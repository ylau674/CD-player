import CDAudioCore
import Foundation
import Testing
@testable import CDKit

@Test(arguments: [CD_READ_STEADY, CD_READ_BURST])
func pacedRefillsBeginAtTheExactConsumptionWatermark(_ pacing: CDReadPacing) async throws {
    let capacity = Int(CD_PLAYBACK_BUFFER_FRAMES)
    #expect(capacity == 661_500 && CD_PLAYBACK_BURST_LOW_FRAMES == 441_000)
    // Burst refills once a third of the 15 s ring, 5 s, remains; that is under the 10 s cap.
    let refillAt = pacing == CD_READ_STEADY ? 4_096 : 441_000
    let source = TestPCMSource(frameCount: UInt64(capacity * 3), readPacing: pacing) { _, count in
        [Int16](repeating: 1, count: count * 2)
    }
    let playback = try OfflinePCMPlayback(source: source)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == capacity }
    cd_playback_enable_output(playback.pointer)
    let initialReads = source.probe.reads.count
    let before = renderPlayback(playback.pointer, frames: refillAt - 1)
    #expect(before.allSatisfy { $0 == 1 / 32_768 })
    try await Task.sleep(for: .milliseconds(30))
    #expect(source.probe.reads.count == initialReads)
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == capacity - refillAt + 1)
    #expect(renderPlayback(playback.pointer, frames: 1) == [Float](repeating: 1 / 32_768, count: 2))
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == capacity }
    let refills = Array(source.probe.reads.dropFirst(initialReads))
    #expect(refills.first?.frame == UInt64(capacity))
    #expect(refills.reduce(0) { $0 + $1.maxFrames } == refillAt)
    #expect(refills.last.map { $0.frame + UInt64($0.maxFrames) } == UInt64(capacity + refillAt))
    #expect(refills.allSatisfy { !$0.onMainThread && $0.maxFrames <= 4_096 })
    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.currentFrame == UInt64(refillAt) && snapshot.underrunFrames == 0 && !snapshot.buffering)
    _ = try await playback.stop()
}

@Test(arguments: [CD_READ_STEADY, CD_READ_BURST], [127, 1_024])
func pacedShortReadsPreserveEveryFrameAcrossWrapsAndRestartAtEOF(
    pacing: CDReadPacing, callbackFrames: Int
) async throws {
    let capacity = 100_003
    let source = TestPCMSource(frameCount: UInt64(capacity * 3 + 1_234), readPacing: pacing) { frame, count in
        pcmSamples(at: frame, count: min(173, count))
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: capacity)
    var cursor: UInt64 = 587
    try playback.prepare(at: cursor)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == capacity }
    cd_playback_enable_output(playback.pointer)
    while cursor < source.frameCount {
        let count = Int(min(UInt64(callbackFrames), source.frameCount - cursor))
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames >= count }
        let output = renderPlayback(playback.pointer, frames: count)
        #expect(output == pcmSamples(at: cursor, count: count).map { Float($0) / 32_768 })
        cursor += UInt64(count)
        #expect(try playbackSnapshot(playback.pointer).currentFrame == cursor)
    }
    let end = try playbackSnapshot(playback.pointer)
    #expect(end.finished && !end.buffering && end.underrunFrames == 0)
    #expect(source.probe.reads.allSatisfy { !$0.onMainThread && $0.maxFrames <= 4_096 })
    _ = try await playback.stop()
    let tail = source.frameCount - 31
    try playback.prepare(at: tail)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 31 }
    cd_playback_enable_output(playback.pointer)
    let output = renderPlayback(playback.pointer, frames: 128)
    #expect(Array(output.prefix(62)) == pcmSamples(at: tail, count: 31).map { Float($0) / 32_768 })
    #expect(output.suffix(194).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).finished)
    #expect(try playbackSnapshot(playback.pointer).underrunFrames == 0)
    _ = try await playback.stop()
}

@Test func burstPacingCanIdleForTwelveSecondsOfPlaybackWithoutAFalseReadTimeout() async throws {
    // A 30 s ring idles until 10 s remain, longer than the 10 s read-progress deadline.
    let capacity = 30 * 44_100
    let source = TestPCMSource(frameCount: UInt64(capacity * 2), readPacing: CD_READ_BURST) { _, count in
        [Int16](repeating: 1, count: count * 2)
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: capacity)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == capacity }
    let initialReads = source.probe.reads.count
    cd_playback_enable_output(playback.pointer)
    let started = ContinuousClock.now
    for second in 1...12 {
        #expect(renderPlayback(playback.pointer, frames: 44_100).allSatisfy { $0 == 1 / 32_768 })
        try await Task.sleep(for: .seconds(1))
        let snapshot = try playbackSnapshot(playback.pointer)
        #expect(snapshot.currentFrame == UInt64(second * 44_100) && snapshot.underrunFrames == 0)
        #expect(snapshot.bufferedFrames == capacity - second * 44_100 && !snapshot.buffering)
        #expect(source.probe.reads.count == initialReads)
    }
    #expect(ContinuousClock.now - started >= .seconds(12))
    _ = try await playback.stop()
}

