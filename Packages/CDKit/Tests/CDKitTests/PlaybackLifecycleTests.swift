import CDAudioCore
import CoreAudio
import Foundation
import Testing
@testable import CDKit

private final class AudioDriverProbe: @unchecked Sendable {
    enum Call: Equatable {
        case created, inspected, started(UInt64), enabled, stopRequested, stopping, stopped, destroyed
    }

    struct Entry {
        let call: Call
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []
    private var enabled = false
    private var retainedPlaybacks: [OfflinePCMPlayback] = []
    private var nextSnapshotFailure: AudioPlaybackError?

    var entries: [Entry] { lock.withLock { recorded } }
    var calls: [Call] { entries.map(\.call) }
    var outputEnabled: Bool { lock.withLock { enabled } }
    var playbacks: [OfflinePCMPlayback] { lock.withLock { retainedPlaybacks } }

    func retain(_ playback: OfflinePCMPlayback) {
        lock.withLock { retainedPlaybacks.append(playback) }
    }

    func failNextSnapshot(with error: AudioPlaybackError) {
        lock.withLock { nextSnapshotFailure = error }
    }

    func consumeSnapshotFailure() -> AudioPlaybackError? {
        lock.withLock {
            defer { nextSnapshotFailure = nil }
            return nextSnapshotFailure
        }
    }

    func record(_ call: Call) {
        lock.withLock {
            recorded.append(Entry(call: call, onMainThread: Thread.isMainThread))
            switch call {
            case .enabled: enabled = true
            case .stopRequested, .stopped, .destroyed: enabled = false
            default: break
            }
        }
    }
}

private struct ChecksumPCMSource: PCMSource {
    let frameCount: UInt64
    var format: AudioSourceFormat { .compactDisc }

    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16] {
        guard frame <= frameCount else { throw CDReadError(.failed, "The checksum test frame is out of range.") }
        let count = Int(min(UInt64(maxFrames), frameCount - frame))
        return pcmSamples(at: frame, count: count)
    }
}

private enum AudioDriverFailure: LocalizedError {
    case start, cleanup

    var errorDescription: String? {
        switch self {
        case .start: "The test output could not start."
        case .cleanup: "The test output could not be restored."
        }
    }
}

private final class FakeAudioDriver: AudioPlaybackDriver, @unchecked Sendable {
    private let probe: AudioDriverProbe
    private let startGate: TestGate?
    private let stopGate: TestGate?
    private let failsStart: Bool
    private let failsCleanup: Bool
    private var frame: UInt64 = 0

    init(
        probe: AudioDriverProbe, startGate: TestGate? = nil, stopGate: TestGate? = nil,
        failsStart: Bool = false, failsCleanup: Bool = false
    ) {
        self.probe = probe
        self.startGate = startGate
        self.stopGate = stopGate
        self.failsStart = failsStart
        self.failsCleanup = failsCleanup
        probe.record(.created)
    }

    deinit { probe.record(.destroyed) }

    func inspectOutput(on target: OutputTarget = .builtIn, format: AudioSourceFormat = .compactDisc) -> OutputInfo {
        probe.record(.inspected)
        return OutputInfo(
            deviceID: 1, name: "Offline output", sampleRate: 44_100, hogOwner: -1,
            supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: false
        )
    }

    func start(at frame: UInt64, on target: OutputTarget) throws -> OutputInfo {
        probe.record(.started(frame))
        try startGate?.wait()
        if failsStart { throw AudioDriverFailure.start }
        self.frame = frame
        return inspectOutput()
    }

    func enableOutput() { probe.record(.enabled) }
    func requestStop() { probe.record(.stopRequested) }
    func snapshot() -> PlaybackSnapshot { PlaybackSnapshot(currentFrame: frame) }

    func stop() throws -> PlaybackSnapshot {
        probe.record(.stopping)
        try stopGate?.wait()
        if failsCleanup { throw AudioDriverFailure.cleanup }
        probe.record(.stopped)
        return snapshot()
    }
}

/// Exercises the actual worker, producer and player model without acquiring an audio device.
private final class OfflinePCMDriver: AudioPlaybackDriver {
    let playback: OfflinePCMPlayback
    let probe: AudioDriverProbe

    init(playback: OfflinePCMPlayback, probe: AudioDriverProbe) {
        self.playback = playback
        self.probe = probe
        probe.record(.created)
    }

    deinit { probe.record(.destroyed) }

    func inspectOutput(on target: OutputTarget = .builtIn, format: AudioSourceFormat = .compactDisc) -> OutputInfo {
        probe.record(.inspected)
        return OutputInfo(
            deviceID: 1, name: "Offline PCM output", sampleRate: 44_100, hogOwner: -1,
            supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: false
        )
    }

    func start(at frame: UInt64, on target: OutputTarget) throws -> OutputInfo {
        probe.record(.started(frame))
        _ = try stop()
        try playback.prepare(at: frame)
        return inspectOutput()
    }

    func enableOutput() {
        cd_playback_enable_output(playback.pointer)
        probe.record(.enabled)
    }

    func requestStop() {
        cd_playback_request_stop(playback.pointer)
        probe.record(.stopRequested)
    }

    func snapshot() throws -> PlaybackSnapshot {
        if let failure = probe.consumeSnapshotFailure() { throw failure }
        return convert(try playbackSnapshot(playback.pointer))
    }

    func stop() throws -> PlaybackSnapshot {
        probe.record(.stopping)
        var snapshot = CDPlaybackSnapshot()
        var error = CDError()
        guard cd_playback_stop(playback.pointer, &snapshot, &error) == 0 else { throw AudioPlaybackError(error) }
        probe.record(.stopped)
        return convert(snapshot)
    }

    private func convert(_ snapshot: CDPlaybackSnapshot) -> PlaybackSnapshot {
        PlaybackSnapshot(
            currentFrame: snapshot.currentFrame, underrunFrames: snapshot.underrunFrames,
            bufferedFrames: snapshot.bufferedFrames, buffering: snapshot.buffering, finished: snapshot.finished,
            concealedSectors: snapshot.concealedSectors, unverified: snapshot.unverified,
            pcmChecksum: snapshot.pcmChecksum
        )
    }
}

private enum PCMStopAction: CaseIterable, Sendable {
    case pause, eject, quit
}

