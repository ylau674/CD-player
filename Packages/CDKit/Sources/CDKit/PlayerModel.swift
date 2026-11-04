import Combine
import CDAudioCore
import CoreAudio
import Foundation
import OSLog

public enum PlayerState: String, Sendable {
    case empty, ready, playing, paused, ended, failed
}

public enum ScanDirection: Sendable {
    case backward, forward
}

public enum PlayerSource: Sendable {
    case demo, opticalDrive
}

/// What went wrong, in words a listener understands; the technical detail is only logged.
public enum PlayerErrorKind: String, Sendable {
    case drive = "Drive error"
    case disc = "Disc error"
    case read = "Read error"
    case access = "Access denied"
    case eject = "Eject error"
    case audio = "Audio error"
}

@MainActor
public final class PlayerModel: ObservableObject {
    @Published public private(set) var disc: Disc? = .demo
    @Published public private(set) var state: PlayerState = .ready {
        didSet {
            if state != oldValue {
                updateSleepPrevention()
                if state == .playing { lostOutput = nil }
                if state != .playing {
                    playbackIsInLeadIn = false
                    clearAudioLevelMeter()
                    updateSelectedOutput()
                }
                updateVolumeMirror()
            }
        }
    }
    /// Not `@Published`: playback polls it ten times a second, but the display shows only the
    /// track and whole seconds, so views are told only when those change.
    public private(set) var currentFrame: UInt64 = 0 {
        willSet {
            if clockReading(at: newValue) != clockReading(at: currentFrame) { objectWillChange.send() }
        }
        didSet {
            if currentFrame != oldValue && (state != .playing || currentFrame < oldValue) {
                resetDisplayClock(at: currentFrame)
            } else if currentFrame != oldValue {
                displayPositionUpdatedAt = audioClock()
            }
        }
    }
    private var displayLatencyFrames: UInt64 = 0
    private var displayFrameFloor: UInt64 = 0
    private var displayPositionUpdatedAt: ContinuousClock.Instant?
    @Published public private(set) var showsAudioLevels = false
    /// Set when the window reports the meters fully shown and cleared the moment they are hidden. The meters
    /// measure only while it is set: never while the window extends or shrinks, or while they are closed.
    @Published public private(set) var audioLevelsAreFullyShown = false
    /// AppKit reports whether any part of the player window is on screen and not fully occluded.
    @Published public private(set) var audioLevelsWindowIsVisible = false
    private var audioLevelMeter = AudioLevelMeter()
    private var lastAudioLevelFrame: UInt64?
    private var lastAudioLevelTrack: Int?
    @Published public private(set) var isBusy = false
    @Published public private(set) var output: OutputInfo? {
        didSet {
            outputGeneration &+= 1
            updateVolumeMirror()
        }
    }
    @Published public private(set) var availableOutputs: [AudioOutputDevice] = [] {
        didSet { updateVolumeMirror() }
    }
    /// The output-rate switch is changing the output's rate; Play waits for it.
    @Published public private(set) var isChangingOutputRate = false
    @Published private(set) var isRecoveringOutputRates = false
    /// The last failed action, kept until the next action or drive/disc change clears it.
    @Published private var failure: (kind: PlayerErrorKind, message: String)?
    /// Not `@Published`: it changes on every playback poll and nothing displays it.
    public private(set) var bufferedFrames = 0
    @Published public private(set) var concealedSectors: UInt64 = 0
    @Published public private(set) var isUnverified = false
    @Published public private(set) var isHDCDDecodingEnabled = true
    /// What playback has found on the loaded disc. HDCD stays found until the disc is ejected or
    /// changed, so a later Play, skip or seek does not show CD while that run detects again.
    @Published private var discHDCDStatus = HDCDPlaybackStatus.notApplicable
    /// The last decided run's state; a run still detecting keeps the previous run's.
    @Published private var playbackHDCDDecoded = false
    @Published private var playbackPhysicalOutputBits: UInt32 = 0
    @Published private var playbackIsBuffering = false {
        didSet {
            if playbackIsBuffering { clearAudioLevelMeter() }
        }
    }
    private var playbackIsInLeadIn = false
    @Published public private(set) var source: PlayerSource
    @Published public private(set) var opticalSnapshot = OpticalSnapshot()
    @Published public private(set) var selectedDriveID: UInt64?
    /// A drive shown by the display's selector that is applied once clicking pauses.
    @Published public private(set) var pendingDriveID: UInt64?
    @Published private var hasSelectedTrack = false
    /// Pausing for system sleep; the controls wait until it finishes.
    @Published private(set) var isPreparingForSleep = false

    /// Where a CD stood when the Mac went to sleep, for when the drive reconnects after wake.
    struct SleepPosition: Equatable {
        let driveName: String
        let tableOfContents: CDTableOfContents
        let frame: UInt64
        let state: PlayerState
        let hasSelectedTrack: Bool
        let concealedSectors: UInt64
        let isUnverified: Bool
    }

    private let engine: any PlaybackEngine
    private let audioLevelSource: any AudioLevelSource
    private let audioClock: @Sendable () -> ContinuousClock.Instant
    private let makeDiscEngine: @MainActor (DiscSession) -> any PlaybackEngine
    private var discEngine: (any PlaybackEngine)?
    private var playbackEngine: any PlaybackEngine { discEngine ?? engine }
    private let opticalService: (any OpticalDriveService)?
    private let discOpener: any DiscOpener
    /// The open disc, kept while paused and closed on eject, removal, drive or source change, and quit.
    private(set) var discSession: DiscSession?
    private struct OpeningDiscSession {
        let id = UUID()
        let driveID: UInt64
        let mediaID: UInt64
        let task: Task<DiscSession, any Error>
    }
    private struct ClosingDiscSession {
        let id = UUID()
        let task: Task<Void, Never>
    }
    private var openingDiscSession: OpeningDiscSession?
    private var closingDiscSession: ClosingDiscSession?
    private let automaticallyMonitor: Bool
    private let driveSelectionDelay: Duration
    private let seekDelay: Duration
    private let outputRateControl: any OutputRateControl
    private let outputSelectionStore: any OutputSelectionStore
    private let hdcdDecodePreferenceStore: any HDCDDecodePreferenceStore
    private var activeHDCDDecodingEnabled: Bool?
    private let volumeMirror: any VolumeMirroring
    /// The pair last given to `volumeMirror`.
    private var volumeMirrorPair: VolumeMirrorPair?
    private var preferredOutputID: OutputChoice.ID?
    /// The saved device's last known name, kept in the store so a launch can name a missing output.
    private var preferredOutputName: String?
    /// Whether the saved device was listed by the last discovery; nil before the first one, so a device
    /// missing at launch counts as lost.
    private var preferredOutputWasPresent: Bool?
    @Published private var selectedOutputChoiceID: OutputChoice.ID?
    /// The target of the playback run in progress; selecting another output while playing moves it.
    private var playingTarget: OutputTarget = .builtIn {
        didSet { updateVolumeMirror() }
    }
    struct LostOutput: Equatable {
        /// Nil when the output's identity is unknown, so only Play or another choice clears the notice.
        let uid: String?
        let name: String
    }
    /// The output that disappeared, or the saved output missing at launch. The notice stays until Play,
    /// another output choice, or the lost output reconnects; Play on the fallback also saves the fallback.
    @Published private(set) var lostOutput: LostOutput?
    /// How long a default-output change waits before deciding the previous output is still connected,
    /// because macOS can announce a new default before it removes the unplugged device.
    private let defaultOutputSettleDelay: Duration
    private var outputCatalogGeneration: UInt64 = 0
    private var outputRateChange: Task<Void, Never>?
    private var outputRateRecovery: Task<Void, Never>?
    private var outputRateRecoveryStarted = false
    private var outputRateRecoveryGeneration: UInt64 = 0
    private var outputMonitor: Task<Void, Never>?
    /// Counts every update of `output`, so a slower refresh never replaces a newer reading.
    private var outputGeneration: UInt64 = 0
    private(set) var driveSelection: Task<Void, Never>?
    private(set) var pendingSeek: Task<Void, Never>?
    private let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Player")
    private var monitor: Task<Void, Never>?
    private var isShuttingDown = false
    private var revision: UInt64 = 0
    private var opticalMonitoringStarted = false
    private var isEjecting = false
    private let sleepPrevention: any SleepPreventing
    private let powerMonitor: any SystemPowerMonitoring
    private var powerEvents: Task<Void, Never>?
    /// How long after wake a reconnecting drive may take to show the same disc again.
    private let wakeGrace: Duration
    /// The longest sleep waits for the pause; macOS itself waits at most 30 seconds.
    private let sleepAcknowledgementLimit: Duration
    /// Kept from sleep until a user action, a different disc, or the end of the wake grace.
    private(set) var sleepPosition: SleepPosition?
    private var sleepPositionExpiry: Task<Void, Never>?
    /// The output's restore did not finish before sleep; it is recovered at wake.
    private(set) var restoresOutputAfterWake = false

    public init(
        engine: any PlaybackEngine = CoreAudioPlaybackEngine(),
        audioLevelSource: any AudioLevelSource = CoreAudioLevelSource.shared,
        audioClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        automaticallyMonitor: Bool = true,
        opticalService: (any OpticalDriveService)? = nil,
        driveSelectionDelay: Duration = .seconds(1),
        discOpener: any DiscOpener = RawDiscOpener(),
        seekDelay: Duration = .milliseconds(300),
        makeDiscEngine: @escaping @MainActor (DiscSession) -> any PlaybackEngine = { CoreAudioPlaybackEngine(session: $0) },
        outputRateControl: any OutputRateControl = CoreAudioOutputRateControl(),
        outputSelectionStore: any OutputSelectionStore = UserDefaultsOutputSelectionStore(),
        hdcdDecodePreferenceStore: any HDCDDecodePreferenceStore = UserDefaultsHDCDDecodePreferenceStore(),
        volumeMirror: any VolumeMirroring = CoreAudioVolumeMirror(),
        sleepPrevention: any SleepPreventing = ProcessActivitySleepPrevention(),
        powerMonitor: any SystemPowerMonitoring = SystemPowerMonitor(),
        wakeGrace: Duration = .seconds(60),
        sleepAcknowledgementLimit: Duration = .seconds(10),
        defaultOutputSettleDelay: Duration = .milliseconds(500)
    ) {
        self.engine = engine
        self.audioLevelSource = audioLevelSource
        self.audioClock = audioClock
        audioLevelMeter = AudioLevelMeter(clock: audioClock)
        self.makeDiscEngine = makeDiscEngine
        self.outputRateControl = outputRateControl
        self.outputSelectionStore = outputSelectionStore
        self.hdcdDecodePreferenceStore = hdcdDecodePreferenceStore
        isHDCDDecodingEnabled = hdcdDecodePreferenceStore.isEnabled
        self.volumeMirror = volumeMirror
        preferredOutputID = outputSelectionStore.selectedID
        preferredOutputName = outputSelectionStore.selectedName
        self.defaultOutputSettleDelay = defaultOutputSettleDelay
        self.sleepPrevention = sleepPrevention
        self.powerMonitor = powerMonitor
        self.wakeGrace = wakeGrace
        self.sleepAcknowledgementLimit = sleepAcknowledgementLimit
        self.automaticallyMonitor = automaticallyMonitor
        self.opticalService = opticalService
        self.driveSelectionDelay = driveSelectionDelay
        self.seekDelay = seekDelay
        self.discOpener = discOpener
        source = opticalService == nil ? .demo : .opticalDrive
        if opticalService != nil {
            disc = nil
            state = .empty
        }
    }

