import Foundation

public enum DiscReadPacingPolicy: String, Sendable {
    case steady
    case burst
}

public enum HDCDPlaybackStatus: Int32, Equatable, Sendable {
    case notApplicable = 0
    case detecting
    case none
    case noEffect
    case effectual
}

/// Which output playback, inspection and the output-rate switch act on.
public enum OutputTarget: Hashable, Sendable {
    /// The 1.0.0 rule: the built-in output that is the default, else built-in headphones, else another.
    case builtIn
    /// Whatever macOS uses as its default output when playback starts, played best effort.
    case systemDefault
    /// A wired output identified by its persistent Core Audio UID.
    case device(uid: String)
}

public struct OutputInfo: Equatable, Sendable {
    public let deviceID: UInt32
    public let uid: String
    public let transport: OutputTransport
    public let name: String
    public let sampleRate: Double
    /// Another process's exclusive (hog-mode) owner, or -1; playback shares the output.
    public let hogOwner: Int32
    /// The output offers the source's rate (44.1 kHz for an audio CD).
    public let supportsSourceRate: Bool
    /// The system default output, controlled by the volume keys and menu-bar slider.
    public let isDefaultOutput: Bool
    public let usesSpeakers: Bool
    /// The active jack/source on devices that keep the same device ID for headphones and speakers.
    public let outputDataSource: UInt32?
    public let isRunning: Bool
    /// The rate the output-rate switch restores while the output is at the source rate: the one recorded when
    /// playback or the switch replaced it, else 48 kHz; 0 when that rate is unsupported.
    public let restoreRate: Double
    public let outputChannels: UInt32
    public let terminalType: UInt32
    /// System Default only: macOS converts the rate or channel layout, because the output cannot take
    /// the source's rate in stereo directly. Playback reports the path it used; inspection predicts it.
    public let converts: Bool
    /// Core Audio's reported stream latency, in seconds; nil when the output does not report it.
    public let streamLatencySeconds: Double?
    /// The output has a host volume control; without one, volume is set on the device itself.
    public let hasVolumeControl: Bool

    public init(
        deviceID: UInt32, name: String, sampleRate: Double, hogOwner: Int32,
        supportsSourceRate: Bool, isDefaultOutput: Bool = false, usesSpeakers: Bool, isRunning: Bool = false,
        outputDataSource: UInt32? = nil, restoreRate: Double = 0, uid: String = "",
        transport: OutputTransport = .builtIn, outputChannels: UInt32 = 2, terminalType: UInt32 = 0,
        converts: Bool = false, streamLatencySeconds: Double? = nil, hasVolumeControl: Bool = true
    ) {
        self.deviceID = deviceID
        self.uid = uid
        self.transport = transport
        self.name = name
        self.sampleRate = sampleRate
        self.hogOwner = hogOwner
        self.supportsSourceRate = supportsSourceRate
        self.isDefaultOutput = isDefaultOutput
        self.usesSpeakers = usesSpeakers
        self.outputDataSource = outputDataSource
        self.isRunning = isRunning
        self.restoreRate = restoreRate
        self.outputChannels = outputChannels
        self.terminalType = terminalType
        self.converts = converts
        self.streamLatencySeconds = streamLatencySeconds
        self.hasVolumeControl = hasVolumeControl
    }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public let currentFrame: UInt64
    public let underrunFrames: UInt64
    public let bufferedFrames: Int
    /// Startup/recovery silence; transport remains active and elapsed time does not advance.
    public let buffering: Bool
    /// Intentional HDMI/DisplayPort lead-in silence; source position does not advance.
    public let leadIn: Bool
    public let finished: Bool
    /// Damaged physical sectors concealed in this playback run, counted once per LBA.
    public let concealedSectors: UInt64
    /// Latched for the run when alignment or independent checking could not be established.
    public let unverified: Bool
    /// Optional callback checksum, populated only for explicitly silent hardware validation.
    public let pcmChecksum: UInt64
    /// HDCD detection result for the loaded disc; this does not imply decoding is enabled.
    public let hdcdStatus: HDCDPlaybackStatus
    /// Whether the audio at `currentFrame` is decoded HDCD. A run can start undecoded and switch at a
    /// later track start, and the producer reads ahead of the playing position, so this follows what plays.
    public let hdcdDecoded: Bool
    /// Physical output word length reported by Core Audio, or zero when unavailable.
    public let physicalOutputBits: UInt32
    /// Set only by `stopBeforeSleep()`: the output's rate or format restore did not finish, and the
    /// output is marked for `OutputRateControl.recoverPendingRates()` after wake.
    public let outputRestorePending: Bool