@Test(arguments: PCMStopAction.allCases, [false, true])
@MainActor private func allPlayerStopsMuteBlockedPCMAndIgnoreItsLateFailure(
    action: PCMStopAction, afterPlayback: Bool
) async throws {
    let blockedFrame = afterPlayback ? UInt64(CD_PLAYBACK_PREFILL_FRAMES) : 0
    let gate = PCMReadGate()
    gate.allow(through: blockedFrame)
    let source = TestPCMSource(frameCount: Disc.demo.totalFrames) { frame, capacity in
        let count = try gate.count(at: frame, capacity: capacity)
        if frame == blockedFrame {
            throw CDReadError(.gone, "The cancelled read must not become a player error.", systemError: ENXIO)
        }
        return pcmSamples(at: frame, count: count)
    }
    let playback = try OfflinePCMPlayback(source: source)
    defer { gate.allow(through: .max) }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine { OfflinePCMDriver(playback: playback, probe: probe) }
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    try await waitUntil { gate.waitingAt == blockedFrame }
    let first = renderPlayback(playback.pointer, frames: 128)
    let playedFrames: UInt64 = afterPlayback ? 128 : 0
    if afterPlayback {
        #expect(first == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    } else {
        #expect(first.allSatisfy { $0 == 0 })
    }
    await model.refreshPlayback()
    #expect(model.currentFrame == playedFrames)
    #expect(model.isBuffering == !afterPlayback)
    let previousStops = probe.calls.filter { $0 == .stopping }.count
    var completed = false
    let stopping = Task {
        switch action {
        case .pause: await model.togglePlayback()
        case .eject: await model.eject()
        case .quit: try await model.shutdown()
        }
        completed = true
    }
    try await waitUntil { probe.calls.filter { $0 == .stopping }.count > previousStops }
    #expect(!completed && !probe.outputEnabled && !model.controlsEnabled)
    for _ in 0..<4 {
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    }
    gate.allow(through: .max)
    try await stopping.value
    let result = try playbackSnapshot(playback.pointer)
    #expect(result.currentFrame == playedFrames && result.bufferedFrames == Int(blockedFrame - playedFrames))
    #expect(!result.buffering && !result.finished && model.errorDetail == nil)
    switch action {
    case .pause:
        #expect(model.state == .paused && model.currentFrame == playedFrames && !model.isBuffering)
    case .eject:
        #expect(model.state == .empty && model.disc == nil && !model.isBuffering)
    case .quit:
        #expect(!model.controlsEnabled)
    }
    #expect(probe.entries.filter { $0.call != .stopRequested }.allSatisfy { !$0.onMainThread })
    try await model.shutdown()
}

@Test @MainActor func anActualProducerFailureReachesThePlayerAndMutesReadAhead() async throws {
    let gate = PCMReadGate()
    gate.allow(through: 4_096)
    let source = TestPCMSource(frameCount: Disc.demo.totalFrames) { frame, capacity in
        let count = try gate.count(at: frame, capacity: capacity)
        if frame >= 4_096 { throw CDReadError(.mediaError, "The scripted sector is unreadable.", systemError: EIO) }
        return pcmSamples(at: frame, count: count)
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    defer { gate.allow(through: .max) }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine { OfflinePCMDriver(playback: playback, probe: probe) }
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    try await waitUntil { gate.waitingAt == 4_096 }
    await model.refreshPlayback()
    #expect(model.state == .playing && model.currentFrame == 128 && !model.isBuffering)
    gate.allow(through: .max)
    try await waitUntil {
        await model.refreshPlayback()
        return model.state == .failed
    }
    #expect(model.statusText == "[ERR] Audio error" && model.errorDetail == "The scripted sector is unreadable.")
    #expect(model.currentFrame == 128 && !model.isBuffering && !probe.outputEnabled)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(source.probe.reads.count == 2)
    do {
        _ = try await engine.snapshot()
        Issue.record("The producer failure must remain observable until a new start.")
    } catch let error as AudioPlaybackError {
        #expect(error.code == Int32(CD_DISC_READ_ERROR.rawValue) && error.systemStatus == EIO)
    }
    try await model.shutdown()
}

private func expectCancelled(_ task: Task<OutputInfo, any Error>) async {
    do {
        _ = try await task.value
        Issue.record("An invalidated start must not succeed.")
    } catch is CancellationError {
        // Cancellation is the expected result, not a playback failure.
    } catch {
        Issue.record("Expected cancellation, received \(error).")
    }
}

@Test @MainActor func stopInvalidatesAnAudioStartBeforeItsBlockedWorkCompletes() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine { FakeAudioDriver(probe: probe, startGate: gate) }
    let starting = Task { try await engine.start(at: 0) }
    try await waitUntil { gate.hasEntered }
    var stopped = false
    let stopping = Task {
        _ = try await engine.stop()
        stopped = true
    }
    try await waitUntil { probe.calls.contains(.stopRequested) }
    #expect(!probe.outputEnabled)
    #expect(!stopped)
    #expect(!probe.calls.contains(.enabled))
    gate.release()
    await expectCancelled(starting)
    try await stopping.value
    #expect(stopped)
    #expect(!probe.calls.contains(.enabled))
    #expect(probe.entries.filter { $0.call != .stopRequested }.allSatisfy { !$0.onMainThread })
}

@Test @MainActor func cancellationDiscardsAnUnpublishedAudioHandleBeforeStopReturns() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine {
        try gate.wait()
        return FakeAudioDriver(probe: probe)
    }
    let starting = Task { try await engine.start(at: 0) }
    try await waitUntil { gate.hasEntered }
    starting.cancel()
    var stopped = false
    let stopping = Task {
        _ = try await engine.stop()
        stopped = true
    }
    #expect(!stopped)
    gate.release()
    await expectCancelled(starting)
    try await stopping.value
    #expect(!probe.calls.contains(.enabled))
    #expect(!probe.calls.contains(.started(0)))
}

@Test @MainActor func audioTaskCancellationMutesAndCleansUpALateStart() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine { FakeAudioDriver(probe: probe, startGate: gate) }
    let starting = Task { try await engine.start(at: 0) }
    try await waitUntil { gate.hasEntered }
    starting.cancel()
    try await waitUntil { probe.calls.contains(.stopRequested) }
    gate.release()
    await expectCancelled(starting)
    #expect(probe.calls.contains(.stopped))
    #expect(!probe.calls.contains(.enabled))
}

@Test @MainActor func aNewStartCannotPlaySamplesFromASupersededStart() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine { FakeAudioDriver(probe: probe, startGate: gate) }
    let first = Task { try await engine.start(at: 0) }
    try await waitUntil { gate.hasEntered }
    let replacement = Task { try await engine.start(at: 12_345) }
    try await waitUntil { probe.calls.contains(.stopRequested) }
    gate.release()
    await expectCancelled(first)
    _ = try await replacement.value
    #expect(probe.calls.filter { $0 == .enabled }.count == 1)
    #expect(probe.outputEnabled)
    #expect(try await engine.snapshot().currentFrame == 12_345)
    _ = try await engine.stop()
}