    private func startOutputRateRecovery() {
        guard !outputRateRecoveryStarted, !isShuttingDown else { return }
        outputRateRecoveryStarted = true
        beginOutputRateRecovery()
    }

    /// Play, inspection and output refreshes wait for this recovery, so Play never records an output
    /// that is still at the playback format as the one to restore.
    private func beginOutputRateRecovery() {
        isRecoveringOutputRates = true
        outputRateRecoveryGeneration &+= 1
        let generation = outputRateRecoveryGeneration
        let earlier = outputRateRecovery
        let control = outputRateControl
        outputRateRecovery = Task { [weak self] in
            await earlier?.value
            do {
                try await control.recoverPendingRates()
            } catch {
                await self?.reportFailure(error, as: .audio)
            }
            guard let self, generation == self.outputRateRecoveryGeneration else { return }
            self.isRecoveringOutputRates = false
            self.outputRateRecovery = nil
        }
    }

    private func recoverPendingOutputRates() async {
        guard !isRecoveringOutputRates, !isShuttingDown else { return }
        isRecoveringOutputRates = true
        defer { isRecoveringOutputRates = false }
        do {
            try await outputRateControl.recoverPendingRates()
        } catch {
            await reportFailure(error, as: .audio)
        }
    }

    public var currentTrack: Disc.Track? { disc?.track(at: displayFrame(at: currentFrame)) }
    private struct ClockReading: Equatable {
        let track: Int
        let second: UInt64
    }
    /// The part of a position the display shows: the same values as `currentTrack` and `elapsedSeconds`.
    private func clockReading(at frame: UInt64) -> ClockReading? {
        let frame = displayFrame(at: frame)
        guard let track = disc?.track(at: frame) else { return nil }
        return ClockReading(track: track.number, second: (frame - track.startFrame) / sourceFormat.sampleRate)
    }
    private func displayFrame(at frame: UInt64) -> UInt64 {
        guard let disc else { return frame }
        let adjusted = frame > displayLatencyFrames ? frame - displayLatencyFrames : 0
        return min(max(adjusted, displayFrameFloor), disc.totalFrames)
    }
    private func resetDisplayClock(at frame: UInt64) {
        displayLatencyFrames = 0
        displayFrameFloor = min(frame, disc?.totalFrames ?? frame)
        displayPositionUpdatedAt = audioClock()
    }
    private func updateDisplayClock(for output: OutputInfo, at frame: UInt64, floor: UInt64? = nil) {
        let visibleFrame = floor ?? displayFrame(at: frame)
        let latencySeconds = output.streamLatencySeconds ?? 0
        let sourceRate = Double(sourceFormat.sampleRate)
        let latency = latencySeconds * sourceRate
        let maximumLatency = Double(disc?.totalFrames ?? 0)
        displayLatencyFrames = latency.isFinite && latency > 0
            ? UInt64(min(latency.rounded(.up), maximumLatency))
            : 0
        displayFrameFloor = min(visibleFrame, disc?.totalFrames ?? visibleFrame)
        displayPositionUpdatedAt = audioClock()
        playbackIsInLeadIn = output.transport == .hdmi || output.transport == .displayPort
    }
    public var selectedDrive: OpticalDrive? {
        opticalSnapshot.drives.first { $0.id == selectedDriveID }
    }
    /// The drive named on the display: one being chosen with the selector, otherwise the selected drive.
    public var displayedDrive: OpticalDrive? {
        opticalSnapshot.drives.first { $0.id == pendingDriveID } ?? selectedDrive
    }
    public var isSelectingDrive: Bool { pendingDriveID != nil }
    public var isBuffering: Bool { state == .playing && playbackIsBuffering }
    public var isPlayingCD: Bool { source == .opticalDrive && state == .playing }
    public var audioLevelReading: AudioLevelMeter.Reading { audioLevelMeter.reading }
    /// The meters read only while this is true; at any other time they are already dark.
    public var audioLevelsAreLive: Bool {
        audioLevelsAreFullyShown && audioLevelsWindowIsVisible && state == .playing
    }

    /// The meters' timed read: levels are pulled at the display position, not pushed by the poll.
    public func refreshAudioLevels() -> AudioLevelMeter.Reading {
        updateAudioLevels()
        return audioLevelReading
    }

    /// Showing the meters starts the window's animation, and they stay dark until it finishes.
    /// Hiding them darkens them and stops measuring before the window starts to shrink.
    public func toggleAudioLevels() {
        showsAudioLevels.toggle()
        audioLevelsAreFullyShown = false
        clearAudioLevelMeter()
    }

    /// The window reports that its bottom edge has finished moving down or, with Reduce Motion, that the meters
    /// have finished fading in. The meters measure from here. A report after they were hidden again is ignored.
    public func audioLevelsDidFinishShowing() {
        guard showsAudioLevels, !audioLevelsAreFullyShown else { return }
        audioLevelsAreFullyShown = true
        updateAudioLevels()
    }

    /// The window reports visibility changes so covered, miniaturized or hidden meters stop reading.
    public func audioLevelsWindowVisibilityDidChange(_ isVisible: Bool) {
        guard audioLevelsWindowIsVisible != isVisible else { return }
        audioLevelsWindowIsVisible = isVisible
        if isVisible {
            updateAudioLevels()
        } else {
            clearAudioLevelMeter()
        }
    }

    public func updateAudioLevels() {
        guard audioLevelsAreFullyShown, audioLevelsWindowIsVisible else { return }
        let now = audioClock()
        guard state == .playing, !isBusy, !playbackIsBuffering, !playbackIsInLeadIn,
              pendingSeek == nil, !isShuttingDown, !isPreparingForSleep, lostOutput == nil,
              let disc else {
            clearAudioLevelMeter()
            return
        }

        let frame = displayLevelFrame(at: now)
        guard let track = disc.track(at: frame) else {
            clearAudioLevelMeter()
            return
        }
        if lastAudioLevelTrack != track.number || lastAudioLevelFrame.map({ frame < $0 }) == true {
            audioLevelMeter.reset()
            lastAudioLevelFrame = nil
        }

        let peaks: AudioLevelPeaks?
        if let previous = lastAudioLevelFrame {
            peaks = frame > previous
                ? audioLevelSource.peaks(fromFrame: previous, throughFrame: frame)
                : nil
        } else {
            peaks = audioLevelSource.peaks(fromFrame: frame, throughFrame: frame)
        }
        audioLevelMeter.update(with: peaks)
        lastAudioLevelFrame = frame
        lastAudioLevelTrack = track.number
    }

    private func displayLevelFrame(at now: ContinuousClock.Instant) -> UInt64 {
        let base = displayFrame(at: currentFrame)
        guard state == .playing, !playbackIsBuffering, !playbackIsInLeadIn,
              let displayPositionUpdatedAt, let disc else { return base }
        let elapsed = min(max(audioLevelElapsedSeconds(from: displayPositionUpdatedAt, to: now), 0), 0.2)
        let maxAdvance = UInt64(elapsed * Double(sourceFormat.sampleRate))
        return base + min(maxAdvance, disc.totalFrames - base)
    }

