import CDAudioCore
import Dispatch
import Foundation
import OSLog

public struct AudioPlaybackError: LocalizedError, Sendable {
    public let message: String
    public let code: Int32
    public let systemStatus: Int32

    public var errorDescription: String? { message }

    init(message: String, code: Int32, systemStatus: Int32) {
        self.message = message
        self.code = code
        self.systemStatus = systemStatus
    }

    var discReadErrorKind: CDReadError.Kind? {
        switch code {
        case Int32(CD_DISC_REFUSED.rawValue): return .refused
        case Int32(CD_DISC_GONE.rawValue): return .gone
        case Int32(CD_DISC_READ_ERROR.rawValue), Int32(CD_READ_TIMEOUT.rawValue): return .mediaError
        case Int32(CD_DISC_FAILED.rawValue): return .failed
        default: return nil
        }
    }

    init(_ error: CDError) {
        message = decodeCString(error.message)
        code = error.code
        systemStatus = error.systemStatus
    }
}

func decodeCString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Only `requestStop` may run concurrently; every other call belongs to the audio worker queue.
protocol AudioPlaybackDriver: AnyObject, Sendable {
    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) throws -> OutputInfo
    func start(at frame: UInt64, on target: OutputTarget) throws -> OutputInfo
    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) throws -> OutputInfo
    func enableOutput()
    func requestStop()
    func snapshot() throws -> PlaybackSnapshot
    func stop() throws -> PlaybackSnapshot
    func stopBeforeSleep() throws -> PlaybackSnapshot
}

extension AudioPlaybackDriver {
    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) throws -> OutputInfo {
        try start(at: frame, on: target)
    }
    func stopBeforeSleep() throws -> PlaybackSnapshot { try stop() }
}

/// Inspects an output on the audio worker queue without a driver.
typealias AudioOutputInspector = @Sendable (OutputTarget, AudioSourceFormat) throws -> OutputInfo

private final class AudioHandle: AudioPlaybackDriver, @unchecked Sendable {
    let pointer: OpaquePointer

    init(disc: Disc, levelSource: CoreAudioLevelSource) throws {
        let tracks = try disc.tracks.map { track in
            guard let tone = track.tone else {
                throw AudioPlaybackError(CDError(
                    result: CD_INVALID_ARGUMENT, message: "A physical disc requires an open disc session, not a demo source."
                ))
            }
            return CDDemoTrack(frameCount: track.frameCount, frequency: tone.frequency, amplitude: tone.amplitude)
        }
        var error = CDError()
        let levelTable = try levelSource.playbackTable()
        guard let pointer = tracks.withUnsafeBufferPointer({
            cd_playback_create_with_levels(
                $0.baseAddress, $0.count, Int(CD_PLAYBACK_BUFFER_FRAMES), levelTable, &error
            )
        }) else {
            throw AudioPlaybackError(error)
        }
        self.pointer = pointer
    }

    init(
        session: DiscSession, silentOutput: Bool, readPacing: DiscReadPacingPolicy,
        levelSource: CoreAudioLevelSource
    ) throws {
        pointer = try makePCMPlayback(
            source: DiscPCMSource(session: session, readPacing: readPacing),
            bufferFrames: Int(CD_PLAYBACK_BUFFER_FRAMES),
            silentOutput: silentOutput, levelSource: levelSource
        )
    }