@Test @MainActor func outputIsMutedBeforeBlockedAudioTeardownAndNewStartsWait() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine { FakeAudioDriver(probe: probe, stopGate: gate) }
    _ = try await engine.start(at: 0)
    #expect(probe.outputEnabled)
    let stopping = Task { try await engine.stop() }
    try await waitUntil { gate.hasEntered }
    #expect(!probe.outputEnabled)
    let restarting = Task { try await engine.start(at: 500) }
    try await waitUntil { probe.calls.filter { $0 == .stopRequested }.count == 2 }
    #expect(!probe.calls.contains(.started(500)))
    gate.release()
    _ = try await stopping.value
    _ = try await restarting.value
    #expect(probe.outputEnabled)
    #expect(try await engine.snapshot().currentFrame == 500)
    _ = try await engine.stop()
}

@Test @MainActor func audioLifecycleSurfacesBothStartAndCleanupFailures() async {
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine {
        FakeAudioDriver(probe: probe, failsStart: true, failsCleanup: true)
    }
    do {
        _ = try await engine.start(at: 0)
        Issue.record("The test output must fail.")
    } catch {
        #expect(error.localizedDescription ==
            "The test output could not start. Cleanup failed: The test output could not be restored.")
    }
    #expect(!probe.outputEnabled)
}

@Test @MainActor func audioInspectionAndHandleDestructionStayOffTheMainThread() async throws {
    let probe = AudioDriverProbe()
    var engine: CoreAudioPlaybackEngine? = CoreAudioPlaybackEngine { FakeAudioDriver(probe: probe) }
    _ = try await engine?.inspectOutput(on: .builtIn, format: .compactDisc)
    _ = try await engine?.start(at: 0)
    engine = nil
    try await waitUntil { probe.calls.contains(.destroyed) }
    #expect(!probe.outputEnabled)
    #expect(probe.entries.filter { $0.call != .stopRequested }.allSatisfy { !$0.onMainThread })
}

@Test @MainActor func outputInspectionCreatesNoPlaybackHandle() async throws {
    let probe = AudioDriverProbe()
    let engine = CoreAudioPlaybackEngine(inspect: { _, format in
        probe.record(.inspected)
        return OutputInfo(
            deviceID: 1, name: "Inspected output", sampleRate: Double(format.sampleRate), hogOwner: -1,
            supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: false
        )
    }) { FakeAudioDriver(probe: probe) }
    let info = try await engine.inspectOutput(on: .builtIn, format: .compactDisc)
    #expect(info.name == "Inspected output" && info.sampleRate == 44_100)
    #expect(probe.calls == [.inspected])
    _ = try await engine.start(at: 0)
    #expect(Array(probe.calls.prefix(3)) == [.inspected, .created, .started(0)])
    _ = try await engine.stop()
    #expect(probe.entries.filter { $0.call != .stopRequested }.allSatisfy { !$0.onMainThread })
}

/// Stalls a main-thread worker teardown until the driver is destroyed, so a final release left
/// on the releasing thread cannot hide behind a fast worker queue.
private final class SlowWorkerTeardown: Sendable {
    let probe: AudioDriverProbe

    init(probe: AudioDriverProbe) { self.probe = probe }

    deinit {
        guard Thread.isMainThread else { return }
        let deadline = Date().addingTimeInterval(2)
        while !probe.calls.contains(.destroyed), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

@Test @MainActor func audioHandleDestructionStaysOffTheMainThreadWhenWorkerTeardownIsSlow() async throws {
    let probe = AudioDriverProbe()
    var engine: CoreAudioPlaybackEngine? = CoreAudioPlaybackEngine { [teardown = SlowWorkerTeardown(probe: probe)] in
        _ = teardown
        return FakeAudioDriver(probe: probe)
    }
    _ = try await engine?.start(at: 0)
    // Let the queue release its last block, so this thread drops the worker's final reference.
    try await Task.sleep(for: .milliseconds(50))
    engine = nil
    try await waitUntil { probe.calls.contains(.destroyed) }
    #expect(probe.entries.filter { $0.onMainThread && $0.call != .stopRequested }.map(\.call) == [])
}

func renderPlayback(_ playback: OpaquePointer, frames: Int) -> [Float] {
    var samples = [Float](repeating: .nan, count: frames * 2)
    samples.withUnsafeMutableBufferPointer { buffer in
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.stride),
            mData: buffer.baseAddress
        ))
        cd_playback_render(playback, &output)
    }
    return samples
}

func playbackSnapshot(_ playback: OpaquePointer) throws -> CDPlaybackSnapshot {
    var snapshot = CDPlaybackSnapshot()
    var error = CDError()
    guard cd_playback_snapshot(playback, &snapshot, &error) == 0 else { throw AudioPlaybackError(error) }
    return snapshot
}

@Test @MainActor func silentCallbackChecksumsPCMAndWritesOnlyZerosAcrossStopAndResume() async throws {
    let playback = try OfflinePCMPlayback(
        source: ChecksumPCMSource(frameCount: 8_192), bufferFrames: 4_096, silentOutput: true
    )
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)

    let first = renderPlayback(playback.pointer, frames: 128)
    let second = renderPlayback(playback.pointer, frames: 128)
    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(first.allSatisfy { $0 == 0 } && second.allSatisfy { $0 == 0 })
    #expect(snapshot.currentFrame == 256 && snapshot.underrunFrames == 0)
    #expect(snapshot.pcmChecksum == expectedRenderedPCMChecksum(pcmSamples(at: 0, count: 256)))

    let paused = try await playback.stop()
    try await Task.sleep(for: .milliseconds(20))
    let held = try playbackSnapshot(playback.pointer)
    let idleOutput = renderPlayback(playback.pointer, frames: 128)
    #expect(paused.currentFrame == 256 && paused.pcmChecksum == snapshot.pcmChecksum)
    #expect(held.currentFrame == paused.currentFrame && held.pcmChecksum == paused.pcmChecksum)
    #expect(idleOutput.allSatisfy { $0 == 0 })

    try playback.prepare(at: paused.currentFrame)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)
    let resumedOutput = renderPlayback(playback.pointer, frames: 128)
    let resumed = try playbackSnapshot(playback.pointer)
    #expect(resumedOutput.allSatisfy { $0 == 0 })
    #expect(resumed.currentFrame == 384 && resumed.underrunFrames == 0)
    #expect(resumed.pcmChecksum == expectedRenderedPCMChecksum(pcmSamples(at: 256, count: 128)))
    _ = try await playback.stop()
}