@Test(arguments: [CD_READ_STEADY, CD_READ_BURST])
func pacedIdleNeverDelaysTwoSecondRecoveryAfterAnUnderrun(_ pacing: CDReadPacing) async throws {
    let capacity = UInt64(CD_PLAYBACK_BUFFER_FRAMES)
    let threshold = UInt64(CD_PLAYBACK_PREFILL_FRAMES)
    let gate = PCMReadGate()
    gate.allow(through: capacity)
    let source = TestPCMSource(frameCount: capacity * 2, readPacing: pacing) { frame, count in
        [Int16](repeating: 1, count: try gate.count(at: frame, capacity: count) * 2)
    }
    let playback = try OfflinePCMPlayback(source: source)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == Int(capacity) }
    cd_playback_enable_output(playback.pointer)
    let first = renderPlayback(playback.pointer, frames: Int(capacity) + 7)
    #expect(first.suffix(14).allSatisfy { $0 == 0 })
    try await waitUntil { gate.waitingAt == capacity }
    gate.allow(through: capacity + threshold - 1)
    try await waitUntil { gate.waitingAt == capacity + threshold - 1 }
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == capacity)
    gate.allow(through: capacity + threshold)
    try await waitUntil { gate.waitingAt == capacity + threshold }
    #expect(renderPlayback(playback.pointer, frames: 128) == [Float](repeating: 1 / 32_768, count: 256))
    let resumed = try playbackSnapshot(playback.pointer)
    #expect(!resumed.buffering && resumed.currentFrame == capacity + 128 && resumed.underrunFrames == 7)
    gate.allow(through: .max)
    _ = try await playback.stop()
}

@Test(arguments: [CD_READ_STEADY, CD_READ_BURST])
func pacedRefillFailuresMuteAlreadyBufferedAudioImmediately(_ pacing: CDReadPacing) async throws {
    let capacity = Int(CD_PLAYBACK_BUFFER_FRAMES)
    let refillAt = pacing == CD_READ_STEADY ? 4_096 : 441_000
    let failure = CDReadError(.mediaError, "The paced refill failed.", systemError: EIO)
    let source = TestPCMSource(frameCount: UInt64(capacity * 2), readPacing: pacing) { frame, count in
        if frame >= UInt64(capacity) { throw failure }
        return [Int16](repeating: 1, count: count * 2)
    }
    let playback = try OfflinePCMPlayback(source: source)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == capacity }
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: refillAt).allSatisfy { $0 == 1 / 32_768 })
    try await waitUntil {
        var snapshot = CDPlaybackSnapshot()
        var error = CDError()
        return cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0
    }
    var snapshot = CDPlaybackSnapshot()
    var error = CDError()
    #expect(cd_playback_snapshot(playback.pointer, &snapshot, &error) == Int32(CD_DISC_READ_ERROR.rawValue))
    #expect(error.code == Int32(CD_DISC_READ_ERROR.rawValue) && error.systemStatus == EIO)
    #expect(decodeCString(error.message) == failure.message)
    #expect(snapshot.bufferedFrames == capacity - refillAt && snapshot.currentFrame == UInt64(refillAt))
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    _ = try await playback.stop()
}

@Test(arguments: [CD_READ_STEADY, CD_READ_BURST])
func pacingNeverWaitsForMoreThanASmallRingsRecoveryGate(_ pacing: CDReadPacing) async throws {
    let source = TestPCMSource(frameCount: 8_192, readPacing: pacing)
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    #expect(source.probe.reads.count == 2 && source.probe.reads.last?.maxFrames == 128)
    #expect(try playbackSnapshot(playback.pointer).underrunFrames == 0)
    _ = try await playback.stop()
}

@Test func invalidPacingIsRejectedWithoutTakingOwnershipOfTheSource() throws {
    let probe = PCMSourceProbe()
    var source: TestPCMSource? = TestPCMSource(
        frameCount: 100, probe: probe, readPacing: CDReadPacing(rawValue: 99)
    )
    do {
        _ = try makePCMPlayback(source: #require(source), bufferFrames: 4_096)
        Issue.record("An invalid pacing policy must fail before taking source ownership.")
    } catch {
        #expect((error as? AudioPlaybackError)?.code == Int32(CD_INVALID_ARGUMENT.rawValue))
    }
    #expect(!probe.isDestroyed && probe.reads.isEmpty)
    source = nil
    #expect(probe.isDestroyed)
}