    deinit {
        var error = CDError()
        if cd_playback_destroy(pointer, &error) != 0 {
            let message = decodeCString(error.message)
            Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Audio")
                .fault("Audio cleanup failed; retaining callback storage until exit: \(message, privacy: .public)")
        }
    }

    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) throws -> OutputInfo {
        try Self.inspect(on: target, format: format)
    }

    /// Inspection reads only Core Audio, so it needs no playback or read-ahead buffer.
    static func inspect(on target: OutputTarget, format: AudioSourceFormat) throws -> OutputInfo {
        var info = CDDeviceInfo()
        var error = CDError()
        let result = target.withCoreAudioUID { coreTarget, uid in
            cd_audio_inspect(coreTarget, uid, Double(format.sampleRate), &info, &error)
        }
        guard result == 0 else { throw AudioPlaybackError(error) }
        return OutputInfo(info)
    }

    func start(at frame: UInt64, on target: OutputTarget) throws -> OutputInfo {
        try start(at: frame, on: target, decodeHDCD: true)
    }

    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) throws -> OutputInfo {
        var info = CDDeviceInfo()
        var error = CDError()
        let result = target.withCoreAudioUID { coreTarget, uid in
            cd_playback_start(pointer, frame, coreTarget, uid, decodeHDCD, &info, &error)
        }
        guard result == 0 else {
            throw AudioPlaybackError(error)
        }
        return OutputInfo(info)
    }

    func enableOutput() { cd_playback_enable_output(pointer) }

    func requestStop() { cd_playback_request_stop(pointer) }

    func snapshot() throws -> PlaybackSnapshot {
        var snapshot = CDPlaybackSnapshot()
        var error = CDError()
        guard cd_playback_snapshot(pointer, &snapshot, &error) == 0 else {
            throw AudioPlaybackError(error)
        }
        return try PlaybackSnapshot(snapshot)
    }

    func stop() throws -> PlaybackSnapshot {
        var snapshot = CDPlaybackSnapshot()
        var error = CDError()
        guard cd_playback_stop(pointer, &snapshot, &error) == 0 else {
            throw AudioPlaybackError(error)
        }
        return try PlaybackSnapshot(snapshot)
    }

    func stopBeforeSleep() throws -> PlaybackSnapshot {
        var snapshot = CDPlaybackSnapshot()
        var error = CDError()
        guard cd_playback_stop_before_sleep(pointer, &snapshot, &error) == 0 else {
            throw AudioPlaybackError(error)
        }
        return try PlaybackSnapshot(snapshot)
    }
}

public final class CoreAudioPlaybackEngine: PlaybackEngine, Sendable {
    private let worker: AudioPlaybackWorker

    public init(disc: Disc = .demo, levelSource: CoreAudioLevelSource = .shared) {
        worker = AudioPlaybackWorker(inspect: { try AudioHandle.inspect(on: $0, format: $1) }) {
            try AudioHandle(disc: disc, levelSource: levelSource)
        }
    }

    /// The first PCM read requests minimum drive speed. The caller must stop the engine,
    /// then close its session to restore the original speed and release the disc.
    public init(
        session: DiscSession, silentOutput: Bool = false, readPacing: DiscReadPacingPolicy = .steady,
        levelSource: CoreAudioLevelSource = .shared
    ) {
        worker = AudioPlaybackWorker(inspect: { try AudioHandle.inspect(on: $0, format: $1) }) {
            try AudioHandle(
                session: session, silentOutput: silentOutput, readPacing: readPacing, levelSource: levelSource
            )
        }
    }

    /// Without `inspect`, inspection goes through the driver, creating it if needed.
    init(
        inspect: AudioOutputInspector? = nil,
        makeDriver: @escaping @Sendable () throws -> any AudioPlaybackDriver
    ) {
        worker = AudioPlaybackWorker(inspect: inspect, makeDriver: makeDriver)
    }

    public func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo {
        try await worker.inspectOutput(on: target, format: format)
    }

    public func start(at frame: UInt64, on target: OutputTarget) async throws -> OutputInfo {
        try await worker.start(at: frame, on: target, decodeHDCD: true)
    }

    public func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) async throws -> OutputInfo {
        try await worker.start(at: frame, on: target, decodeHDCD: decodeHDCD)
    }

    public func snapshot() async throws -> PlaybackSnapshot {
        try await worker.snapshot()
    }

    public func stop() async throws -> PlaybackSnapshot {
        try await worker.stop()
    }

    public func stopBeforeSleep() async throws -> PlaybackSnapshot {
        try await worker.stop(beforeSleep: true)
    }
}