private enum PhysicalStopAction: CaseIterable, Sendable {
    case pause, eject, remove, replace, disconnect, demo, quit
}

private struct GatedDiscPCMSource: PCMSource {
    let source: DiscPCMSource
    let gate: PCMReadGate
    var format: AudioSourceFormat { source.format }
    var frameCount: UInt64 { source.frameCount }
    var readPacing: CDReadPacing { source.readPacing }

    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16] {
        try read(at: frame, maxFrames: maxFrames, context: PCMReadContext()).samples
    }

    func read(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCMReadResult {
        _ = try gate.count(at: frame, capacity: maxFrames)
        try context.checkCancellation()
        return try source.read(at: frame, maxFrames: maxFrames, context: context)
    }
}

@MainActor
private struct OfflineDiscPlayer {
    let player: PlayerModel
    let probe = AudioDriverProbe()
    let opener: FakeDiscOpener
    let service: FakeOpticalService

    init(
        tableOfContents: Data = tocFixture(), seekDelay: Duration = .milliseconds(300), readGate: PCMReadGate? = nil,
        readFeatures: CDReadFeatures = CDReadFeatures(cdFeatures: 0x10)
    ) throws {
        let media = OpticalMedia(
            id: 10, bsdName: "disk4", contents: .audioCD(try CDTableOfContents(data: tableOfContents)),
            isMounted: false, isEjectable: true
        )
        service = FakeOpticalService([opticalDrive(media: media)])
        opener = FakeDiscOpener(tableOfContents: tableOfContents, readFeatures: readFeatures)
        let probe = self.probe
        player = PlayerModel.offline(
            engine: FakeEngine(), automaticallyMonitor: false, opticalService: service,
            discOpener: opener, seekDelay: seekDelay,
            makeDiscEngine: { session in
                CoreAudioPlaybackEngine {
                    let discSource = DiscPCMSource(session: session)
                    let source: any PCMSource
                    if let readGate { source = GatedDiscPCMSource(source: discSource, gate: readGate) }
                    else { source = discSource }
                    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
                    probe.retain(playback)
                    return OfflinePCMDriver(playback: playback, probe: probe)
                }
            }
        )
        player.startOpticalMonitoring()
    }
}

private enum BufferingInterruption: CaseIterable {
    case pause, eject, remove, replace, disconnect, sleep
}

private enum PhysicalStressEvent: CaseIterable {
    case seekForward, seekBackward, pause, disconnect, remove, replace, outputLoss, sleep, eject
}

private struct SeededStressRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(upperBound: Int) -> Int {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return Int(state % UInt64(upperBound))
    }

    mutating func shuffle<Element>(_ elements: inout [Element]) {
        guard elements.count > 1 else { return }
        for index in stride(from: elements.count - 1, through: 1, by: -1) {
            elements.swapAt(index, next(upperBound: index + 1))
        }
    }
}

@MainActor
private final class PhysicalWorkerStressRun {
    let fixture: OfflineDiscPlayer
    let readGate: PCMReadGate
    private(set) var driveID: UInt64 = 1
    private(set) var mediaID: UInt64 = 10

    init() throws {
        let readGate = PCMReadGate()
        readGate.allow(through: 4_095)
        self.readGate = readGate
        fixture = try OfflineDiscPlayer(seekDelay: .milliseconds(5), readGate: readGate)
    }

    func startBufferedPlayback() async throws -> (OfflinePCMPlayback, FakeCDSectorSource) {
        await fixture.player.togglePlayback()
        let playback = try #require(fixture.probe.playbacks.last)
        let source = try #require(fixture.opener.discs.last)
        try await waitFor(description: "the producer to fill the playback ring") {
            try playbackSnapshot(playback.pointer).bufferedFrames == 4_096
        }
        _ = renderPlayback(playback.pointer, frames: 128)
        try await waitFor(description: "the producer to block below buffer capacity") {
            readGate.waitingAt != nil
        }
        for _ in 0..<31 { _ = renderPlayback(playback.pointer, frames: 128) }
        _ = renderPlayback(playback.pointer, frames: 128)
        await fixture.player.refreshPlayback()
        #expect(fixture.player.state == .playing && fixture.player.isBuffering)
        #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 0)
        return (playback, source)
    }

    func interruptBufferedPlayback(
        _ action: BufferingInterruption, playback: OfflinePCMPlayback, source: FakeCDSectorSource
    ) async throws {
        let previousStopCount = fixture.probe.calls.filter { $0 == .stopRequested }.count
        var actionTask: Task<Void, Never>?
        switch action {
        case .pause:
            actionTask = Task { await fixture.player.togglePlayback() }
        case .eject:
            actionTask = Task { await fixture.player.eject() }
        case .remove:
            fixture.service.emit([try drive(mediaID: nil)])
        case .replace:
            mediaID &+= 1
            fixture.service.emit([try drive(mediaID: mediaID)])
        case .disconnect:
            fixture.service.emit([])
        case .sleep:
            actionTask = Task { await fixture.player.prepareForSleep() }
        }

        try await waitFor(description: "the worker to request an immediate stop") {
            fixture.probe.calls.filter { $0 == .stopRequested }.count > previousStopCount
        }
        #expect(!fixture.probe.outputEnabled)
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        readGate.allow(through: .max)
        await actionTask?.value

        if action == .pause {
            try await waitFor(description: "pause to settle") {
                fixture.player.state == .paused && !fixture.player.isBusy
            }
            #expect(!source.isClosed && fixture.player.discSession != nil)
        } else {
            try await waitFor(description: "the interrupted disc session to close") {
                source.isClosed && fixture.player.discSession == nil
            }
            switch action {
            case .eject, .remove:
                fixture.service.emit([try drive(mediaID: mediaID)])
            case .disconnect:
                driveID &+= 1
                fixture.service.emit([try drive(mediaID: mediaID)])
            case .replace:
                break
            case .sleep:
                fixture.player.systemDidWake()
            case .pause:
                Issue.record("Pause should keep the physical disc session open.")
            }
        }
        if action != .pause {
            try await waitFor(description: "the current disc to be available after recovery") {
                fixture.player.selectedDrive?.media?.id == mediaID && !fixture.player.isBusy
            }
        }
        #expect(fixture.player.state != .failed && fixture.player.errorDetail == nil)
        assertDisplayConsistency()
        assertWorkerAndDiscOperationsStayOffMainThread()
    }

