import CDAudioCore
import Foundation
@testable import CDKit

extension PlayerModel {
    /// A player for offline tests. It takes `PlayerModel.init`'s parameters, but every default that
    /// would reach the Mac or CI runner is a fake: the output list, rate switching and its restore
    /// record (kept in the installed app's preferences), the saved output, volume mirroring, sleep
    /// prevention, power events, disc access and Core Audio playback of a disc. Results then never
    /// depend on that machine's audio devices, and a test can never change them.
    /// The timing defaults match `PlayerModel.init`.
    static func offline(
        engine: any PlaybackEngine,
        audioLevelSource: any AudioLevelSource = FakeAudioLevelSource(),
        audioClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        automaticallyMonitor: Bool = true,
        opticalService: (any OpticalDriveService)? = nil,
        driveSelectionDelay: Duration = .seconds(1),
        discOpener: any DiscOpener = FakeDiscOpener(),
        seekDelay: Duration = .milliseconds(300),
        makeDiscEngine: @escaping @MainActor (DiscSession) -> any PlaybackEngine = { _ in FakeEngine() },
        outputRateControl: any OutputRateControl = FakeOutputRateControl(),
        outputSelectionStore: any OutputSelectionStore = FakeOutputSelectionStore(),
        hdcdDecodePreferenceStore: any HDCDDecodePreferenceStore = FakeHDCDDecodePreferenceStore(),
        volumeMirror: any VolumeMirroring = RecordingVolumeMirror(),
        sleepPrevention: any SleepPreventing = FakeSleepPrevention(),
        powerMonitor: any SystemPowerMonitoring = FakePowerMonitor(),
        wakeGrace: Duration = .seconds(60),
        sleepAcknowledgementLimit: Duration = .seconds(10),
        defaultOutputSettleDelay: Duration = .milliseconds(500)
    ) -> PlayerModel {
        PlayerModel(
            engine: engine, audioLevelSource: audioLevelSource, audioClock: audioClock,
            automaticallyMonitor: automaticallyMonitor, opticalService: opticalService,
            driveSelectionDelay: driveSelectionDelay, discOpener: discOpener, seekDelay: seekDelay,
            makeDiscEngine: makeDiscEngine, outputRateControl: outputRateControl,
            outputSelectionStore: outputSelectionStore, hdcdDecodePreferenceStore: hdcdDecodePreferenceStore,
            volumeMirror: volumeMirror,
            sleepPrevention: sleepPrevention, powerMonitor: powerMonitor, wakeGrace: wakeGrace,
            sleepAcknowledgementLimit: sleepAcknowledgementLimit, defaultOutputSettleDelay: defaultOutputSettleDelay
        )
    }
}

@MainActor
final class FakeHDCDDecodePreferenceStore: HDCDDecodePreferenceStore {
    private(set) var isEnabled: Bool
    private(set) var savedValues: [Bool] = []

    init(isEnabled: Bool = true) { self.isEnabled = isEnabled }

    func save(isEnabled: Bool) {
        self.isEnabled = isEnabled
        savedValues.append(isEnabled)
    }
}

final class FakeAudioLevelSource: AudioLevelSource, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let fromFrame: UInt64
        let throughFrame: UInt64
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var samples: [UInt64: AudioLevelPeaks] = [:]
    private let slotFrames = UInt64(CD_LEVEL_SLOT_FRAMES)

    var requests: [Request] { lock.withLock { recorded } }

    func set(_ peaks: AudioLevelPeaks, at frame: UInt64) {
        lock.withLock { samples[frame / slotFrames] = peaks }
    }

    func peaks(fromFrame: UInt64, throughFrame: UInt64) -> AudioLevelPeaks? {
        lock.withLock {
            recorded.append(Request(fromFrame: fromFrame, throughFrame: throughFrame))
            let firstSlot = fromFrame / slotFrames
            let lastSlot = throughFrame / slotFrames
            let values = samples
                .filter { $0.key >= firstSlot && $0.key <= lastSlot }
                .map(\.value)
            guard !values.isEmpty else { return nil }
            return AudioLevelPeaks(
                leftPeak: values.map(\.leftPeak).max() ?? 0,
                rightPeak: values.map(\.rightPeak).max() ?? 0
            )
        }
    }
}

final class FakeAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

/// Keeps the saved output in memory instead of the user defaults.
@MainActor
final class FakeOutputSelectionStore: OutputSelectionStore {
    private(set) var selectedID: OutputChoice.ID?
    private(set) var selectedName: String?
    private(set) var savedIDs: [OutputChoice.ID] = []
    private(set) var savedNames: [String] = []

    init(selectedID: OutputChoice.ID? = nil, selectedName: String? = nil) {
        self.selectedID = selectedID
        self.selectedName = selectedName
    }

    convenience init(selectedUID: String, selectedName: String? = nil) {
        self.init(selectedID: .device(uid: selectedUID), selectedName: selectedName)
    }

    func save(_ id: OutputChoice.ID) {
        if id != selectedID || id == .systemDefault { selectedName = nil }
        selectedID = id
        savedIDs.append(id)
    }

    func saveName(_ name: String, for id: OutputChoice.ID) {
        guard case .device = id, id == selectedID else { return }
        selectedName = name
        savedNames.append(name)
    }
}