/// Blocking lifecycle calls and handle destruction stay on this queue. The lock protects
/// request ownership and the handle's publication, never a read, join, or Core Audio call.
private final class AudioPlaybackWorker: @unchecked Sendable {
    private final class StartRequest: @unchecked Sendable {
        // Protected by the worker's lock, including cancellation before the request is queued.
        var cancelled = false
    }

    private final class DriverHandoff: @unchecked Sendable {
        // Filled before the hand-off; afterwards only the queue touches it.
        var driver: (any AudioPlaybackDriver)?

        init(_ driver: (any AudioPlaybackDriver)?) { self.driver = driver }
    }

    private let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.audio-worker", qos: .userInitiated)
    private let lock = NSLock()
    private let inspect: AudioOutputInspector?
    private let makeDriver: @Sendable () throws -> any AudioPlaybackDriver
    private var driver: (any AudioPlaybackDriver)?
    private var currentStart: StartRequest?

    init(
        inspect: AudioOutputInspector? = nil,
        makeDriver: @escaping @Sendable () throws -> any AudioPlaybackDriver
    ) {
        self.inspect = inspect
        self.makeDriver = makeDriver
    }

    deinit {
        guard driver != nil else { return }
        // Keep no reference here: one released after the queued block would destroy the
        // handle on this thread, which is often the main thread.
        let handoff = DriverHandoff(driver)
        driver = nil
        handoff.driver?.requestStop()
        queue.async { handoff.driver = nil }
    }

    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo {
        try await perform {
            if let inspect = self.inspect { return try inspect(target, format) }
            return try self.getDriver().inspectOutput(on: target, format: format)
        }
    }

    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) async throws -> OutputInfo {
        let request = StartRequest()
        return try await withTaskCancellationHandler {
            try await perform(preparing: {
                guard !request.cancelled else { throw CancellationError() }
                self.currentStart?.cancelled = true
                self.currentStart = request
                self.driver?.requestStop()
            }) {
                try self.start(request, at: frame, on: target, decodeHDCD: decodeHDCD)
            }
        } onCancel: {
            self.lock.withLock {
                request.cancelled = true
                if self.currentStart === request {
                    self.driver?.requestStop()
                    self.currentStart = nil
                }
            }
        }
    }

    func snapshot() async throws -> PlaybackSnapshot {
        try await perform {
            try self.existingDriver()?.snapshot() ?? PlaybackSnapshot(currentFrame: 0)
        }
    }

    func stop(beforeSleep: Bool = false) async throws -> PlaybackSnapshot {
        try await perform(preparing: {
            self.currentStart?.cancelled = true
            self.currentStart = nil
            self.driver?.requestStop()
        }) {
            guard let driver = self.existingDriver() else { return PlaybackSnapshot(currentFrame: 0) }
            return try beforeSleep ? driver.stopBeforeSleep() : driver.stop()
        }
    }

    private func start(
        _ request: StartRequest, at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool
    ) throws -> OutputInfo {
        defer {
            lock.withLock {
                if currentStart === request { currentStart = nil }
            }
        }
        try check(request)
        let driver = try getDriver()
        do {
            try check(request)
            let info = try driver.start(at: frame, on: target, decodeHDCD: decodeHDCD)
            try lock.withLock {
                guard currentStart === request, !request.cancelled else { throw CancellationError() }
                driver.enableOutput()
                currentStart = nil
            }
            return info
        } catch {
            let original = error
            driver.requestStop()
            do {
                _ = try driver.stop()
            } catch {
                throw PlaybackCleanupError(original: original, cleanup: error)
            }
            throw original
        }
    }

    private func check(_ request: StartRequest) throws {
        try lock.withLock {
            guard currentStart === request, !request.cancelled else { throw CancellationError() }
        }
    }

    private func existingDriver() -> (any AudioPlaybackDriver)? {
        lock.withLock { driver }
    }

    private func getDriver() throws -> any AudioPlaybackDriver {
        if let driver = existingDriver() { return driver }
        let driver = try makeDriver()
        lock.withLock { self.driver = driver }
        return driver
    }

    private func perform<Value: Sendable>(
        preparing: @Sendable () throws -> Void = {},
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try lock.withLock {
                    try preparing()
                    queue.async {
                        do {
                            continuation.resume(returning: try operation())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct PlaybackCleanupError: LocalizedError {
    let original: any Error
    let cleanup: any Error

    var errorDescription: String? {
        "\(original.localizedDescription) Cleanup failed: \(cleanup.localizedDescription)"
    }
}

extension OutputInfo {
    init(_ info: CDDeviceInfo) {
        self.init(
            deviceID: info.deviceID,
            name: decodeCString(info.name),
            sampleRate: info.sampleRate,
            hogOwner: info.hogOwner,
            supportsSourceRate: info.supportsSourceRate,
            isDefaultOutput: info.isDefaultOutput,
            usesSpeakers: info.usesSpeakers,
            isRunning: info.isRunning,
            outputDataSource: info.hasOutputDataSource ? info.outputDataSource : nil,
            restoreRate: info.restoreRate,
            uid: decodeCString(info.uid),
            transport: OutputTransport(coreAudioValue: info.transportType),
            outputChannels: info.outputChannels,
            terminalType: info.outputTerminalType,
            converts: info.converts,
            streamLatencySeconds: info.hasStreamLatency && info.sampleRate > 0
                ? Double(info.streamLatencyFrames) / info.sampleRate
                : nil,
            hasVolumeControl: info.hasVolumeControl
        )
    }
}

extension OutputTarget {
    var coreValue: CDOutputTarget {
        switch self {
        case .builtIn: return CD_TARGET_BUILT_IN
        case .systemDefault: return CD_TARGET_SYSTEM_DEFAULT
        case .device: return CD_TARGET_DEVICE
        }
    }

    func withCoreAudioUID<Value>(_ body: (CDOutputTarget, UnsafePointer<CChar>?) -> Value) -> Value {
        switch self {
        case .device(let uid):
            uid.withCString { body(coreValue, $0) }
        case .builtIn, .systemDefault:
            body(coreValue, nil)
        }
    }
}

private extension PlaybackSnapshot {
    init(_ snapshot: CDPlaybackSnapshot) throws {
        guard let hdcdStatus = HDCDPlaybackStatus(coreAudioValue: snapshot.hdcdStatus) else {
            throw AudioPlaybackError(CDError(
                result: CD_INVALID_ARGUMENT, message: "The playback engine returned an unknown HDCD state."
            ))
        }
        self.init(
            currentFrame: snapshot.currentFrame,
            underrunFrames: snapshot.underrunFrames,
            bufferedFrames: snapshot.bufferedFrames,
            buffering: snapshot.buffering,
            leadIn: snapshot.leadIn,
            finished: snapshot.finished,
            concealedSectors: snapshot.concealedSectors,
            unverified: snapshot.unverified,
            pcmChecksum: snapshot.pcmChecksum,
            hdcdStatus: hdcdStatus,
            hdcdDecoded: snapshot.hdcdDecoded,
            physicalOutputBits: snapshot.physicalOutputBits,
            outputRestorePending: snapshot.outputRestorePending
        )
    }
}

private extension HDCDPlaybackStatus {
    init?(coreAudioValue: CDHDCDStatus) {
        switch coreAudioValue {
        case CD_HDCD_NOT_APPLICABLE: self = .notApplicable
        case CD_HDCD_DETECTING: self = .detecting
        case CD_HDCD_NONE: self = .none
        case CD_HDCD_NO_EFFECT: self = .noEffect
        case CD_HDCD_EFFECTUAL: self = .effectual
        default: return nil
        }
    }
}