    private func clearAudioLevelMeter() {
        audioLevelMeter.reset()
        lastAudioLevelFrame = nil
        lastAudioLevelTrack = nil
    }
    /// Several drives can be cycled through. A lone drive gets the icon only to rescan it after a
    /// drive, disc or eject error; Play is the retry after an audio, read or access error.
    public var showsDriveSelector: Bool {
        guard source == .opticalDrive else { return false }
        let count = opticalSnapshot.drives.count
        return count > 1 || (count == 1 && rescanCanFixCurrentError)
    }
    public var opticalDriveSelectionEnabled: Bool {
        opticalService != nil && !isPlayingCD && !isBusy && !isShuttingDown && !isPreparingForSleep
    }
    public var driveSelectorEnabled: Bool { showsDriveSelector && opticalDriveSelectionEnabled }
    public var driveSelectorLabel: String {
        opticalSnapshot.drives.count > 1 ? "Switch to next optical drive" : "Refresh optical drive"
    }
    private var selectionPosition: (index: Int, count: Int)? {
        guard let index = opticalSnapshot.drives.firstIndex(where: { $0.id == pendingDriveID }) else { return nil }
        return (index + 1, opticalSnapshot.drives.count)
    }
    public var isShowingDiscSummary: Bool {
        if isSelectingDrive { return false }
        return disc != nil && !hasSelectedTrack
    }
    public var displayTrackNumber: Int {
        if isSelectingDrive { return 0 }
        if isShowingDiscSummary {
            return disc?.tracks.count ?? 0
        }
        return currentTrack?.number ?? 0
    }
    public var elapsedSeconds: UInt64 {
        let frame = displayFrame(at: currentFrame)
        guard let track = disc?.track(at: frame) else { return 0 }
        return (frame - track.startFrame) / sourceFormat.sampleRate
    }
    public var timeText: String {
        let seconds: UInt64
        if isSelectingDrive {
            seconds = 0
        } else if isShowingDiscSummary {
            seconds = (disc?.totalFrames ?? 0) / sourceFormat.sampleRate
        } else {
            seconds = elapsedSeconds
        }
        return String(format: "%02llu:%02llu", seconds / 60, seconds % 60)
    }
    public var trackText: String { String(format: "%02d", displayTrackNumber) }
    public var displayAccessibilityLabel: String {
        if let position = selectionPosition {
            return "Selecting optical drive \(position.index) of \(position.count)"
        }
        if isShowingDiscSummary {
            let tracks = displayTrackNumber == 1 ? "1 audio track" : "\(displayTrackNumber) audio tracks"
            return "Disc total, \(tracks), total time \(timeText)"
        }
        return "Track \(displayTrackNumber), elapsed \(timeText)"
    }
    public var controlsEnabled: Bool {
        guard disc != nil, !isBusy, !isShuttingDown, !isPreparingForSleep,
              !isRecoveringOutputRates, !isSelectingDrive else { return false }
        return source == .demo || (
            opticalSnapshot.errorMessage == nil && selectedDrive?.issue == nil &&
            selectedDrive?.media?.bsdName != nil && selectedDrive?.media?.contents.tableOfContents != nil
        )
    }
    public var ejectEnabled: Bool {
        // While choosing a drive, Eject would still target the previous drive's disc.
        guard !isBusy, !isShuttingDown, !isPreparingForSleep,
              !isRecoveringOutputRates, !isSelectingDrive else { return false }
        if source == .demo { return disc != nil }
        return opticalSnapshot.errorMessage == nil &&
            selectedDrive?.media?.isEjectable == true && selectedDrive?.media?.bsdName != nil
    }
    public var isStopAction: Bool { state == .playing || state == .paused }
    public var stopOrEjectLabel: String {
        if isStopAction { return "Stop" }
        return source == .demo ? "Eject demo disc" : "Eject disc"
    }
    public var stopOrEjectSymbol: String { isStopAction ? "stop.fill" : "eject.fill" }
    public var stopOrEjectEnabled: Bool { isStopAction ? controlsEnabled : ejectEnabled }
    public var errorMessage: String? { failure?.message }
    private var currentError: (kind: PlayerErrorKind, message: String)? {
        if let failure { return failure }
        guard source == .opticalDrive else { return nil }
        if let issue = opticalSnapshot.errorMessage { return (.drive, issue) }
        if let issue = selectedDrive?.issue { return (.drive, issue) }
        if case .unreadable(let issue) = selectedDrive?.media?.contents { return (.disc, issue) }
        return nil
    }
    /// The technical message behind the current error. It is logged, not displayed.
    public var errorDetail: String? { currentError?.message }
    private var rescanCanFixCurrentError: Bool {
        switch currentError?.kind {
        case .drive, .disc, .eject: return true
        case .read, .access, .audio, nil: return false
        }
    }
    /// The short error the status line shows, such as "Drive error"; nil while another status takes precedence.
    public var errorSummary: String? {
        guard !isEjecting, !isBusy || (state == .failed && failure != nil), selectionPosition == nil else { return nil }
        return currentError?.kind.rawValue
    }
    private var baseStatusText: String {
        if isEjecting { return "EJECTING" }
        if isBusy && (state != .failed || failure == nil) { return "PREPARING" }
        if let position = selectionPosition { return "DRIVE \(position.index) OF \(position.count)" }
        if let errorSummary { return "[ERR] \(errorSummary)" }
        if lostOutput != nil, state != .playing { return "OUTPUT LOST" }
        if isBuffering { return "BUFFERING" }
        if source == .opticalDrive {
            if !opticalMonitoringStarted { return "CHECKING DRIVE" }
            guard let selectedDrive else { return "NO DRIVE" }
            guard let media = selectedDrive.media else { return "NO DISC" }
            switch media.contents {
            case .reading: return "READING"
            case .audioCD:
                switch state {
                case .playing: return "\(discLabel) PLAYING"
                case .paused: return "\(discLabel) PAUSED"
                case .ended: return "\(discLabel) END"
                default: return "\(discLabel) DETECTED"
                }
            case .dataCD: return "DATA DISC"
            case .other: return "NOT AUDIO CD"
            case .unreadable: return "[ERR] \(PlayerErrorKind.disc.rawValue)"
            }
        }
        switch state {
        case .empty: return "NO DEMO DISC"
        case .ready: return "DEMO READY"
        case .playing: return "DEMO PLAYING"
        case .paused: return "DEMO PAUSED"
        case .ended: return "DEMO END"
        case .failed: return "[ERR] \(PlayerErrorKind.audio.rawValue)"
        }
    }
    private var qualityStatusSuffix: [String] {
        guard source == .opticalDrive, !isEjecting, !isSelectingDrive,
              !isBusy || (state == .failed && failure != nil) else { return [] }
        switch state {
        case .playing, .paused, .ended, .failed: break
        case .empty, .ready: return []
        }
        var suffix: [String] = []
        if concealedSectors > 0 { suffix.append("ERR \(concealedSectors)") }
        if isUnverified { suffix.append("UNVERIFIED") }
        return suffix
    }
    public var statusText: String {
        ([baseStatusText] + qualityStatusSuffix).joined(separator: " | ")
    }
    public var statusIsError: Bool {
        baseStatusText.hasPrefix("[ERR] ") || errorSummary != nil ||
            qualityStatusSuffix.contains { $0.hasPrefix("ERR ") }
    }
    public var statusIsWarning: Bool {
        !statusIsError && (baseStatusText == "OUTPUT LOST" || qualityStatusSuffix.contains("UNVERIFIED"))
    }
    public var statusAccessibilityLabel: String {
        let base: String
        if let errorSummary { base = "Error: \(errorSummary)" }
        else if baseStatusText.hasPrefix("[ERR] ") {
            base = "Error: \(baseStatusText.dropFirst("[ERR] ".count))"
        } else if let position = selectionPosition {
            base = "Selecting optical drive \(position.index) of \(position.count)"
        } else {
            switch baseStatusText {
            case "EJECTING": base = "Ejecting disc"
            case "PREPARING": base = "Preparing playback"
            case "BUFFERING": base = "Buffering audio"
            case "CHECKING DRIVE": base = "Checking for an optical drive"
            case "NO DRIVE": base = "No optical drive"
            case "NO DISC": base = "No disc"
            case "READING": base = "Reading disc metadata"
            case "DATA DISC": base = "Data disc detected"
            case "NOT AUDIO CD": base = "Disc is not an audio CD"
            case "DEMO READY": base = "Demo disc ready"
            case "DEMO PLAYING": base = "Demo playing"
            case "DEMO PAUSED": base = "Demo paused"
            case "DEMO END": base = "Demo ended"
            case "NO DEMO DISC": base = "No demo disc"
            case "\(discLabel) PLAYING": base = "\(discLabel) playing"
            case "\(discLabel) PAUSED": base = "\(discLabel) paused"
            case "\(discLabel) END": base = "\(discLabel) ended"
            case "\(discLabel) DETECTED": base = isHDCDDisc ? "HDCD disc detected" : "Audio CD detected"
            case "OUTPUT LOST":
                let name = lostOutput?.name ?? "audio output"
                base = state == .paused ? "Output lost: \(name). Playback paused" : "Output lost: \(name)"
            default: base = baseStatusText
            }
        }
        var details = [base]
        if qualityStatusSuffix.contains(where: { $0.hasPrefix("ERR ") }) {
            let count = concealedSectors
            details.append("\(count) audio sector\(count == 1 ? "" : "s") concealed")
        }
        if qualityStatusSuffix.contains("UNVERIFIED") {
            details.append("Audio alignment or independent read verification is unverified")
        }
        return details.joined(separator: ". ")
    }
    public var sourceText: String {
        if source == .demo { return "DEMO - 3 simulated tracks, not the physical CD" }
        guard let drive = selectedDrive else { return "Connect a CD / DVD / Blu-ray drive." }
        guard let media = drive.media else { return "\(drive.name) | Insert an audio CD." }
        if let table = media.contents.tableOfContents {
            let seconds = table.audioDurationSeconds
            let duration = String(format: "%02llu:%02llu", seconds / 60, seconds % 60)
            let tracks = table.audioTracks.count == 1 ? "1 audio track" : "\(table.audioTracks.count) audio tracks"
            return "\(drive.name) | \(tracks) | \(duration)"
        }
        if case .other(let type) = media.contents { return "\(drive.name) | \(type)" }
        return drive.name
    }
    /// The PCM format of the loaded disc, detected from its table of contents: 44.1 kHz / 16-bit stereo
    /// for an audio CD. Without a disc, the CD format the player plays.
    public var sourceFormat: AudioSourceFormat { disc?.format ?? .compactDisc }
    /// Describes the disc beside the power button; blank when there is no disc to describe. An HDCD
    /// disc names the depth it plays at: its own 16 bits, or 20 once decoded.
    public var formatText: String {
        if isSelectingDrive { return "" }
        if source == .demo { return disc == nil ? "" : "\(sourceFormat.description) source" }
        guard let media = selectedDrive?.media else { return "" }
        guard let table = media.contents.tableOfContents else { return "Optical media" }
        let format = table.audioFormat ?? sourceFormat
        guard isHDCDDisc else { return "\(format.description) source" }
        let bits = playbackHDCDDecoded ? Self.hdcdDecodedBitsPerChannel : format.bitsPerChannel
        return "\(format.rateText) / \(bits)-bit HDCD"
    }
    public var formatHelp: String? {
        guard source == .opticalDrive else { return nil }
        switch discHDCDStatus {
        case .noEffect:
            return "HDCD disc using no decodable features; its \(sourceFormat.bitsPerChannel)-bit audio plays unchanged and bit-perfect."
        case .effectual where playbackHDCDDecoded:
            return "HDCD disc decoded to \(Self.hdcdDecodedBitsPerChannel)-bit PCM. It plays about 6 dB quieter; no make-up gain is applied."
        case .effectual:
            if playbackPhysicalOutputBits > 0 && playbackPhysicalOutputBits < 20 {
                return "HDCD disc detected; it is not decoded because the selected output carries only \(playbackPhysicalOutputBits) bits."
            }
            if playbackPhysicalOutputBits == 0 {
                return "HDCD disc detected; it is not decoded because the selected output's physical bit depth is unavailable."
            }
            if activeHDCDDecodingEnabled == false {
                return "HDCD disc detected; decoding was off for this playback run. The setting applies at the next Play, track start or seek."
            }
            return "HDCD disc detected; it is not decoded in this playback run. The setting applies at the next Play, track start or seek."
        default:
            return nil
        }
    }
    public var formatAccessibilityLabel: String {
        guard let formatHelp else { return formatText }
        return "\(formatText). \(formatHelp)"
    }
    /// The depth HDCD decoding restores, carried in 32-bit samples.
    private static let hdcdDecodedBitsPerChannel: UInt32 = 20
    /// Known only once playback has read the disc's audio; the app reads none before Play.
    private var isHDCDDisc: Bool {
        source == .opticalDrive && (discHDCDStatus == .noEffect || discHDCDStatus == .effectual)
    }
    private var discLabel: String { isHDCDDisc ? "HDCD" : "CD" }
    /// The output-rate switch beside the output selector, lit while the output Play would use runs at
    /// the source's rate (44.1 kHz for an audio CD), as it always does during playback. Lighting it keeps
    /// that rate between plays; unlit, Play still switches to it and Pause, Stop or quit switch back.
    public var showsOutputRateSwitch: Bool { output != nil }
    public var outputMatchesSource: Bool { output?.sampleRate == Double(sourceFormat.sampleRate) }
    /// The output's type: speakers, headphones, USB, HDMI, DisplayPort, Thunderbolt, AirPlay or other.
    public var outputRateSymbol: String {
        guard let output else { return "hifispeaker" }
        return output.transport.symbol(usesSpeakers: output.usesSpeakers)
    }
    public var outputRateSwitchEnabled: Bool {
        guard let output, state != .playing, !isBusy, !isShuttingDown, !isPreparingForSleep,
              !isChangingOutputRate, !isRecoveringOutputRates,
              !outputHeldByAnotherApp else { return false }
        return outputMatchesSource ? output.restoreRate > 0 : output.supportsSourceRate
    }
    public var outputRateLabel: String {
        guard let output else { return "" }
        var current = "\(output.name) at \(Self.rateText(output.sampleRate))"
        if activeTarget == .systemDefault {
            current += output.converts
                ? ", System Default, best effort: macOS converts the audio"
                : ", System Default, best effort"
        }
        if outputHeldByAnotherApp { return "\(current). Another app has exclusive use of it." }
        if outputMatchesSource {
            if state == .playing { return "\(current), matching the source during playback." }
            guard output.restoreRate > 0 else { return "\(current), matching the source." }
            return "\(current), matching the source. Click to restore \(Self.rateText(output.restoreRate))."
        }
        let source = sourceFormat.rateText
        guard output.supportsSourceRate else { return "\(current). It cannot match the \(source) source." }
        return "\(current). Click to match the \(source) source."
    }
    private var outputHeldByAnotherApp: Bool {
        guard let owner = output?.hogOwner else { return false }
        return owner != -1 && owner != ProcessInfo.processInfo.processIdentifier
    }
    private static func rateText(_ rate: Double) -> String { AudioSourceFormat.rateText(rate) }
    public var guidanceText: String {
        if source == .opticalDrive {
            guard let media = selectedDrive?.media else {
                return "Connect an optical drive and insert an audio CD. Playback never starts automatically."
            }
            let mount = media.isMounted.map { $0 ? "Mounted." : "Not mounted." } ?? "Mount state unavailable."
            return "\(mount) Press Play to read the selected audio CD. System volume remains under your control."
        }
        if activeTarget == .systemDefault, output?.converts == true {
            return "System Default, best effort: macOS converts the rate or channels for this output."
        }
        return output?.transport == .builtIn && output?.usesSpeakers == true
            ? "Use wired headphones for the DAC path; built-in speakers use Apple DSP."
            : "No app EQ, gain or resampling. System volume remains under your control."
    }
    public func toggleHDCDDecoding() {
        setHDCDDecodingEnabled(!isHDCDDecodingEnabled)
    }

    public func setHDCDDecodingEnabled(_ enabled: Bool) {
        guard enabled != isHDCDDecodingEnabled else { return }
        hdcdDecodePreferenceStore.save(isEnabled: enabled)
        isHDCDDecodingEnabled = enabled
    }