    func apply(_ event: PhysicalStressEvent) async throws {
        let playback = try await ensurePlaying()
        let source = try #require(fixture.opener.discs.last)
        switch event {
        case .seekForward:
            let target = fixture.player.currentFrame + 10 * Disc.sampleRate
            await fixture.player.scan(.forward)
            try await settleSeek(on: playback, at: target)
        case .seekBackward:
            let target = fixture.player.currentFrame > 10 * Disc.sampleRate
                ? fixture.player.currentFrame - 10 * Disc.sampleRate
                : 0
            await fixture.player.scan(.backward)
            try await settleSeek(on: playback, at: target)
        case .pause:
            await fixture.player.togglePlayback()
            #expect(fixture.player.state == .paused && !fixture.probe.outputEnabled)
            #expect(fixture.player.discSession != nil && !source.isClosed)
        case .disconnect:
            fixture.service.emit([])
            try await waitForClose(of: source)
            driveID &+= 1
            fixture.service.emit([try drive(mediaID: mediaID)])
            try await waitForCurrentDisc()
        case .remove:
            fixture.service.emit([try drive(mediaID: nil)])
            try await waitForClose(of: source)
            fixture.service.emit([try drive(mediaID: mediaID)])
            try await waitForCurrentDisc()
        case .replace:
            mediaID &+= 1
            fixture.service.emit([try drive(mediaID: mediaID)])
            try await waitForClose(of: source)
            try await waitForCurrentDisc()
        case .outputLoss:
            fixture.probe.failNextSnapshot(with: AudioPlaybackError(CDError(
                result: CD_CONFIGURATION_CHANGED,
                message: "The audio route changed during seeded stress.",
                systemStatus: 0
            )))
            await fixture.player.refreshPlayback()
            #expect(fixture.player.state == .paused && !fixture.probe.outputEnabled)
            #expect(fixture.player.statusText == "CD PAUSED" && fixture.player.errorDetail == nil)
            #expect(fixture.player.discSession != nil && !source.isClosed)
        case .sleep:
            await fixture.player.prepareForSleep()
            #expect(fixture.player.state == .paused && !fixture.probe.outputEnabled)
            #expect(fixture.player.discSession == nil && source.isClosed)
            fixture.player.systemDidWake()
        case .eject:
            let previousEjectCount = fixture.service.ejects.count
            await fixture.player.eject()
            #expect(fixture.service.ejects.count == previousEjectCount + 1)
            #expect(fixture.player.discSession == nil && source.isClosed)
            fixture.service.emit([try drive(mediaID: mediaID)])
            try await waitForCurrentDisc()
        }
        try await waitFor(description: "the stress event to settle") {
            !fixture.player.isBusy && fixture.player.pendingSeek == nil
        }
        #expect(fixture.player.state != .failed && fixture.player.errorDetail == nil)
        assertDisplayConsistency()
        assertWorkerAndDiscOperationsStayOffMainThread()
    }

    func finish() async throws {
        _ = try await ensurePlaying()
        assertDisplayConsistency()
        try await fixture.player.shutdown()
        #expect(!fixture.probe.outputEnabled && fixture.player.discSession == nil)
        #expect(fixture.player.pendingSeek == nil)
        #expect(!fixture.opener.discs.isEmpty)
        for source in fixture.opener.discs {
            #expect(source.isClosed)
            #expect(source.speedRequests.last == 4_234)
            #expect(source.operations.last == .close)
            #expect(!source.usedMainThread)
        }
        assertWorkerAndDiscOperationsStayOffMainThread()
    }

    private func ensurePlaying() async throws -> OfflinePCMPlayback {
        try await waitFor(description: "the player to be idle before opening") {
            !fixture.player.isBusy && fixture.player.pendingSeek == nil
        }
        if fixture.player.state != .playing {
            #expect(fixture.player.state != .failed)
            await fixture.player.togglePlayback()
        }
        #expect(fixture.player.state == .playing)
        let playback = try #require(fixture.probe.playbacks.last)
        try await waitFor(description: "the real producer to fill the playback ring") {
            try playbackSnapshot(playback.pointer).bufferedFrames == 4_096
        }
        _ = renderPlayback(playback.pointer, frames: 128)
        await fixture.player.refreshPlayback()
        #expect(fixture.player.state == .playing && !fixture.player.isBuffering)
        return playback
    }

    private func settleSeek(on playback: OfflinePCMPlayback, at target: UInt64) async throws {
        try await waitFor(description: "the physical seek to finish") { fixture.player.pendingSeek == nil }
        try await waitFor(description: "the producer to refill after seeking") {
            try playbackSnapshot(playback.pointer).bufferedFrames == 4_096
        }
        await fixture.player.refreshPlayback()
        #expect(fixture.player.state == .playing && fixture.player.currentFrame == target)
    }

    private func waitForClose(of source: FakeCDSectorSource) async throws {
        try await waitFor(description: "the physical session to close") {
            source.isClosed && fixture.player.discSession == nil
        }
    }

    private func waitForCurrentDisc() async throws {
        try await waitFor(description: "the selected optical disc to be ready") {
            fixture.player.selectedDrive?.media?.id == mediaID && !fixture.player.isBusy
        }
        #expect(fixture.player.state != .failed && fixture.player.errorDetail == nil)
    }

    private func drive(mediaID: UInt64?) throws -> OpticalDrive {
        OpticalDrive(
            id: driveID, name: "Test Blu-ray drive 1",
            media: try mediaID.map { try audioMedia(id: $0) }
        )
    }

    private func waitFor(
        description: String, _ condition: @MainActor () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await condition()) {
            try #require(
                ContinuousClock.now < deadline,
                "Seeded stress timed out waiting for \(description)."
            )
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertWorkerAndDiscOperationsStayOffMainThread() {
        #expect(fixture.probe.entries.filter { $0.call != .stopRequested }.allSatisfy { !$0.onMainThread })
        #expect(fixture.opener.opens.allSatisfy { !$0.onMainThread })
        #expect(fixture.opener.discs.allSatisfy { !$0.usedMainThread })
    }