    public init(
        currentFrame: UInt64, underrunFrames: UInt64 = 0, bufferedFrames: Int = 0,
        buffering: Bool = false, leadIn: Bool = false, finished: Bool = false, concealedSectors: UInt64 = 0,
        unverified: Bool = false, pcmChecksum: UInt64 = PCMChecksum.initialValue,
        hdcdStatus: HDCDPlaybackStatus = .notApplicable, hdcdDecoded: Bool = false,
        physicalOutputBits: UInt32 = 0,
        outputRestorePending: Bool = false
    ) {
        self.currentFrame = currentFrame
        self.underrunFrames = underrunFrames
        self.bufferedFrames = bufferedFrames
        self.buffering = buffering
        self.leadIn = leadIn
        self.finished = finished
        self.concealedSectors = concealedSectors
        self.unverified = unverified
        self.pcmChecksum = pcmChecksum
        self.hdcdStatus = hdcdStatus
        self.hdcdDecoded = hdcdDecoded
        self.physicalOutputBits = physicalOutputBits
        self.outputRestorePending = outputRestorePending
    }
}

public protocol PlaybackEngine: Sendable {
    /// Reports the output Play would use for a source in `format`, without changing it.
    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo
    /// An output kept from the previous start is reused for the same target and released for another.
    func start(at frame: UInt64, on target: OutputTarget) async throws -> OutputInfo
    /// Starts with the HDCD preference selected for this Play, track start or seek.
    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) async throws -> OutputInfo
    func snapshot() async throws -> PlaybackSnapshot
    func stop() async throws -> PlaybackSnapshot
    /// Stops as `stop()` does before system sleep. Once sleep begins, macOS can hold an output change
    /// until wake, so a restore that does not finish sets `outputRestorePending` instead of throwing.
    func stopBeforeSleep() async throws -> PlaybackSnapshot
}

public extension PlaybackEngine {
    func start(at frame: UInt64) async throws -> OutputInfo { try await start(at: frame, on: .builtIn) }
    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) async throws -> OutputInfo {
        try await start(at: frame, on: target)
    }
    func stopBeforeSleep() async throws -> PlaybackSnapshot { try await stop() }
}

/// Switches the output Play would use between the source's rate (44.1 kHz for an audio CD) and the rate
/// it replaced, only while no playback holds the output, and puts back at quit every rate changed for the source.
public protocol OutputRateControl: Sendable {
    /// Restores only crash-recovery records, leaving rate changes made in this process alone.
    func recoverPendingRates() async throws
    /// Sets the source's rate and records the replaced rate, so playback leaves the rate as it is.
    func matchSourceRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo
    /// Sets an output at the source's rate to its `OutputInfo.restoreRate`; one at another rate keeps it.
    func restoreRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo
    /// Call at quit, after playback stops: restores every output still at a source rate that playback
    /// or the switch set.
    func restoreChangedRates() async throws
    /// Inspects all live outputs for a source in `format`, without changing their rates.
    func discoverOutputs(format: AudioSourceFormat) async throws -> [AudioOutputDevice]
    /// Yields when outputs come or go, the default output changes, or an output's rate or owner changes.
    func changes() -> AsyncStream<Void>
}

public extension OutputRateControl {
    func recoverPendingRates() async throws {}
    func discoverOutputs(format: AudioSourceFormat) async throws -> [AudioOutputDevice] { [] }
}