    public var outputText: String {
        guard let output else {
            return activeTarget == .systemDefault ? "Checking the default audio output..." : "Checking built-in audio output..."
        }
        if activeTarget == .systemDefault {
            let path = output.converts ? "Converted by macOS" : "Native \(sourceFormat.rateText)"
            return state == .playing
                ? "\(output.name) | System Default, best effort | \(path)"
                : "\(output.name) | System Default, best effort | \(path) on Play"
        }
        return state == .playing
            ? "\(output.name) | Native \(sourceFormat.rateText)"
            : "\(output.name) | Native \(sourceFormat.rateText) on Play"
    }

    /// The target the next Play uses: System Default when chosen, otherwise the built-in rule. Wired
    /// outputs are routed by their persistent Core Audio UID.
    var playbackTarget: OutputTarget {
        switch selectedOutputChoiceID ?? preferredOutputID {
        case .systemDefault: .systemDefault
        case .device(let uid):
            selectorDevices.first(where: { $0.id == uid })?.transport == .builtIn
                ? .builtIn : .device(uid: uid)
        case nil: .builtIn
        }
    }
    /// The target `output` describes: the playing one during playback, otherwise the next Play's.
    private var activeTarget: OutputTarget { state == .playing ? playingTarget : playbackTarget }

    /// The outputs the selector lists: built-in first, then wired external transports, then System
    /// Default, which plays to whatever macOS uses, Bluetooth and AirPlay included, best effort.
    public var outputChoices: [OutputChoice] {
        var choices = selectorDevices.map(\.choice)
        if choices.isEmpty {
            choices = [
                OutputChoice(
                    id: .device(uid: "unavailable"), name: "No wired audio output",
                    connection: "Unavailable", isEnabled: false, disabledReason: "No output is available."
                )
            ]
        }
        choices.append(.systemDefault(defaultOutputDevice))
        return choices
    }
    public var selectedOutputID: OutputChoice.ID { selectedOutputChoice.id }
    public var selectedOutputChoice: OutputChoice {
        let choices = outputChoices
        if let selectedOutputChoiceID, let selected = choices.first(where: { $0.id == selectedOutputChoiceID }) {
            return selected
        }
        return choices[0]
    }
    /// The device macOS uses as its default output, from discovery or, before it, from inspection.
    private var defaultOutputDevice: AudioOutputDevice? {
        availableOutputs.first(where: \.isDefaultOutput) ?? (output?.isDefaultOutput == true ? fallbackOutput : nil)
    }
    /// Decision 19: while the CD plays on a directly chosen output that is not the macOS default, and
    /// both are listed with a host volume control, the default's volume and mute are mirrored onto it.
    /// Never on System Default, which may still be playing on the previous default while it moves.
    private var currentVolumeMirrorPair: VolumeMirrorPair? {
        guard !isShuttingDown, state == .playing, playingTarget != .systemDefault, let output, !output.uid.isEmpty,
              let playing = availableOutputs.first(where: { $0.id == output.uid }), playing.hasVolumeControl,
              let defaultOutput = availableOutputs.first(where: \.isDefaultOutput), defaultOutput.hasVolumeControl,
              defaultOutput.id != playing.id else { return nil }
        return VolumeMirrorPair(defaultUID: defaultOutput.id, outputUID: playing.id)
    }
    private func updateVolumeMirror() {
        let pair = currentVolumeMirrorPair
        guard pair != volumeMirrorPair else { return }
        volumeMirrorPair = pair
        volumeMirror.mirror(pair)
    }
    private var selectorDevices: [AudioOutputDevice] {
        let wired = availableOutputs.filter { $0.transport.isSelectableWiredOutput }
        let fallback = fallbackOutput.flatMap { $0.transport.isSelectableWiredOutput ? [$0] : nil } ?? []
        let devices = wired.isEmpty ? fallback : wired
        return devices.sorted {
            let left = $0.transport.preferenceRank
            let right = $1.transport.preferenceRank
            if left != right { return left < right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var fallbackOutput: AudioOutputDevice? {
        guard let output else { return nil }
        let uid = output.uid.isEmpty ? "output-\(output.deviceID)" : output.uid
        return AudioOutputDevice(
            uid: uid, deviceID: output.deviceID, name: output.name, transport: output.transport,
            sampleRate: output.sampleRate, hogOwner: output.hogOwner, supportsSourceRate: output.supportsSourceRate,
            hasStereoOutput: output.outputChannels >= 2, isDefaultOutput: output.isDefaultOutput,
            terminalType: output.terminalType, usesSpeakers: output.usesSpeakers, restoreRate: output.restoreRate,
            sourceRate: Double(sourceFormat.sampleRate), hasVolumeControl: output.hasVolumeControl
        )
    }
    /// Usable during playback, and while another app holds the output, so the user can change the
    /// preferred output; not while the player is busy.
    public var outputSelectorEnabled: Bool {
        !isBusy && !isEjecting && !isShuttingDown && !isPreparingForSleep &&
            !isChangingOutputRate && !isRecoveringOutputRates
    }
    public var outputSelectorName: String {
        let choice = selectedOutputChoice
        return choice.isSystemDefault && choice.name.isEmpty ? "System Default" : choice.name
    }
    public var outputSelectorHelp: String {
        let selected = selectedOutputChoice
        var sentences = [selected.title]
        let defaultDevice = defaultOutputDevice
        if selected.isSystemDefault, let defaultDevice {
            for device in selectorDevices where device.id == defaultDevice.id {
                let wiredChoice = device.choice
                if wiredChoice.isEnabled {
                    sentences.append(
                        "Choose \"\(wiredChoice.routeTitle)\" for direct \(sourceFormat.rateText) playback"
                    )
                }
                break
            }
        }
        // The volume keys and menu-bar slider act on the macOS default; while playing, decision 19 mirrors
        // them onto a directly chosen output when both have a host volume control.
        if case .device(let uid) = selected.id, selected.isEnabled, let defaultDevice, defaultDevice.id != uid {
            if defaultDevice.hasVolumeControl,
               let device = availableOutputs.first(where: { $0.id == uid }), device.hasVolumeControl {
                sentences.append("While playing, volume keys control \(device.name) and \(defaultDevice.name)")
            } else {
                sentences.append("Volume keys control \(defaultDevice.name)")
            }
        }
        if let lostOutput {
            sentences.append(state == .paused
                ? "\(lostOutput.name) was disconnected; playback paused"
                : "\(lostOutput.name) is not connected")
        }
        return sentences.count == 1 ? sentences[0] : sentences.joined(separator: ". ") + "."
    }
    public var outputSelectorAccessibilityValue: String { selectedOutputChoice.accessibilityValue }

    /// Remembers the chosen output. System Default routes to the macOS default; wired devices route by
    /// UID. Choosing another output while playing moves playback there at the same position.
    public func selectOutput(_ id: OutputChoice.ID) async {
        // The ticked entry can be a fallback for a missing saved output; choosing it saves it.
        guard outputSelectorEnabled, id != selectedOutputID || id != preferredOutputID,
              outputChoices.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        lostOutput = nil
        selectedOutputChoiceID = id
        savePreferredOutput(id)
        if state == .playing {
            if let disc, playbackTarget != playingTarget { await moveOutput(to: playbackTarget, in: disc) }
        } else {
            await refreshOutput()
        }
    }

    /// Only listed, enabled outputs are saved, so a saved device is present.
    private func savePreferredOutput(_ id: OutputChoice.ID) {
        preferredOutputID = id
        outputSelectionStore.save(id)
        preferredOutputName = nil
        if case .device(let uid) = id {
            preferredOutputWasPresent = true
            rememberPreferredOutputName(availableOutputs.first(where: { $0.id == uid })?.name
                ?? outputChoices.first(where: { $0.id == id })?.name)
        } else {
            preferredOutputWasPresent = nil
        }
    }

    /// Play while the saved device is missing uses the fallback the selector shows. That fallback
    /// becomes the saved output, so later launches don't report the old device as lost.
    private func adoptFallbackOutput(_ choice: OutputChoice.ID?) {
        guard let choice, choice != preferredOutputID, case .device = preferredOutputID,
              preferredOutputWasPresent == false else { return }
        savePreferredOutput(choice)
        logger.notice("The saved output is missing; the output Play used is now saved instead.")
    }

    /// Stops and restarts playback on another target at the same position. Stopping restores a rate
    /// playback changed on the previous output.
    private func moveOutput(to target: OutputTarget, in disc: Disc) async {
        let wasSeeking = pendingSeek != nil
        cancelPendingSeek()
        discardSleepPosition()
        isBusy = true
        revision &+= 1
        let actionRevision = revision
        defer { isBusy = false }
        failure = nil
        monitor?.cancel()
        do {
            let snapshot = try await playbackEngine.stop()
            guard actionRevision == revision, !isShuttingDown else { return }
            updatePlaybackQuality(from: snapshot)
            logPlaybackTotals("moved to another output", snapshot)
            let frame = wasSeeking ? currentFrame : min(snapshot.currentFrame, disc.totalFrames)
            currentFrame = frame
            bufferedFrames = 0
            if frame == disc.totalFrames {
                await finishDisc(actionRevision: actionRevision)
                return
            }
            try Task.checkCancellation()
            let decodeHDCD = activeHDCDDecodingEnabled ?? isHDCDDecodingEnabled
            let started = try await playbackEngine.start(at: frame, on: target, decodeHDCD: decodeHDCD)
            try Task.checkCancellation()
            guard actionRevision == revision, !isShuttingDown else { return }
            clearPlaybackQuality()
            beginHDCDPlayback(decodeHDCD: decodeHDCD)
            updateDisplayClock(for: started, at: frame, floor: wasSeeking ? frame : nil)
            output = started
            playingTarget = target
            playbackIsBuffering = true
            beginMonitoring()
        } catch is CancellationError {
            await finishCancelledPlayback(actionRevision: actionRevision)
        } catch {
            guard actionRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
        await refreshOutputChoices()
    }

    public func inspectOutput() async {
        if let outputRateRecovery { await outputRateRecovery.value }
        let inspectionRevision = revision
        var target = activeTarget
        for attempt in 1...2 {
            let inspected: Result<OutputInfo, any Error>
            do {
                inspected = .success(try await engine.inspectOutput(on: target, format: sourceFormat))
            } catch {
                inspected = .failure(error)
            }
            guard inspectionRevision == revision, !isShuttingDown else { return }
            if case .success(let info) = inspected { output = info }
            await refreshOutputChoices()
            guard inspectionRevision == revision, !isShuttingDown else { return }
            // Discovery can move the selection to another target, for example from a remembered System
            // Default when macOS has no default output; describe the output the next Play uses.
            if attempt == 1, target != activeTarget {
                target = activeTarget
                continue
            }
            if case .failure(let error) = inspected { await reportFailure(error, as: .audio) }
            return
        }
    }

    private func refreshOutputChoices() async {
        outputCatalogGeneration &+= 1
        let generation = outputCatalogGeneration
        do {
            let devices = try await outputRateControl.discoverOutputs(format: sourceFormat)
            guard generation == outputCatalogGeneration, !isShuttingDown else { return }
            let previous = availableOutputs
            availableOutputs = devices
            updateLostOutput(previouslyListed: previous)
            updateSelectedOutput()
        } catch {
            guard generation == outputCatalogGeneration, !isShuttingDown else { return }
            logger.error("Cannot discover wired audio outputs: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears the notice when the lost output is listed again. While nothing plays, names the saved
    /// device when it is missing at launch or leaves the list; during playback the playback path names
    /// it. Play on the fallback saves the fallback, so the missing device is not named again.
    private func updateLostOutput(previouslyListed previous: [AudioOutputDevice]) {
        if let uid = lostOutput?.uid, availableOutputs.contains(where: { $0.id == uid }) { lostOutput = nil }
        guard case .device(let uid) = preferredOutputID else {
            preferredOutputWasPresent = nil
            return
        }
        let wasPresent = preferredOutputWasPresent
        if let device = availableOutputs.first(where: { $0.id == uid }) {
            preferredOutputWasPresent = true
            rememberPreferredOutputName(device.name)
            return
        }
        preferredOutputWasPresent = false
        guard wasPresent != false, state != .playing, lostOutput == nil else { return }
        let name = previous.first(where: { $0.id == uid })?.name ?? preferredOutputName ?? "The saved output"
        lostOutput = LostOutput(uid: uid, name: name)
    }

    private func rememberPreferredOutputName(_ name: String?) {
        guard let name, !name.isEmpty, name != preferredOutputName, let preferredOutputID else { return }
        preferredOutputName = name
        outputSelectionStore.saveName(name, for: preferredOutputID)
    }

    /// Keeps the saved choice while it is available; otherwise the default wired output, built-in,
    /// another wired output, then System Default as the last resort. Playback keeps its choice.
    private func updateSelectedOutput() {
        let selectable = outputChoices.filter(\.isEnabled).map(\.id)
        guard !selectable.isEmpty else {
            if state != .playing { selectedOutputChoiceID = nil }
            return
        }
        if state == .playing {
            if selectedOutputChoiceID == nil {
                selectedOutputChoiceID = playingTarget == .systemDefault ? .systemDefault : fallbackOutputID(in: selectable)
            }
            return
        }
        if let preferredOutputID, selectable.contains(preferredOutputID) {
            selectedOutputChoiceID = preferredOutputID
        } else {
            selectedOutputChoiceID = fallbackOutputID(in: selectable)
        }
    }

    private func fallbackOutputID(in selectable: [OutputChoice.ID]) -> OutputChoice.ID? {
        let devices = selectorDevices.filter { selectable.contains(.device(uid: $0.id)) }
        let device = devices.first(where: { $0.isDefaultOutput })
            ?? devices.first(where: { $0.transport == .builtIn })
            ?? devices.first
        if let device { return .device(uid: device.id) }
        return selectable.contains(.systemDefault) ? .systemDefault : nil
    }

    /// Keeps the output-rate switch current as outputs come and go or change rate outside the player.
    public func startOutputMonitoring() {
        guard outputMonitor == nil, !isShuttingDown else { return }
        startOutputRateRecovery()
        let changes = outputRateControl.changes()
        outputMonitor = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.refreshOutput()
            }
        }
    }

    /// Matches the output to the source's rate (44.1 kHz for an audio CD), or restores the rate it replaced.
    public func toggleOutputRate() async {
        guard outputRateSwitchEnabled else { return }
        let matchSource = !outputMatchesSource
        let control = outputRateControl
        let target = playbackTarget
        let format = sourceFormat
        failure = nil
        isChangingOutputRate = true
        let change = Task { [weak self] in
            do {
                let switched = try await matchSource
                    ? control.matchSourceRate(on: target, format: format) : control.restoreRate(on: target, format: format)
                if let self, !self.isShuttingDown { self.output = switched }
            } catch {
                if let self, !self.isShuttingDown {
                    // Lighter than a playback failure: nothing plays, so the disc and position are kept.
                    self.logger.error("Audio error: \(error.localizedDescription, privacy: .public)")
                    self.failure = (.audio, error.localizedDescription)
                    await self.refreshOutput()
                }
            }
            self?.outputRateChange = nil
            self?.isChangingOutputRate = false
        }
        outputRateChange = change
        await change.value
    }

    /// Nothing was asked of the player, so a failure is only logged and hides the switch until the
    /// output can be read again.
    private func refreshOutput(retargeting: Bool = true) async {
        if let outputRateRecovery { await outputRateRecovery.value }
        guard !isShuttingDown else { return }
        if state != .playing, !isBusy, !isChangingOutputRate {
            await recoverPendingOutputRates()
        }
        let generation = outputGeneration
        let inspectionRevision = revision
        let target = activeTarget
        let inspected: OutputInfo?
        let inspectionError: (any Error)?
        do {
            inspected = try await engine.inspectOutput(on: target, format: sourceFormat)
            inspectionError = nil
        } catch {
            logger.error("Cannot inspect the audio output: \(error.localizedDescription, privacy: .public)")
            inspected = nil
            inspectionError = error
        }
        await refreshOutputChoices()
        guard generation == outputGeneration, !isShuttingDown else { return }
        guard target == activeTarget else {
            // Discovery moved the selection to another target; describe that output instead.
            if retargeting, state != .playing { await refreshOutput(retargeting: false) }
            return
        }
        if state == .playing, !isBusy {
            if target == .systemDefault, let inspected, let output, inspected.deviceID != output.deviceID {
                await followDefaultOutputChange(from: output, expectedRevision: inspectionRevision)
                return
            }
            if let inspected, let output, !sameOutput(inspected, output) {
                await pauseForOutputChange(
                    inspected, updateOutput: true, expectedRevision: inspectionRevision
                )
                return
            }
            if inspected == nil, let inspectionError, isOutputChange(inspectionError) {
                await pauseForOutputChange(
                    nil, updateOutput: true, expectedRevision: inspectionRevision
                )
                return
            }
        }
        output = inspected
    }

    public func togglePlayback() async {
        if let outputRateRecovery { await outputRateRecovery.value }
        // Play finds the output at the rate a switch in progress sets.
        if let outputRateChange { await outputRateChange.value }
        guard controlsEnabled, let disc else { return }
        discardSleepPosition()
        let wasSeeking = pendingSeek != nil
        cancelPendingSeek()
        isBusy = true
        revision &+= 1
        let actionRevision = revision
        defer { isBusy = false }
        failure = nil
        do {
            if state == .playing {
                monitor?.cancel()
                let snapshot = try await playbackEngine.stop()
                guard actionRevision == revision, !isShuttingDown else { return }
                updatePlaybackQuality(from: snapshot)
                logPlaybackTotals(snapshot.finished ? "ended" : "paused", snapshot)
                if !wasSeeking { currentFrame = min(snapshot.currentFrame, disc.totalFrames) }
                bufferedFrames = 0
                playbackIsBuffering = false
                if !wasSeeking && snapshot.finished {
                    await finishDisc(actionRevision: actionRevision)
                } else {
                    state = .paused
                }
            } else {
                if currentFrame == disc.totalFrames { currentFrame = 0 }
                guard let playback = await preparePlaybackEngine(), actionRevision == revision, !isShuttingDown else { return }
                try Task.checkCancellation()
                let target = playbackTarget
                let choice = selectedOutputChoiceID
                let decodeHDCD = isHDCDDecodingEnabled
                let started = try await playback.start(at: currentFrame, on: target, decodeHDCD: decodeHDCD)
                try Task.checkCancellation()
                guard actionRevision == revision, !isShuttingDown else { return }
                clearPlaybackQuality()
                beginHDCDPlayback(decodeHDCD: decodeHDCD)
                playingTarget = target
                adoptFallbackOutput(choice)
                updateDisplayClock(for: started, at: currentFrame)
                output = started
                hasSelectedTrack = true
                playbackIsBuffering = true
                state = .playing
                beginMonitoring()
            }
        } catch is CancellationError {
            await finishCancelledPlayback(actionRevision: actionRevision)
        } catch {
            guard actionRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
    }

    public func nextTrack() async {
        guard controlsEnabled, let disc, let track = currentTrack else { return }
        if !hasSelectedTrack, let first = disc.tracks.first {
            // The disc total comes before track 1, as Previous on track 1 returns to it.
            await move(to: first.startFrame, in: disc)
            return
        }
        guard track.endFrame == disc.totalFrames else {
            await move(to: track.endFrame, in: disc)
            return
        }
        // Next on the last track never ends the disc; only playing to the end does.
        switch state {
        case .ready, .ended:
            await move(to: track.startFrame, in: disc)
        case .paused, .failed:
            // Keeps the position, so Play resumes there.
            await move(to: displayFrame(at: currentFrame), in: disc)
        case .playing, .empty:
            break
        }
    }

    public func previousTrack() async {
        guard controlsEnabled, let disc, let track = currentTrack,
              let index = disc.tracks.firstIndex(where: { $0.number == track.number }) else { return }
        let position = displayFrame(at: currentFrame)
        let restartsTrack = position - track.startFrame > 3 * disc.format.sampleRate
        if state == .ready || state == .ended, index == 0, !restartsTrack {
            // Before Play, after Stop or after the disc ended, Previous on the first track returns to the disc total.
            cancelPendingSeek()
            discardSleepPosition()
            revision &+= 1
            failure = nil
            currentFrame = 0
            hasSelectedTrack = false
            state = .ready
            return
        }
        let target = restartsTrack ? track.startFrame : disc.tracks[max(0, index - 1)].startFrame
        await move(to: target, in: disc)
    }

    public func scan(_ direction: ScanDirection) async {
        guard controlsEnabled, let disc else { return }
        let step = 10 * disc.format.sampleRate
        let position = displayFrame(at: currentFrame)
        let target: UInt64
        switch direction {
        case .backward:
            target = position > step ? position - step : 0
        case .forward:
            // Stops at the last whole step before the end; only playing to the end ends the disc.
            guard position + step < disc.totalFrames else { return }
            target = position + step
        }
        if source == .opticalDrive && state == .playing {
            queueDiscSeek(to: target)
        } else {
            await move(to: target, in: disc)
        }
    }

    private func move(to frame: UInt64, in disc: Disc) async {
        let wasSeeking = pendingSeek != nil
        cancelPendingSeek()
        discardSleepPosition()
        isBusy = true
        revision &+= 1
        let actionRevision = revision
        defer { isBusy = false }
        failure = nil
        if source == .opticalDrive {
            currentFrame = frame
            hasSelectedTrack = true
        }
        do {
            if wasSeeking && state != .playing && frame < disc.totalFrames {
                let snapshot = try await playbackEngine.stop()
                guard actionRevision == revision, !isShuttingDown else { return }
                updatePlaybackQuality(from: snapshot)
            }
            if frame == disc.totalFrames {
                monitor?.cancel()
                let snapshot = try await playbackEngine.stop()
                guard actionRevision == revision, !isShuttingDown else { return }
                updatePlaybackQuality(from: snapshot)
                await finishDisc(actionRevision: actionRevision)
                return
            } else if state == .playing {
                try Task.checkCancellation()
                let decodeHDCD = isHDCDDecodingEnabled
                let started = try await playbackEngine.start(at: frame, on: playingTarget, decodeHDCD: decodeHDCD)
                try Task.checkCancellation()
                guard actionRevision == revision, !isShuttingDown else { return }
                clearPlaybackQuality()
                beginHDCDPlayback(decodeHDCD: decodeHDCD)
                currentFrame = frame
                updateDisplayClock(for: started, at: frame, floor: frame)
                output = started
                playbackIsBuffering = true
                beginMonitoring()
            } else {
                currentFrame = frame
                state = state == .ready || state == .ended ? .ready : .paused
            }
            hasSelectedTrack = true
        } catch is CancellationError {
            await finishCancelledPlayback(actionRevision: actionRevision)
        } catch {
            guard actionRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
    }

    /// The disc played to its end. As after Stop, the disc is released and the display returns to the
    /// disc total; the status shows the end until the next action, and Play starts again at track 1.
    private func finishDisc(actionRevision: UInt64) async {
        if source == .opticalDrive { await closeDiscSession() }
        guard actionRevision == revision, !isShuttingDown else { return }
        currentFrame = 0
        bufferedFrames = 0
        playbackIsBuffering = false
        hasSelectedTrack = false
        state = .ended
    }

    private func finishCancelledPlayback(actionRevision: UInt64) async {
        guard actionRevision == revision, !isShuttingDown else { return }
        monitor?.cancel()
        do {
            let snapshot = try await playbackEngine.stop()
            guard actionRevision == revision, !isShuttingDown else { return }
            updatePlaybackQuality(from: snapshot)
            bufferedFrames = 0
            playbackIsBuffering = false
            if state == .playing { state = .paused }
            if source == .opticalDrive { await closeDiscSession() }
        } catch {
            guard actionRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
    }

    private func queueDiscSeek(to frame: UInt64) {
        cancelPendingSeek()
        discardSleepPosition()
        monitor?.cancel()
        revision &+= 1
        let actionRevision = revision
        let playback = playbackEngine
        let deadline = ContinuousClock.now.advanced(by: seekDelay)
        resetDisplayClock(at: frame)
        currentFrame = frame
        bufferedFrames = 0
        hasSelectedTrack = true
        failure = nil
        playbackIsBuffering = true
        pendingSeek = Task { [weak self] in
            guard let self else { return }
            defer {
                if actionRevision == self.revision { self.pendingSeek = nil }
            }
            do {
                try Task.checkCancellation()
                let stopped = try await playback.stop()
                try Task.checkCancellation()
                guard actionRevision == self.revision, !self.isShuttingDown else { return }
                self.updatePlaybackQuality(from: stopped)
                try await Task.sleep(until: deadline, clock: .continuous)
                guard actionRevision == self.revision, !self.isShuttingDown else { return }
                let decodeHDCD = self.isHDCDDecodingEnabled
                let started = try await playback.start(
                    at: frame, on: self.playingTarget, decodeHDCD: decodeHDCD
                )
                try Task.checkCancellation()
                guard actionRevision == self.revision, !self.isShuttingDown else { return }
                self.clearPlaybackQuality()
                self.beginHDCDPlayback(decodeHDCD: decodeHDCD)
                self.updateDisplayClock(for: started, at: frame, floor: frame)
                self.output = started
                self.playbackIsBuffering = true
                self.beginMonitoring()
            } catch is CancellationError {
                return
            } catch {
                guard actionRevision == self.revision, !self.isShuttingDown else {
                    self.logger.error("Discarded CD seek failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                await self.reportFailure(error, as: self.playbackErrorKind(error))
            }
        }
    }

    private func cancelPendingSeek() {
        pendingSeek?.cancel()
        pendingSeek = nil
    }

    private func preparePlaybackEngine() async -> (any PlaybackEngine)? {
        guard source == .opticalDrive else { return engine }
        let preparationRevision = revision
        guard let session = await prepareDiscSession(), preparationRevision == revision,
              discSession === session, !isShuttingDown else { return nil }
        if discEngine == nil { discEngine = makeDiscEngine(session) }
        return discEngine
    }

    public func stopOrEject() async {
        guard stopOrEjectEnabled else { return }
        if isStopAction {
            await stopPlayback()
        } else {
            await eject()
        }
    }

    private func stopPlayback() async {
        guard isStopAction, controlsEnabled else { return }
        cancelPendingSeek()
        discardSleepPosition()
        isBusy = true
        revision &+= 1
        let actionRevision = revision
        defer { isBusy = false }
        monitor?.cancel()
        failure = nil
        do {
            let snapshot = try await playbackEngine.stop()
            guard actionRevision == revision, !isShuttingDown else { return }
            if state == .playing { logPlaybackTotals("stopped", snapshot) }
            updatePlaybackQuality(from: snapshot)
            if source == .opticalDrive { await closeDiscSession() }
            guard actionRevision == revision, !isShuttingDown else { return }
            currentFrame = 0
            bufferedFrames = 0
            playbackIsBuffering = false
            clearPlaybackQuality()
            hasSelectedTrack = false
            state = .ready
        } catch {
            guard actionRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
    }

    public func eject() async {
        guard ejectEnabled else { return }
        let targetDrive = selectedDrive
        discardSleepPosition()
        isBusy = true
        isEjecting = true
        revision &+= 1
        defer { isBusy = false; isEjecting = false }
        monitor?.cancel()
        cancelPendingSeek()
        do {
            let snapshot = try await playbackEngine.stop()
            updatePlaybackQuality(from: snapshot)
            if state == .playing { logPlaybackTotals("ejected", snapshot) }
            guard !isShuttingDown else { return }
            if source == .opticalDrive {
                guard let opticalService, let drive = targetDrive, let media = drive.media else {
                    throw OpticalDriveError("The selected optical disc is no longer available.")
                }
                await closeDiscSession()
                guard !isShuttingDown else { return }
                try await opticalService.eject(media: media, from: drive.id)
                guard !isShuttingDown else { return }
                clearPlaybackQuality()
                clearHDCDPlaybackState(resetAppliedSetting: true)
                failure = nil
                reconcileOpticalState()
            } else {
                disc = nil
                currentFrame = 0
                bufferedFrames = 0
                clearPlaybackQuality()
                clearHDCDPlaybackState(resetAppliedSetting: true)
                state = .empty
                failure = nil
            }
        } catch {
            guard !isShuttingDown else { return }
            await reportFailure(error, as: .eject)
        }
    }

    public func insertDemoDisc() async {
        guard !isBusy, !isShuttingDown, !isPreparingForSleep else { return }
        discardSleepPosition()
        isBusy = true
        revision &+= 1
        defer { isBusy = false }
        monitor?.cancel()
        cancelPendingSeek()
        cancelDriveSelection()
        do {
            _ = try await playbackEngine.stop()
            await closeDiscSession()
            guard !isShuttingDown else { return }
            // A sleep that began meanwhile cannot bring back the CD's position.
            discardSleepPosition()
            clearPlaybackQuality()
            clearHDCDPlaybackState(resetAppliedSetting: true)
            source = .demo
            disc = .demo
            currentFrame = 0
            bufferedFrames = 0
            hasSelectedTrack = false
            state = .ready
            failure = nil
        } catch {
            await reportFailure(error, as: .audio)
        }
    }

    public func startOpticalMonitoring() {
        guard let opticalService, !opticalMonitoringStarted, !isShuttingDown else { return }
        do {
            try opticalService.start { [weak self] snapshot in self?.applyOpticalSnapshot(snapshot) }
            opticalMonitoringStarted = true
        } catch {
            opticalSnapshot = OpticalSnapshot(errorMessage: error.localizedDescription)
            if source == .opticalDrive { state = .failed }
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshOpticalDrives() {
        guard !isShuttingDown else { return }
        if opticalMonitoringStarted { opticalService?.refresh() }
        else { startOpticalMonitoring() }
    }

    public func useOpticalDrive(id: UInt64? = nil) async {
        guard opticalDriveSelectionEnabled else { return }
        discardSleepPosition()
        isBusy = true
        revision &+= 1
        defer { isBusy = false }
        monitor?.cancel()
        cancelPendingSeek()
        // Keep showing a pending drive until this explicit selection replaces it.
        driveSelection?.cancel()
        driveSelection = nil
        do {
            _ = try await playbackEngine.stop()
            guard !isShuttingDown else { return }
            if let id {
                guard opticalSnapshot.drives.contains(where: { $0.id == id }) else {
                    throw OpticalDriveError("The selected optical drive was disconnected.")
                }
                selectedDriveID = id
            }
            pendingDriveID = nil
            source = .opticalDrive
            disc = nil
            currentFrame = 0
            bufferedFrames = 0
            playbackIsBuffering = false
            clearPlaybackQuality()
            clearHDCDPlaybackState(resetAppliedSetting: true)
            hasSelectedTrack = false
            failure = nil
            await closeDiscSession()
            guard !isShuttingDown else { return }
            // A sleep that began meanwhile cannot switch back to the previous drive's position.
            discardSleepPosition()
            refreshOpticalDrives()
            reconcileOpticalState(reset: true)
        } catch {
            pendingDriveID = nil
            await reportFailure(error, as: error is OpticalDriveError ? .drive : .audio)
        }
    }

    /// Opens the selected audio CD for reading, for Play. An open session for the same disc is kept
    /// (for example, while paused). A refusal shows "Access denied" and is not retried.
    @discardableResult
    func openDiscSession() async -> DiscSession? {
        guard !isBusy, !isShuttingDown, !Task.isCancelled else { return nil }
        isBusy = true
        defer { isBusy = false }
        return await prepareDiscSession()
    }

    /// The body of `openDiscSession`, for callers that already hold the busy state.
    private func prepareDiscSession() async -> DiscSession? {
        guard source == .opticalDrive, !isShuttingDown, let drive = selectedDrive,
              let media = drive.media, let tableOfContents = media.contents.tableOfContents else { return nil }
        if let discSession, !discSessionIsStale { return discSession }
        let startRevision = revision
        await closeDiscSession()
        guard revision == startRevision, !isShuttingDown, !Task.isCancelled,
              selectedDrive?.id == drive.id, selectedDrive?.media?.id == media.id else { return nil }
        failure = nil
        let opener = discOpener
        let opening = OpeningDiscSession(driveID: drive.id, mediaID: media.id, task: Task {
            try await DiscSession.open(media, driveID: drive.id, tableOfContents: tableOfContents, opener: opener)
        })
        openingDiscSession = opening
        let result = await opening.task.result
        guard openingDiscSession?.id == opening.id else {
            await waitForDiscSessionCloses()
            return nil
        }
        guard revision == startRevision, !isShuttingDown, !Task.isCancelled,
              selectedDrive?.id == drive.id, selectedDrive?.media?.id == media.id else {
            await closeDiscSession()
            return nil
        }
        openingDiscSession = nil
        switch result {
        case .success(let session):
            discSession = session
            return session
        case .failure(let error):
            await reportFailure(error, as: (error as? CDReadError)?.kind == .refused ? .access : .disc)
            return nil
        }
    }

    /// A session whose disc is no longer the selected drive's disc in optical mode.
    private var discSessionIsStale: Bool {
        guard let driveID = discSession?.driveID ?? openingDiscSession?.driveID,
              let mediaID = discSession?.mediaID ?? openingDiscSession?.mediaID else { return false }
        if let discSession, discSession.disc != disc { return true }
        return source != .opticalDrive || driveID != selectedDriveID || mediaID != selectedDrive?.media?.id
            || opticalSnapshot.errorMessage != nil || selectedDrive?.issue != nil
            || selectedDrive?.media?.contents.tableOfContents == nil
    }

    /// Closes the disc after any read in progress has finished.
    private func closeDiscSession() async {
        scheduleDiscSessionClose()
        await waitForDiscSessionCloses()
    }

    private func scheduleDiscSessionClose() {
        guard discSession != nil || openingDiscSession != nil || discEngine != nil else { return }
        let session = discSession
        let playback = discEngine
        let opening = openingDiscSession?.task
        let previous = closingDiscSession?.task
        let logger = self.logger
        discSession = nil
        discEngine = nil
        openingDiscSession = nil
        closingDiscSession = ClosingDiscSession(task: Task {
            await previous?.value
            if let playback {
                do {
                    _ = try await playback.stop()
                } catch {
                    logger.error("Cannot stop discarded CD playback: \(error.localizedDescription, privacy: .public)")
                }
            }
            await session?.close()
            if let opening {
                switch await opening.result {
                case .success(let session):
                    await session.close()
                case .failure(let error):
                    logger.error("Discarded disc open failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        })
    }

    private func waitForDiscSessionCloses() async {
        while let closing = closingDiscSession {
            await closing.task.value
            if closingDiscSession?.id == closing.id { closingDiscSession = nil }
        }
    }

    /// Shows the next drive in connection order; it is selected and rescanned once clicking pauses.
    /// A lone drive (shown only after an error) becomes drive 1 of 1 and is rescanned the same way.
    public func selectNextDrive() {
        guard driveSelectorEnabled else { return }
        let drives = opticalSnapshot.drives
        let current = drives.firstIndex { $0.id == (pendingDriveID ?? selectedDriveID) }
        pendingDriveID = drives[current.map { ($0 + 1) % drives.count } ?? 0].id
        driveSelection?.cancel()
        let delay = driveSelectionDelay
        driveSelection = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.commitDriveSelection()
        }
    }

    func commitDriveSelection() async {
        guard let id = pendingDriveID else { return }
        driveSelection = nil
        await useOpticalDrive(id: id)
        // The selection could not be applied (for example, during shutdown).
        if pendingDriveID == id { pendingDriveID = nil }
    }

    private func cancelDriveSelection() {
        driveSelection?.cancel()
        driveSelection = nil
        pendingDriveID = nil
    }

    private func applyOpticalSnapshot(_ snapshot: OpticalSnapshot) {
        guard !isShuttingDown else { return }
        let previousDrive = selectedDrive
        let previousError = opticalSnapshot.errorMessage
        opticalSnapshot = snapshot
        if !snapshot.drives.contains(where: { $0.id == selectedDriveID }) {
            selectedDriveID = snapshot.drives.first { $0.media?.contents.tableOfContents != nil }?.id
                ?? snapshot.drives.first?.id
        }
        // After wake, macOS can reconnect the drive under a new ID after listing the others.
        if let name = sleepPosition?.driveName, selectedDrive?.name != name,
           let drive = snapshot.drives.first(where: { $0.name == name }) {
            selectedDriveID = drive.id
        }
        if source == .opticalDrive {
            let changed = previousDrive?.id != selectedDrive?.id ||
                previousDrive?.media?.id != selectedDrive?.media?.id ||
                previousDrive?.media?.bsdName != selectedDrive?.media?.bsdName ||
                previousDrive?.media?.contents != selectedDrive?.media?.contents ||
                previousDrive?.issue != selectedDrive?.issue || previousError != snapshot.errorMessage
            if changed {
                revision &+= 1
                monitor?.cancel()
                cancelPendingSeek()
                failure = nil
                clearPlaybackQuality()
                clearHDCDPlaybackState(resetAppliedSetting: true)
            }
            reconcileOpticalState(reset: changed)
            if changed {
                scheduleDiscSessionClose()
                resumeSleepPosition()
            }
        }
        // Checked last: the icon's visibility depends on the selection and error updated above.
        if let pendingDriveID,
           !showsDriveSelector || !snapshot.drives.contains(where: { $0.id == pendingDriveID }) {
            cancelDriveSelection()
        }
        // The disc was removed or replaced, or its drive disconnected.
        if discSessionIsStale { scheduleDiscSessionClose() }
    }

    private func reconcileOpticalState(reset: Bool = false) {
        guard source == .opticalDrive else { return }
        let timeline = selectedDrive?.media?.contents.tableOfContents.map { Disc(tableOfContents: $0) }
        if reset || disc != timeline {
            disc = timeline
            currentFrame = 0
            bufferedFrames = 0
            playbackIsBuffering = false
            clearPlaybackQuality()
            clearHDCDPlaybackState(resetAppliedSetting: true)
            hasSelectedTrack = false
        }
        if errorDetail != nil { state = .failed }
        else if disc != nil {
            if reset || state == .empty || state == .failed { state = .ready }
        }
        else { state = .empty }
    }

    public func refreshPlayback() async {
        guard state == .playing, pendingSeek == nil, !isBusy, !isShuttingDown, !isPreparingForSleep,
              let disc else { return }
        let snapshotRevision = revision
        do {
            let snapshot = try await playbackEngine.snapshot()
            guard snapshotRevision == revision, state == .playing, !isBusy, !isShuttingDown,
                  !isPreparingForSleep else { return }
            updatePlaybackQuality(from: snapshot)
            currentFrame = min(snapshot.currentFrame, disc.totalFrames)
            bufferedFrames = snapshot.bufferedFrames
            playbackIsInLeadIn = snapshot.leadIn
            displayPositionUpdatedAt = audioClock()
            // `@Published` notifies views on every assignment, so skip unchanged values on each poll.
            if snapshot.buffering != playbackIsBuffering {
                let seconds = Double(snapshot.currentFrame) / Double(disc.format.sampleRate)
                logger.notice("\(snapshot.buffering ? "Buffering began" : "Buffering ended", privacy: .public) at \(seconds, format: .fixed(precision: 2)) s; \(snapshot.underrunFrames) underrun frames so far")
                playbackIsBuffering = snapshot.buffering
            }
            if snapshot.finished {
                isBusy = true
                defer { isBusy = false }
                monitor?.cancel()
                let stopped = try await playbackEngine.stop()
                guard snapshotRevision == revision, !isShuttingDown else { return }
                updatePlaybackQuality(from: stopped)
                logPlaybackTotals("ended", stopped)
                await finishDisc(actionRevision: snapshotRevision)
            }
        } catch {
            guard snapshotRevision == revision, !isShuttingDown else { return }
            if (error as? AudioPlaybackError)?.code == Int32(CD_DEFAULT_OUTPUT_CHANGED.rawValue) {
                await followDefaultOutputChange(from: output, expectedRevision: snapshotRevision)
            } else if isOutputChange(error) {
                await pauseForOutputChange(output, expectedRevision: snapshotRevision)
            } else {
                await reportFailure(error, as: playbackErrorKind(error))
            }
        }
    }

    private func pauseForOutputChange(
        _ newOutput: OutputInfo? = nil, updateOutput: Bool = false, expectedRevision: UInt64
    ) async {
        guard expectedRevision == revision, state == .playing, !isBusy, !isShuttingDown,
              let disc else { return }
        isBusy = true
        revision &+= 1
        let pauseRevision = revision
        monitor?.cancel()
        defer { isBusy = false }
        do {
            let snapshot = try await playbackEngine.stop()
            guard pauseRevision == revision, !isShuttingDown else { return }
            updatePlaybackQuality(from: snapshot)
            logPlaybackTotals("paused by an output change", snapshot)
            currentFrame = min(snapshot.currentFrame, disc.totalFrames)
            bufferedFrames = 0
            playbackIsBuffering = false
            // Exclusive use by another app reports the same error as a missing output, so an output
            // with a known UID is named only when discovery no longer lists it.
            var lost: LostOutput?
            if updateOutput, newOutput == nil {
                lost = output.map { LostOutput(uid: $0.uid.isEmpty ? nil : $0.uid, name: $0.name) }
            } else if let output, !output.uid.isEmpty, !(await outputIsConnected(output.uid)) {
                guard pauseRevision == revision, !isShuttingDown else { return }
                lost = LostOutput(uid: output.uid, name: output.name)
            }
            if let lost { lostOutput = lost }
            if updateOutput { output = newOutput }
            state = .paused
            logger.notice("Audio output changed; CD playback paused.")
        } catch {
            guard pauseRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
        guard pauseRevision == revision, state == .paused, !isShuttingDown else { return }
        await refreshOutputChoices()
        await refreshOutput()
    }

    /// Playing on System Default, macOS chose another default output. If the previous output is still
    /// connected after `defaultOutputSettleDelay`, the user chose the new one and playback follows at the
    /// same position. If it disappeared, playback pauses rather than moving to, say, the speakers.
    private func followDefaultOutputChange(from previous: OutputInfo?, expectedRevision: UInt64) async {
        guard expectedRevision == revision, state == .playing, !isBusy, !isShuttingDown,
              let disc else { return }
        isBusy = true
        revision &+= 1
        let changeRevision = revision
        // The snapshot poll that found the change runs in the monitor task, so cancelling it here would
        // cancel the settle delay and restart. While busy, its polls do nothing.
        defer { isBusy = false }
        do {
            let snapshot = try await playbackEngine.stop()
            guard changeRevision == revision, !isShuttingDown else { return }
            updatePlaybackQuality(from: snapshot)
            let frame = min(snapshot.currentFrame, disc.totalFrames)
            currentFrame = frame
            bufferedFrames = 0
            playbackIsBuffering = false
            var stillConnected = await outputIsConnected(previous?.uid)
            if stillConnected {
                try await Task.sleep(for: defaultOutputSettleDelay)
                guard changeRevision == revision, !isShuttingDown else { return }
                stillConnected = await outputIsConnected(previous?.uid)
            }
            guard changeRevision == revision, !isShuttingDown else { return }
            if frame == disc.totalFrames {
                monitor?.cancel()
                logPlaybackTotals("ended", snapshot)
                await finishDisc(actionRevision: changeRevision)
            } else if stillConnected {
                logPlaybackTotals("moved to the new default output", snapshot)
                let decodeHDCD = activeHDCDDecodingEnabled ?? isHDCDDecodingEnabled
                let started = try await playbackEngine.start(
                    at: frame, on: .systemDefault, decodeHDCD: decodeHDCD
                )
                guard changeRevision == revision, !isShuttingDown else { return }
                clearPlaybackQuality()
                beginHDCDPlayback(decodeHDCD: decodeHDCD)
                updateDisplayClock(for: started, at: frame)
                output = started
                playingTarget = .systemDefault
                playbackIsBuffering = true
                beginMonitoring()
                logger.notice("Default output changed; CD playback moved to the new default output.")
            } else {
                monitor?.cancel()
                logPlaybackTotals("paused because the output disappeared", snapshot)
                state = .paused
                lostOutput = LostOutput(
                    uid: previous.flatMap { $0.uid.isEmpty ? nil : $0.uid },
                    name: previous?.name ?? "The audio output"
                )
                logger.notice("Default output disappeared; CD playback paused.")
                if let inspected = try? await engine.inspectOutput(on: .systemDefault, format: sourceFormat),
                   changeRevision == revision, !isShuttingDown {
                    output = inspected
                }
            }
        } catch is CancellationError {
            await finishCancelledPlayback(actionRevision: changeRevision)
        } catch {
            guard changeRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
        }
        await refreshOutputChoices()
    }

    /// Discovery lists only live outputs; a failed discovery counts as disconnected, so playback pauses.
    private func outputIsConnected(_ uid: String?) async -> Bool {
        guard let uid, !uid.isEmpty else { return false }
        do {
            return try await outputRateControl.discoverOutputs(format: sourceFormat).contains { $0.id == uid }
        } catch {
            logger.error("Cannot discover audio outputs: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sameOutput(_ lhs: OutputInfo, _ rhs: OutputInfo) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.outputDataSource == rhs.outputDataSource
            && lhs.name == rhs.name && lhs.usesSpeakers == rhs.usesSpeakers
    }

    private func isOutputChange(_ error: any Error) -> Bool {
        guard let error = error as? AudioPlaybackError else { return false }
        return error.code == Int32(CD_CONFIGURATION_CHANGED.rawValue)
            || error.code == Int32(CD_NO_BUILT_IN_OUTPUT.rawValue)
            || error.code == Int32(CD_OUTPUT_UNAVAILABLE.rawValue)
            || error.systemStatus == Int32(kAudioHardwareBadObjectError)
            || error.systemStatus == Int32(kAudioHardwareBadDeviceError)
    }

    /// Stops playback and closes the disc, then restores the output sample rates playback or the
    /// output-rate switch changed. A stop failure is reported in preference to a restore failure;
    /// both steps always run.
    public func shutdown() async throws {
        isShuttingDown = true
        updateVolumeMirror()
        revision &+= 1
        sleepPrevention.setActive(false)
        powerEvents?.cancel()
        sleepPositionExpiry?.cancel()
        monitor?.cancel()
        outputMonitor?.cancel()
        if let outputRateRecovery { await outputRateRecovery.value }
        cancelPendingSeek()
        cancelDriveSelection()
        opticalService?.stop()
        var stopFailure: (any Error)?
        do {
            _ = try await playbackEngine.stop()
        } catch {
            stopFailure = error
        }
        await closeDiscSession()
        // A rate switch in progress is recorded once it finishes, so it can be restored too.
        if let outputRateChange { await outputRateChange.value }
        do {
            try await outputRateControl.restoreChangedRates()
        } catch {
            guard stopFailure != nil else { throw error }
            logger.error("Cannot restore an output sample rate: \(error.localizedDescription, privacy: .public)")
        }
        if let stopFailure { throw stopFailure }
    }

    /// Listens for system sleep and wake for the rest of the app's life.
    public func startPowerMonitoring() {
        guard powerEvents == nil, !isShuttingDown else { return }
        let events = powerMonitor.events()
        powerEvents = Task { [weak self] in
            for await event in events {
                switch event {
                case .willSleep(let acknowledge):
                    guard let self else {
                        acknowledge()
                        return
                    }
                    self.systemWillSleep(acknowledge)
                case .didWake:
                    self?.systemDidWake()
                }
            }
        }
    }

    /// Sleep waits for the pause, but never longer than `sleepAcknowledgementLimit`.
    private func systemWillSleep(_ acknowledge: @escaping @Sendable () -> Void) {
        let acknowledgement = SleepAcknowledgement(acknowledge)
        let started = ContinuousClock.now
        let limit = sleepAcknowledgementLimit
        let logger = self.logger
        // Off the main actor, so sleep is allowed even if the main thread stalls.
        let timeout = Task.detached {
            do {
                try await Task.sleep(for: limit)
            } catch {
                return
            }
            if acknowledgement.send() {
                logger.error("Allowed system sleep after \(limit, privacy: .public) before the CD finished pausing")
            }
        }
        Task { [weak self] in
            await self?.prepareForSleep()
            timeout.cancel()
            if acknowledgement.send() {
                let elapsed = (ContinuousClock.now - started).components
                let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                logger.notice("Ready for system sleep after \(milliseconds, privacy: .public) ms")
            }
        }
    }

    /// Before sleep: pauses through the normal path and closes the disc, which restores the drive
    /// speed and releases the drive before macOS powers it down. The position is kept for wake.
    func prepareForSleep() async {
        guard !isShuttingDown, !isPreparingForSleep else { return }
        logger.notice("Preparing for system sleep")
        isPreparingForSleep = true
        defer { isPreparingForSleep = false }
        let wasSeeking = pendingSeek != nil
        let wasBusy = isBusy
        let earlierPosition = sleepPosition
        sleepPositionExpiry?.cancel()
        sleepPositionExpiry = nil
        // Kept now in case the drive disconnects before the pause finishes.
        sleepPosition = positionToKeepForWake() ?? earlierPosition
        cancelPendingSeek()
        cancelDriveSelection()
        monitor?.cancel()
        // Actions in progress, such as an opening Play, give up at their next revision check.
        revision &+= 1
        let sleepRevision = revision
        do {
            let snapshot = try await playbackEngine.stopBeforeSleep()
            if snapshot.outputRestorePending {
                restoresOutputAfterWake = true
                logger.notice("The output did not finish restoring before sleep; restoring it after wake")
            }
            if source == .opticalDrive { await closeDiscSession() }
            guard sleepRevision == revision, !isShuttingDown else { return }
            if state == .playing {
                updatePlaybackQuality(from: snapshot)
                logPlaybackTotals("paused for sleep", snapshot)
                bufferedFrames = 0
                playbackIsBuffering = false
                // A seek or track change in progress already shows its target.
                let settled = !wasSeeking && !wasBusy
                if settled, let disc { currentFrame = min(snapshot.currentFrame, disc.totalFrames) }
                if settled && snapshot.finished {
                    await finishDisc(actionRevision: sleepRevision)
                } else {
                    state = .paused
                }
            }
        } catch {
            guard sleepRevision == revision, !isShuttingDown else { return }
            await reportFailure(error, as: playbackErrorKind(error))
            return
        }
        guard sleepRevision == revision, !isShuttingDown else { return }
        sleepPosition = positionToKeepForWake() ?? earlierPosition
    }

    /// Starts the wake grace; a drive that reconnects within it gets its position back. An output
    /// restore that sleep held back is finished under the same rules as recovery at launch.
    func systemDidWake() {
        guard !isShuttingDown else { return }
        logger.notice("System woke")
        if restoresOutputAfterWake {
            restoresOutputAfterWake = false
            logger.notice("Restoring the output after wake")
            beginOutputRateRecovery()
        }
        guard sleepPosition != nil else { return }
        sleepPositionExpiry?.cancel()
        let grace = wakeGrace
        sleepPositionExpiry = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.sleepPosition = nil
            self.sleepPositionExpiry = nil
            self.logger.notice("The wake grace ended; the CD position is no longer kept")
        }
    }

    /// A paused CD, one about to pause, or a track chosen while stopped. The disc total needs nothing.
    private func positionToKeepForWake() -> SleepPosition? {
        guard source == .opticalDrive, !isEjecting, disc != nil, let drive = selectedDrive,
              let table = drive.media?.contents.tableOfContents else { return nil }
        let kept: PlayerState
        switch state {
        case .playing, .paused: kept = .paused
        case .ready where hasSelectedTrack: kept = .ready
        default: return nil
        }
        return SleepPosition(
            driveName: drive.name, tableOfContents: table, frame: currentFrame, state: kept,
            hasSelectedTrack: hasSelectedTrack, concealedSectors: concealedSectors, isUnverified: isUnverified
        )
    }

    /// After a reset, puts back the position kept at sleep once the same drive shows the same disc.
    /// It stays kept through the wake grace, as the drive may reconnect more than once.
    private func resumeSleepPosition() {
        guard let position = sleepPosition, let drive = selectedDrive, drive.name == position.driveName,
              let media = drive.media else { return }
        switch media.contents {
        case .reading, .unreadable:
            return
        case .audioCD(let table) where table == position.tableOfContents:
            guard let disc, errorDetail == nil else { return }
            currentFrame = min(position.frame, disc.totalFrames)
            hasSelectedTrack = position.hasSelectedTrack
            concealedSectors = position.concealedSectors
            isUnverified = position.isUnverified
            state = position.state
            logger.notice("Restored the CD position after sleep")
        default:
            logger.notice("A different disc after sleep; the CD position was discarded")
            discardSleepPosition()
        }
    }

    private func discardSleepPosition() {
        sleepPosition = nil
        sleepPositionExpiry?.cancel()
        sleepPositionExpiry = nil
    }

    private func updateSleepPrevention() {
        sleepPrevention.setActive(state == .playing && !isShuttingDown)
    }

    private func beginMonitoring() {
        monitor?.cancel()
        guard automaticallyMonitor else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch is CancellationError {
                    return
                } catch {
                    await self?.reportFailure(error, as: .audio)
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshPlayback()
            }
        }
    }

    private func reportFailure(_ error: any Error, as kind: PlayerErrorKind) async {
        guard !isShuttingDown else {
            logger.error("\(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let wasBusy = isBusy
        isBusy = true
        revision &+= 1
        let failureRevision = revision
        defer { isBusy = wasBusy }
        monitor?.cancel()
        cancelPendingSeek()
        var message = error.localizedDescription
        let wasPlaying = state == .playing
        state = .failed
        failure = (kind, message)
        logger.error("\(kind.rawValue, privacy: .public): \(message, privacy: .public)")
        let snapshot: PlaybackSnapshot?
        do {
            snapshot = try await playbackEngine.stop()
        } catch {
            snapshot = nil
            message += " Cleanup failed: \(error.localizedDescription)"
            logger.error("\(kind.rawValue, privacy: .public): \(message, privacy: .public)")
        }
        if source == .opticalDrive { await closeDiscSession() }
        guard failureRevision == revision, !isShuttingDown else { return }
        if let snapshot {
            updatePlaybackQuality(from: snapshot)
            if wasPlaying {
                logPlaybackTotals("stopped by an error", snapshot)
                if let disc { currentFrame = min(snapshot.currentFrame, disc.totalFrames) }
            }
        }
        failure = (kind, message)
    }

    /// One line per playback run; the counts reset when Play starts the next run.
    private func logPlaybackTotals(_ outcome: String, _ snapshot: PlaybackSnapshot) {
        let seconds = Double(snapshot.currentFrame) / Double(sourceFormat.sampleRate)
        logger.notice("Playback \(outcome, privacy: .public) at \(seconds, format: .fixed(precision: 2)) s: \(snapshot.underrunFrames) underrun frames; \(snapshot.concealedSectors) concealed sectors.")
    }

    private func playbackErrorKind(_ error: any Error) -> PlayerErrorKind {
        guard source == .opticalDrive else { return .audio }
        let readKind = (error as? CDReadError)?.kind ?? (error as? AudioPlaybackError)?.discReadErrorKind
        guard let readKind else { return .audio }
        switch readKind {
        case .refused: return .access
        case .gone, .failed: return .disc
        case .mediaError: return .read
        }
    }

    private func updatePlaybackQuality(from snapshot: PlaybackSnapshot) {
        if concealedSectors != snapshot.concealedSectors { concealedSectors = snapshot.concealedSectors }
        if isUnverified != snapshot.unverified { isUnverified = snapshot.unverified }
        guard snapshot.hdcdStatus != .notApplicable else { return }
        let status = Self.mergedHDCDStatus(discHDCDStatus, after: snapshot.hdcdStatus)
        if discHDCDStatus != status { discHDCDStatus = status }
        // Until a run decides whether to decode, its state is not yet known; keep the last run's, so
        // a Play, skip or seek on a decoded disc does not show 16-bit for a moment.
        guard snapshot.hdcdStatus != .detecting else { return }
        if playbackHDCDDecoded != snapshot.hdcdDecoded { playbackHDCDDecoded = snapshot.hdcdDecoded }
        if playbackPhysicalOutputBits != snapshot.physicalOutputBits {
            playbackPhysicalOutputBits = snapshot.physicalOutputBits
        }
    }

    /// Found HDCD stays found for the disc, and effectual outranks no effect, as in the engine.
    private static func mergedHDCDStatus(
        _ disc: HDCDPlaybackStatus, after run: HDCDPlaybackStatus
    ) -> HDCDPlaybackStatus {
        switch (disc, run) {
        case (.effectual, _), (.noEffect, .effectual): return .effectual
        case (.noEffect, _): return .noEffect
        default: return run
        }
    }

    private func beginHDCDPlayback(decodeHDCD: Bool) {
        activeHDCDDecodingEnabled = decodeHDCD
        guard source == .opticalDrive else {
            clearHDCDPlaybackState(resetAppliedSetting: false)
            return
        }
        if !isHDCDDisc { discHDCDStatus = .detecting }
        // With the setting off this run cannot decode, so the text need not wait for the engine.
        if !decodeHDCD { playbackHDCDDecoded = false }
    }

    private func clearHDCDPlaybackState(resetAppliedSetting: Bool) {
        if resetAppliedSetting { activeHDCDDecodingEnabled = nil }
        discHDCDStatus = .notApplicable
        playbackHDCDDecoded = false
        playbackPhysicalOutputBits = 0
    }

    private func clearPlaybackQuality() {
        concealedSectors = 0
        isUnverified = false
    }
}