    private func assertDisplayConsistency() {
        let player = fixture.player
        #expect(!player.displayAccessibilityLabel.isEmpty)
        #expect(player.timeText.count == 5)
        if let table = player.selectedDrive?.media?.contents.tableOfContents {
            #expect(player.disc == Disc(tableOfContents: table))
            #expect(player.formatText == "44.1 kHz / 16-bit source")
            let expectedTrack = player.isShowingDiscSummary
                ? player.disc?.tracks.count ?? 0
                : player.currentTrack?.number ?? 0
            #expect(player.displayTrackNumber == expectedTrack)
        } else {
            #expect(player.disc == nil)
            #expect(player.formatText.isEmpty)
        }
        if player.state == .playing {
            #expect(fixture.probe.outputEnabled && player.discSession != nil)
            #expect(player.statusText == "CD PLAYING" || player.statusText == "BUFFERING")
        } else {
            #expect(!fixture.probe.outputEnabled)
            if player.state == .paused { #expect(player.statusText == "CD PAUSED") }
        }
    }
}

@Suite(.serialized)
@MainActor
private struct PhysicalWorkerIntegrationTests {
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6])
    func seededHotUnplugInterleavingsKeepTheRealWorkerAndDiscConsistent(seed: UInt64) async throws {
        let startedAt = ContinuousClock.now
        let run = try PhysicalWorkerStressRun()
        let (playback, source) = try await run.startBufferedPlayback()
        let interruptions = BufferingInterruption.allCases
        let interruption = interruptions[Int(seed % UInt64(interruptions.count))]
        try await run.interruptBufferedPlayback(interruption, playback: playback, source: source)

        var random = SeededStressRandom(seed: seed)
        var events = PhysicalStressEvent.allCases
        random.shuffle(&events)
        for event in events {
            try await run.apply(event)
            try #require(
                ContinuousClock.now - startedAt < .seconds(25),
                "Seed \(seed) exceeded the 25-second offline stress budget."
            )
        }
        try await run.finish()
        try #require(
            ContinuousClock.now - startedAt < .seconds(25),
            "Seed \(seed) exceeded the 25-second offline stress budget."
        )
    }

    @Test func physicalPlayFeedsTheActualWorkerAndProducerAndReusesBothAcrossPauseAndTracks() async throws {
        let test = try OfflineDiscPlayer()
        #expect(test.opener.opens.isEmpty && test.probe.playbacks.isEmpty)
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        let source = try #require(test.opener.discs.first)
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
        await test.player.refreshPlayback()
        #expect(test.player.currentFrame == 128 && !test.player.isBuffering)
        await test.player.nextTrack()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        let start = 10 * Disc.sampleRate
        #expect(test.player.currentFrame == start && test.player.trackText == "02")
        #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: start, count: 128).map { Float($0) / 32_768 })
        await test.player.togglePlayback()
        #expect(test.player.currentFrame == start + 128 && test.player.state == .paused)
        #expect(!test.probe.outputEnabled && !source.isClosed)
        #expect(source.speedRequests == [176])
        await test.player.togglePlayback()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: start + 128, count: 128).map { Float($0) / 32_768 })
        #expect(test.opener.opens.count == 1 && test.probe.playbacks.count == 1)
        #expect(test.probe.calls.filter { $0 == .created }.count == 1)
        try await test.player.shutdown()
        #expect(source.isClosed && source.speedRequests == [176, 4_234])
        #expect(test.probe.entries.filter { $0.call != .stopRequested }.allSatisfy { !$0.onMainThread })
    }

    @Test func concealedPhysicalAudioAndUnverifiedReadsReachTheStatusAndVoiceOverLabel() async throws {
        let test = try OfflineDiscPlayer(readFeatures: CDReadFeatures(cdFeatures: 0))
        _ = try #require(await test.player.openDiscSession())
        let source = try #require(test.opener.discs.first)
        source.unreadableSectors[0] = CDReadError(.mediaError, "The first sector cannot be read.")
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        try await waitUntil {
            try playbackSnapshot(playback.pointer).bufferedFrames >= 4_096
        }
        await test.player.refreshPlayback()
        #expect(test.player.statusText == "BUFFERING | ERR 1 | UNVERIFIED")
        #expect(test.player.statusAccessibilityLabel ==
            "Buffering audio. 1 audio sector concealed. Audio alignment or independent read verification is unverified")
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        await test.player.refreshPlayback()
        #expect(test.player.concealedSectors == 1)
        #expect(test.player.isUnverified)
        #expect(test.player.statusText == "CD PLAYING | ERR 1 | UNVERIFIED")
        #expect(test.player.statusIsError)
        #expect(test.player.statusAccessibilityLabel ==
            "CD playing. 1 audio sector concealed. Audio alignment or independent read verification is unverified")
        #expect(test.player.formatText == "44.1 kHz / 16-bit source")
        try await test.player.shutdown()
        #expect(source.isClosed)
    }

    @Test(arguments: PhysicalStopAction.allCases, [false, true])
    func physicalStopsMuteBeforeBlockedReadsFinishAndCloseOnlyAfterJoining(
        action: PhysicalStopAction, afterPlayback: Bool
    ) async throws {
        let test = try OfflineDiscPlayer()
        _ = try #require(await test.player.openDiscSession())
        let source = try #require(test.opener.discs.first)
        let gate = TestGate()
        defer { gate.release() }
        source.readNumberGates[afterPlayback ? 2 : 1] = gate
        source.unreadableSectors[afterPlayback ? 7 : 0] = CDReadError(.gone, "The cancelled physical read failed.")
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        if afterPlayback {
            try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
            #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
        }
        try await waitUntil { gate.hasEntered }
        await test.player.refreshPlayback()
        let stopsBefore = test.probe.calls.filter { $0 == .stopping }.count
        test.service.onEject = { #expect(source.isClosed && !test.probe.outputEnabled) }
        var completed = false
        let stopping = Task {
            switch action {
            case .pause: await test.player.togglePlayback()
            case .eject: await test.player.eject()
            case .remove: test.service.emit([opticalDrive()])
            case .replace: test.service.emit([opticalDrive(media: try audioMedia(id: 11))])
            case .disconnect: test.service.emit([])
            case .demo: await test.player.insertDemoDisc()
            case .quit: try await test.player.shutdown()
            }
            completed = true
        }
        try await waitUntil { test.probe.calls.filter { $0 == .stopping }.count > stopsBefore }
        #expect(!test.probe.outputEnabled && !source.isClosed)
        if action == .pause || action == .eject || action == .demo || action == .quit {
            #expect(!completed)
        }
        #expect(test.service.ejects.isEmpty)
        for _ in 0..<3 { #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 }) }
        gate.release()
        try await stopping.value
        if action == .pause {
            #expect(test.player.state == .paused && test.player.discSession != nil && !source.isClosed)
            #expect(test.player.currentFrame == (afterPlayback ? 128 : 0))
        } else {
            try await waitUntil { source.isClosed }
            #expect(test.player.discSession == nil)
            #expect(source.operations.last == .close)
        }
        switch action {
        case .eject:
            #expect(test.service.ejects.map(\.media) == [10])
            #expect(test.player.state == .empty && test.player.formatText.isEmpty)
        case .replace:
            #expect(test.player.state == .ready && test.player.isShowingDiscSummary)
        case .remove, .disconnect:
            #expect(test.player.state == .empty && test.player.currentFrame == 0)
        case .demo:
            #expect(test.player.source == .demo && test.player.state == .ready)
        case .quit:
            #expect(!test.player.controlsEnabled)
        case .pause: break
        }
        let snapshot = try playbackSnapshot(playback.pointer)
        #expect(snapshot.currentFrame == (afterPlayback ? 128 : 0))
        #expect(snapshot.concealedSectors == 0 && !snapshot.unverified)
        #expect(test.player.errorDetail == nil && test.opener.opens.count == 1)
        #expect(source.reads.count == (afterPlayback ? 2 : 1))
        try await test.player.shutdown()
        #expect(source.isClosed)
    }

    @Test(arguments: [CDReadError.Kind.refused, .gone, .failed])
    func actualPhysicalReadFailuresReachTheModelAndCloseWithoutAnAlternateAccessPath(_ kind: CDReadError.Kind) async throws {
        let test = try OfflineDiscPlayer()
        _ = try #require(await test.player.openDiscSession())
        let source = try #require(test.opener.discs.first)
        let failure = CDReadError(kind, "The physical reader reported a scripted failure.")
        source.unreadableSectors[0] = failure
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        try await waitUntil {
            await test.player.refreshPlayback()
            return test.player.state == .failed
        }
        #expect(test.player.statusText == (kind == .refused ? "[ERR] Access denied" : "[ERR] Disc error"))
        #expect(test.player.errorDetail == failure.message)
        #expect(test.player.discSession == nil && source.isClosed && !test.probe.outputEnabled)
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        #expect(source.reads.count == (kind == .failed ? 2 : 1))
        #expect(test.opener.opens.count == 1)
        try await test.player.shutdown()
    }

    @Test func physicalNoProgressReportsTheTenSecondTimeoutBeforeItsBlockedProducerCanJoin() async throws {
        let gate = PCMReadGate()
        defer { gate.allow(through: .max) }
        let test = try OfflineDiscPlayer(readGate: gate)
        let started = ContinuousClock.now
        await test.player.togglePlayback()
        let source = try #require(test.opener.discs.first)
        let playback = try #require(test.probe.playbacks.first)
        try await waitUntil { gate.waitingAt == 0 }
        let polling = Task {
            while test.player.state == .playing {
                await test.player.refreshPlayback()
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let deadline = started + .seconds(13)
        while test.player.state != .failed {
            try #require(ContinuousClock.now < deadline, "The physical player's 10-second watchdog did not report the stalled read.")
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(ContinuousClock.now - started >= .seconds(10))
        try await waitUntil { test.probe.calls.contains(.stopping) && !test.probe.outputEnabled }
        #expect(test.player.statusText == "[ERR] Read error")
        #expect(test.player.errorDetail == "The PCM source made no read progress for 10 seconds while buffering.")
        #expect(test.player.isBusy && !source.isClosed)
        #expect(test.player.currentFrame == 0 && renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        gate.allow(through: .max)
        try await polling.value
        #expect(source.isClosed && test.player.discSession == nil && !test.player.isBusy)
        #expect(source.reads.isEmpty && test.opener.opens.count == 1)
        try await test.player.shutdown()
    }

    @Test func repeatedPhysicalSeeksStayResponsiveWhileAnOldReadIsBlockedAndEmitOnlyTheFinalTarget() async throws {
        let test = try OfflineDiscPlayer()
        _ = try #require(await test.player.openDiscSession())
        let source = try #require(test.opener.discs.first)
        let gate = TestGate()
        defer { gate.release() }
        source.readNumberGates[2] = gate
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        _ = renderPlayback(playback.pointer, frames: 128)
        try await waitUntil { gate.hasEntered }
        let stopped = test.probe.calls.filter { $0 == .stopping }.count
        await test.player.scan(.forward)
        try await waitUntil { test.probe.calls.filter { $0 == .stopping }.count > stopped }
        await test.player.scan(.forward)
        let lastInput = ContinuousClock.now
        await test.player.scan(.backward)
        #expect(test.player.currentFrame == 10 * Disc.sampleRate && test.player.trackText == "02")
        #expect(test.player.controlsEnabled && !test.player.isBusy && !test.probe.outputEnabled)
        #expect(test.probe.calls.filter { if case .started = $0 { return true }; return false } == [.started(0)])
        gate.release()
        try await waitUntil { test.player.pendingSeek == nil }
        #expect(ContinuousClock.now - lastInput >= .milliseconds(300))
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        #expect(test.probe.calls.filter { if case .started = $0 { return true }; return false } == [.started(0), .started(10 * Disc.sampleRate)])
        #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 10 * Disc.sampleRate, count: 128).map { Float($0) / 32_768 })
        #expect(test.opener.opens.count == 1 && source.speedRequests == [176])
        try await test.player.shutdown()
    }

    @Test func heldForwardSeeksNearTheEndKeepTheRealOutputPlayingFromTheLastStep() async throws {
        let test = try OfflineDiscPlayer()
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        for _ in 0..<3 { await test.player.scan(.forward) }
        #expect(test.player.state == .playing && test.player.currentFrame == 20 * Disc.sampleRate)
        try await waitUntil { test.player.pendingSeek == nil }
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        #expect(test.player.state == .playing && test.probe.outputEnabled)
        #expect(test.probe.calls.filter { if case .started = $0 { return true }; return false } == [.started(0), .started(20 * Disc.sampleRate)])
        #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 20 * Disc.sampleRate, count: 128).map { Float($0) / 32_768 })
        try await test.player.shutdown()
    }

    @Test func sleepPausesTheRealOutputClosesTheDiscAndPlayAfterWakeResumesTheSameAudio() async throws {
        let test = try OfflineDiscPlayer()
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        let source = try #require(test.opener.discs.first)
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
        _ = renderPlayback(playback.pointer, frames: 128)
        await test.player.prepareForSleep()
        #expect(test.player.state == .paused && test.player.currentFrame == 128)
        #expect(!test.probe.outputEnabled && test.player.discSession == nil)
        #expect(source.isClosed && source.speedRequests == [176, 4_234])
        test.player.systemDidWake()
        await test.player.togglePlayback()
        #expect(test.player.state == .playing && test.opener.opens.count == 2 && test.probe.playbacks.count == 2)
        let resumed = try #require(test.probe.playbacks.last)
        try await waitUntil { try playbackSnapshot(resumed.pointer).bufferedFrames == 4_096 }
        #expect(renderPlayback(resumed.pointer, frames: 128) == pcmSamples(at: 128, count: 128).map { Float($0) / 32_768 })
        try await test.player.shutdown()
    }

    @Test func playingTheRealOutputToTheDiscEndShowsTheTotalReleasesTheDiscAndPlayStartsAgain() async throws {
        let data = tocFixture([TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0), TOCTrackFixture(number: 2, sector: 2)
        ], leadOut: 4)])
        let test = try OfflineDiscPlayer(tableOfContents: data)
        let frames = Int(4 * Disc.framesPerSector)
        await test.player.togglePlayback()
        let playback = try #require(test.probe.playbacks.first)
        let source = try #require(test.opener.discs.first)
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == frames }
        try await waitUntil {
            _ = renderPlayback(playback.pointer, frames: frames + 4)
            return try playbackSnapshot(playback.pointer).finished
        }
        await test.player.refreshPlayback()
        #expect(test.player.state == .ended && test.player.statusText == "CD END")
        #expect(test.player.isShowingDiscSummary && test.player.trackText == "02" && test.player.timeText == "00:00")
        #expect(!test.probe.outputEnabled && test.player.discSession == nil)
        #expect(source.isClosed && source.speedRequests == [176, 4_234])
        await test.player.togglePlayback()
        #expect(test.player.state == .playing && test.player.trackText == "01")
        #expect(test.opener.opens.count == 2 && test.probe.playbacks.count == 2)
        let replay = try #require(test.probe.playbacks.last)
        try await waitUntil { try playbackSnapshot(replay.pointer).bufferedFrames == frames }
        #expect(renderPlayback(replay.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
        try await test.player.shutdown()
    }

    @Test(arguments: 0..<4, [false, true])
    func invalidatedPhysicalStartsNeverEnableLateAudio(change: Int, fails: Bool) async throws {
        let gate = TestGate()
        defer { gate.release() }
        let probe = AudioDriverProbe()
        let opener = FakeDiscOpener()
        let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
        let player = PlayerModel.offline(
            engine: FakeEngine(), automaticallyMonitor: false, opticalService: service, discOpener: opener,
            makeDiscEngine: { _ in
                CoreAudioPlaybackEngine { FakeAudioDriver(probe: probe, startGate: gate, failsStart: fails) }
            }
        )
        player.startOpticalMonitoring()
        let starting = Task { await player.togglePlayback() }
        try await waitUntil { gate.hasEntered }
        let source = try #require(opener.discs.first)
        var quitting: Task<Void, any Error>?
        switch change {
        case 0: starting.cancel()
        case 1: service.emit([opticalDrive()])
        case 2: service.emit([opticalDrive(media: try audioMedia(id: 11))])
        default: quitting = Task { try await player.shutdown() }
        }
        try await waitUntil { probe.calls.contains(.stopRequested) }
        #expect(!probe.outputEnabled && !probe.calls.contains(.enabled) && !source.isClosed)
        gate.release()
        await starting.value
        try await quitting?.value
        try await waitUntil { source.isClosed }
        #expect(!probe.calls.contains(.enabled))
        #expect(player.discSession == nil)
        if change != 0 || !fails { #expect(player.errorDetail == nil) }
        try await player.shutdown()
    }
}

@Test @MainActor func theRealProducerPrefillsOffThreadAndItsRendererHonorsImmediateMute() async throws {
    var track = CDDemoTrack(frameCount: 8_192, frequency: 220, amplitude: 3_276)
    var error = CDError()
    let playback = try #require(cd_playback_create(&track, 1, 4_096, &error))
    defer { #expect(cd_playback_destroy(playback, &error) == 0) }
    #expect(cd_playback_prepare(playback, 0, &error) == 0)
    try await waitUntil {
        var snapshot = CDPlaybackSnapshot()
        #expect(cd_playback_snapshot(playback, &snapshot, &error) == 0)
        return snapshot.bufferedFrames == 4_096
    }
    #expect(renderPlayback(playback, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback).currentFrame == 0)
    #expect(try playbackSnapshot(playback).bufferedFrames == 4_096)
    #expect(cd_playback_prepare(playback, 0, &error) == Int32(CD_INVALID_ARGUMENT.rawValue))
    cd_playback_enable_output(playback)
    #expect(renderPlayback(playback, frames: 128).contains { $0 != 0 })
    #expect(try playbackSnapshot(playback).currentFrame == 128)
    cd_playback_request_stop(playback)
    #expect(renderPlayback(playback, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback).currentFrame == 128)
    #expect(cd_playback_stop(playback, nil, &error) == 0)

    // Reusing the buffer must discard the previous run, including its unread samples.
    #expect(cd_playback_prepare(playback, 5_000, &error) == 0)
    try await waitUntil {
        var snapshot = CDPlaybackSnapshot()
        #expect(cd_playback_snapshot(playback, &snapshot, &error) == 0)
        return snapshot.bufferedFrames == 3_192
    }
    cd_playback_enable_output(playback)
    let rendered = renderPlayback(playback, frames: 3_192)
    var expected = [Int16](repeating: 0, count: rendered.count)
    expected.withUnsafeMutableBufferPointer {
        #expect(cd_demo_render(&track, 1, 5_000, $0.baseAddress, 3_192) == 3_192)
    }
    #expect(zip(rendered, expected).allSatisfy { Int32($0 * 32_768) == Int32($1) })
    #expect(try playbackSnapshot(playback).finished)
    #expect(try playbackSnapshot(playback).underrunFrames == 0)
}

@Test func theSystemDefaultOutputWinsSoTheVolumeKeysControlTheCD() {
    let defaultSpeakers = cd_output_rank(true, "MacBook Pro Speakers")
    let headphones = cd_output_rank(false, "External Headphones")
    let speakers = cd_output_rank(false, "MacBook Pro Speakers")
    #expect(defaultSpeakers > headphones)
    #expect(headphones > speakers)
    #expect(cd_output_rank(true, "External Headphones") == defaultSpeakers)
    #expect(cd_output_rank(false, "BUILT-IN HEADPHONE OUTPUT") == headphones)
    #expect(cd_output_rank(false, nil) == speakers)
}
