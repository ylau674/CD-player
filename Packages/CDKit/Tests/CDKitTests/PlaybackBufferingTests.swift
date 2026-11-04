import CDAudioCore
import CoreAudio
import Foundation
import Testing
@testable import CDKit

final class PCMReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var readableUntil: UInt64 = 0
    private var blockedFrame: UInt64?

    var waitingAt: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return blockedFrame
    }

    func allow(through frame: UInt64) {
        condition.lock()
        readableUntil = frame
        condition.broadcast()
        condition.unlock()
    }

    func count(at frame: UInt64, capacity: Int) throws -> Int {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(30)
        while frame >= readableUntil {
            blockedFrame = frame
            guard condition.wait(until: deadline) else {
                throw CDReadError(.failed, "The offline PCM read gate timed out.")
            }
        }
        blockedFrame = nil
        return Int(min(UInt64(capacity), readableUntil - frame))
    }
}

@Test @MainActor func thePlaybackRingHoldsExactlyFifteenSecondsOfStereoInt16() async throws {
    let capacity = Int(CD_PLAYBACK_BUFFER_FRAMES)
    #expect(capacity == 661_500)
    #expect(capacity * 2 * MemoryLayout<Int16>.stride == 2_646_000)
    let source = TestPCMSource(frameCount: UInt64(capacity + 512)) { _, count in
        [Int16](repeating: 1, count: count * 2)
    }
    let playback = try OfflinePCMPlayback(source: source)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == capacity }
    #expect(source.probe.reads.last.map { $0.frame + UInt64($0.maxFrames) } == UInt64(capacity))
    let memory = playbackMemory(playback.pointer)
    #expect(!memory.ringWide && memory.ring.claimedBytes == pageRounded(2_646_000))
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128) == [Float](repeating: 1 / 32_768, count: 256))
    #expect(try playbackSnapshot(playback.pointer).buffering == false)
    _ = try await playback.stop()
}

@Test @MainActor func startupWaitsForExactlyTwoSecondsWithoutWaitingForTheWholeRing() async throws {
    let threshold = UInt64(CD_PLAYBACK_PREFILL_FRAMES)
    #expect(threshold == 88_200)
    let gate = PCMReadGate()
    gate.allow(through: threshold - 1)
    let source = TestPCMSource(frameCount: UInt64(CD_PLAYBACK_BUFFER_FRAMES)) { frame, count in
        pcmSamples(at: frame, count: try gate.count(at: frame, capacity: count))
    }
    let playback = try OfflinePCMPlayback(source: source)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    try await waitUntil { gate.waitingAt == threshold - 1 }
    cd_playback_enable_output(playback.pointer)
    let before = try playbackSnapshot(playback.pointer)
    #expect(before.buffering && before.bufferedFrames == 88_199)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 88_199)
    #expect(try playbackSnapshot(playback.pointer).underrunFrames == 0)

    gate.allow(through: threshold)
    try await waitUntil { gate.waitingAt == threshold }
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 88_200)
    let output = renderPlayback(playback.pointer, frames: 128)
    #expect(output == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    let started = try playbackSnapshot(playback.pointer)
    #expect(!started.buffering && started.currentFrame == 128 && started.underrunFrames == 0)
    gate.allow(through: .max)
    _ = try await playback.stop()
}

@Test @MainActor func anUnderrunRecoversOnlyAfterTwoSecondsAndPreservesEverySourceFrame() async throws {
    let threshold = UInt64(CD_PLAYBACK_PREFILL_FRAMES)
    let cursor = threshold + 31
    let gate = PCMReadGate()
    gate.allow(through: cursor)
    let source = TestPCMSource(frameCount: 6 * Disc.sampleRate) { frame, count in
        pcmSamples(at: frame, count: try gate.count(at: frame, capacity: count))
    }
    let playback = try OfflinePCMPlayback(source: source)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    try await waitUntil { gate.waitingAt == cursor }
    cd_playback_enable_output(playback.pointer)
    let first = renderPlayback(playback.pointer, frames: Int(cursor) + 17)
    #expect(Array(first.prefix(Int(cursor) * 2)) == pcmSamples(at: 0, count: Int(cursor)).map { Float($0) / 32_768 })
    #expect(first.suffix(34).allSatisfy { $0 == 0 })
    let dry = try playbackSnapshot(playback.pointer)
    #expect(dry.buffering && dry.currentFrame == cursor && dry.bufferedFrames == 0)
    #expect(dry.underrunFrames == 17)

    gate.allow(through: cursor + threshold - 1)
    try await waitUntil { gate.waitingAt == cursor + threshold - 1 }
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    let waiting = try playbackSnapshot(playback.pointer)
    #expect(waiting.buffering && waiting.currentFrame == cursor && waiting.bufferedFrames == 88_199)

    gate.allow(through: cursor + threshold)
    try await waitUntil { gate.waitingAt == cursor + threshold }
    let resumed = renderPlayback(playback.pointer, frames: 128)
    #expect(resumed == pcmSamples(at: cursor, count: 128).map { Float($0) / 32_768 })
    let recovered = try playbackSnapshot(playback.pointer)
    #expect(!recovered.buffering && recovered.currentFrame == cursor + 128 && recovered.underrunFrames == 17)
    gate.allow(through: .max)
    let tailCount = Int(source.frameCount - recovered.currentFrame)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == tailCount }
    let tail = renderPlayback(playback.pointer, frames: tailCount + 4)
    #expect(Array(tail.prefix(tailCount * 2)) ==
        pcmSamples(at: recovered.currentFrame, count: tailCount).map { Float($0) / 32_768 })
    #expect(tail.suffix(8).allSatisfy { $0 == 0 })
    let end = try playbackSnapshot(playback.pointer)
    #expect(end.finished && !end.buffering && end.underrunFrames == 17)
    _ = try await playback.stop()
}

@Test @MainActor func recoveryDrainsAShortEOFTailWithoutDemandingTwoSeconds() async throws {
    let threshold = UInt64(CD_PLAYBACK_PREFILL_FRAMES)
    let gate = PCMReadGate()
    gate.allow(through: threshold)
    let source = TestPCMSource(frameCount: threshold + 100) { frame, count in
        pcmSamples(at: frame, count: try gate.count(at: frame, capacity: count))
    }
    let playback = try OfflinePCMPlayback(source: source)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    try await waitUntil { gate.waitingAt == threshold }
    cd_playback_enable_output(playback.pointer)
    _ = renderPlayback(playback.pointer, frames: Int(threshold) + 8)
    #expect(try playbackSnapshot(playback.pointer).buffering)
    gate.allow(through: source.frameCount - 1)
    try await waitUntil { gate.waitingAt == source.frameCount - 1 }
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == threshold)
    gate.allow(through: .max)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 100 }
    let tail = renderPlayback(playback.pointer, frames: 128)
    #expect(Array(tail.prefix(200)) == pcmSamples(at: threshold, count: 100).map { Float($0) / 32_768 })
    #expect(tail.suffix(56).allSatisfy { $0 == 0 })
    let end = try playbackSnapshot(playback.pointer)
    #expect(end.finished && !end.buffering && end.currentFrame == source.frameCount)
    #expect(end.underrunFrames == 8)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).underrunFrames == 8)
    _ = try await playback.stop()
}

@Test(arguments: [false, true])
@MainActor func tenSecondsWithoutProgressTimesOutOnlyWhileWaitingAndDiscardsALateRead(
    afterPlayback: Bool
) async throws {
    #expect(CD_PLAYBACK_STALL_SECONDS == 10)
    let blockedFrame: UInt64 = afterPlayback ? 4_096 : 0
    let gate = PCMReadGate()
    gate.allow(through: blockedFrame)
    let source = TestPCMSource(frameCount: blockedFrame + 100) { frame, count in
        pcmSamples(at: frame, count: try gate.count(at: frame, capacity: count))
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    if afterPlayback {
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    } else {
        try await waitUntil { gate.waitingAt == blockedFrame }
    }
    cd_playback_enable_output(playback.pointer)
    if afterPlayback {
        let output = renderPlayback(playback.pointer, frames: 4_097)
        #expect(Array(output.prefix(8_192)) == pcmSamples(at: 0, count: 4_096).map { Float($0) / 32_768 })
        #expect(output.suffix(2).allSatisfy { $0 == 0 })
        #expect(try playbackSnapshot(playback.pointer).underrunFrames == 1)
    }
    try await waitUntil { gate.waitingAt == blockedFrame }
    #expect(try playbackSnapshot(playback.pointer).buffering)

    let mutedGate = PCMReadGate()
    let mutedSource = TestPCMSource(frameCount: 100) { frame, count in
        pcmSamples(at: frame, count: try mutedGate.count(at: frame, capacity: count))
    }
    let muted = try OfflinePCMPlayback(source: mutedSource)
    defer { mutedGate.allow(through: .max) }
    try muted.prepare()
    #expect(try playbackSnapshot(muted.pointer).buffering == false)

    let fullGate = PCMReadGate()
    fullGate.allow(through: 4_096)
    let fullSource = TestPCMSource(frameCount: 8_192) { frame, count in
        [Int16](repeating: 1, count: try fullGate.count(at: frame, capacity: count) * 2)
    }
    let full = try OfflinePCMPlayback(source: fullSource, bufferFrames: 4_096)
    defer { fullGate.allow(through: .max) }
    try full.prepare()
    try await waitUntil { try playbackSnapshot(full.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(full.pointer)
    #expect(try playbackSnapshot(full.pointer).bufferedFrames == 4_096)

    try await Task.sleep(for: .seconds(6))
    gate.allow(through: blockedFrame + 1)
    try await waitUntil { gate.waitingAt == blockedFrame + 1 }
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 1)
    let progressObserved = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(4_200))
    #expect(try playbackSnapshot(playback.pointer).buffering)
    #expect(try playbackSnapshot(muted.pointer).currentFrame == 0)
    #expect(try playbackSnapshot(full.pointer).bufferedFrames == 4_096)
    _ = renderPlayback(full.pointer, frames: 4_097)
    #expect(try playbackSnapshot(full.pointer).buffering)

    var snapshot = CDPlaybackSnapshot()
    var error = CDError()
    var status: Int32 = 0
    let deadline = progressObserved + .seconds(13)
    while status == 0 {
        try #require(ContinuousClock.now < deadline, "The 10-second no-progress watchdog did not fire.")
        try await Task.sleep(for: .milliseconds(50))
        status = cd_playback_snapshot(playback.pointer, &snapshot, &error)
    }
    #expect(progressObserved.duration(to: ContinuousClock.now) >= .seconds(10))
    #expect(status == Int32(CD_READ_TIMEOUT.rawValue) && error.code == status)
    #expect(decodeCString(error.message) == "The PCM source made no read progress for 10 seconds while buffering.")
    #expect(snapshot.currentFrame == blockedFrame && snapshot.bufferedFrames == 1 && !snapshot.finished)
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(cd_playback_snapshot(playback.pointer, &snapshot, &error) == Int32(CD_READ_TIMEOUT.rawValue))
    var stopped = false
    let stopping = Task {
        _ = try await playback.stop()
        stopped = true
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!stopped)
    gate.allow(through: .max)
    try await stopping.value
    #expect(snapshot.currentFrame == blockedFrame)
    #expect(cd_playback_snapshot(playback.pointer, &snapshot, &error) == Int32(CD_READ_TIMEOUT.rawValue))
    #expect(snapshot.bufferedFrames == 1 && snapshot.currentFrame == blockedFrame)
    #expect(try playbackSnapshot(full.pointer).buffering)
    let restartFrame = source.frameCount - 31
    try playback.prepare(at: restartFrame)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 31 }
    cd_playback_enable_output(playback.pointer)
    let restarted = renderPlayback(playback.pointer, frames: 35)
    #expect(Array(restarted.prefix(62)) == pcmSamples(at: restartFrame, count: 31).map { Float($0) / 32_768 })
    #expect(restarted.suffix(8).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).finished)
    _ = try await playback.stop()
    mutedGate.allow(through: .max)
    _ = try await muted.stop()
    fullGate.allow(through: .max)
    _ = try await full.stop()
}

@Test(arguments: [127, 512, 1_024])
@MainActor func repeatedBufferingPreservesShortReadsAcrossRingWraps(quantum: Int) async throws {
    let threshold = UInt64(CD_PLAYBACK_PREFILL_FRAMES)
    let gate = PCMReadGate()
    gate.allow(through: threshold)
    let source = TestPCMSource(frameCount: 4 * threshold + 31) { frame, capacity in
        let available = try gate.count(at: frame, capacity: capacity)
        let shortRead = [73, 307, 1_151][Int(frame % 3)]
        return pcmSamples(at: frame, count: min(available, shortRead))
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 100_003)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    cd_playback_enable_output(playback.pointer)
    var cursor: UInt64 = 0
    var underrunFrames: UInt64 = 0
    var collected: [Float] = []
    for cycle in 0..<4 {
        let end = UInt64(cycle + 1) * threshold
        if cycle > 0 {
            gate.allow(through: end - 1)
            try await waitUntil { gate.waitingAt == end - 1 }
            #expect(renderPlayback(playback.pointer, frames: quantum).allSatisfy { $0 == 0 })
            let waiting = try playbackSnapshot(playback.pointer)
            #expect(waiting.buffering && waiting.currentFrame == cursor && waiting.bufferedFrames == 88_199)
            gate.allow(through: end)
        }
        try await waitUntil { gate.waitingAt == end }
        while cursor < end {
            let count = Int(min(UInt64(quantum), end - cursor))
            collected += renderPlayback(playback.pointer, frames: count)
            cursor += UInt64(count)
        }
        #expect(renderPlayback(playback.pointer, frames: quantum).allSatisfy { $0 == 0 })
        underrunFrames += min(UInt64(quantum), source.frameCount - cursor)
        let dry = try playbackSnapshot(playback.pointer)
        #expect(dry.buffering && dry.currentFrame == cursor && dry.bufferedFrames == 0)
        #expect(dry.underrunFrames == underrunFrames)
    }
    gate.allow(through: .max)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 31 }
    let tail = renderPlayback(playback.pointer, frames: quantum)
    collected += tail.prefix(62)
    #expect(tail.dropFirst(62).allSatisfy { $0 == 0 })
    let expected = pcmSamples(at: 0, count: Int(source.frameCount)).map { Float($0) / 32_768 }
    #expect(collected == expected)
    let end = try playbackSnapshot(playback.pointer)
    #expect(end.finished && !end.buffering && end.underrunFrames == underrunFrames)
    #expect(source.probe.reads.allSatisfy { !$0.onMainThread && $0.maxFrames <= 4_096 })
    _ = try await playback.stop()
}

@Test @MainActor func steadyPartialProgressCanTakeMoreThanTenSecondsWithoutTimingOut() async throws {
    let threshold = UInt64(CD_PLAYBACK_PREFILL_FRAMES)
    let gate = PCMReadGate()
    let source = TestPCMSource(frameCount: threshold + 17) { frame, capacity in
        let count = min(499, try gate.count(at: frame, capacity: capacity))
        return pcmSamples(at: frame, count: count)
    }
    let playback = try OfflinePCMPlayback(source: source)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    try await waitUntil { gate.waitingAt == 0 }
    cd_playback_enable_output(playback.pointer)
    #expect(try playbackSnapshot(playback.pointer).buffering)
    let start = ContinuousClock.now
    for part in 1...4 {
        try await Task.sleep(for: .seconds(3))
        let end = UInt64(part) * threshold / 4
        gate.allow(through: end)
        try await waitUntil { gate.waitingAt == end }
        let progress = try playbackSnapshot(playback.pointer)
        #expect(progress.currentFrame == 0 && progress.bufferedFrames == Int(end))
        if part < 4 {
            #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        }
    }
    #expect(ContinuousClock.now - start >= .seconds(12))
    #expect(renderPlayback(playback.pointer, frames: 128) ==
        pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    #expect(try playbackSnapshot(playback.pointer).buffering == false)
    gate.allow(through: .max)
    let remaining = Int(source.frameCount - 128)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == remaining }
    let tail = renderPlayback(playback.pointer, frames: remaining + 4)
    let expected = pcmSamples(at: 128, count: remaining).map { Float($0) / 32_768 }
    #expect(Array(tail.prefix(remaining * 2)) == expected)
    #expect(tail.suffix(8).allSatisfy { $0 == 0 })
    let end = try playbackSnapshot(playback.pointer)
    #expect(end.finished && end.underrunFrames == 0)
    _ = try await playback.stop()
}

private func renderPlanarPlayback(_ playback: OpaquePointer, frames: Int) -> [Float] {
    var left = [Float](repeating: .nan, count: frames)
    var right = left
    let buffers = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(buffers.unsafeMutablePointer) }
    buffers.unsafeMutablePointer.pointee.mNumberBuffers = 2
    left.withUnsafeMutableBufferPointer { left in
        right.withUnsafeMutableBufferPointer { right in
            let byteSize = UInt32(frames * MemoryLayout<Float>.stride)
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: left.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: right.baseAddress)
            cd_playback_render(playback, buffers.unsafeMutablePointer)
        }
    }
    return zip(left, right).flatMap { [$0, $1] }
}

@Test(arguments: [127, 512, 1_024])
@MainActor func planarPlaybackHonorsStartupRecoveryAndEOFSilence(quantum: Int) async throws {
    let gate = PCMReadGate()
    gate.allow(through: 4_095)
    let source = TestPCMSource(frameCount: 4_196) { frame, capacity in
        pcmSamples(at: frame, count: try gate.count(at: frame, capacity: capacity))
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    defer { gate.allow(through: .max) }
    try playback.prepare()
    try await waitUntil { gate.waitingAt == 4_095 }
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlanarPlayback(playback.pointer, frames: quantum).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 4_095)
    gate.allow(through: 4_096)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    var cursor = 0
    while cursor < 4_096 {
        let count = min(quantum, 4_096 - cursor)
        let expected = pcmSamples(at: UInt64(cursor), count: count).map { Float($0) / 32_768 }
        #expect(renderPlanarPlayback(playback.pointer, frames: count) == expected)
        cursor += count
    }
    #expect(renderPlanarPlayback(playback.pointer, frames: quantum).allSatisfy { $0 == 0 })
    let dry = try playbackSnapshot(playback.pointer)
    #expect(dry.buffering && dry.currentFrame == 4_096 && dry.underrunFrames == 100)
    gate.allow(through: .max)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 100 }
    let tail = renderPlanarPlayback(playback.pointer, frames: quantum)
    #expect(Array(tail.prefix(200)) == pcmSamples(at: 4_096, count: 100).map { Float($0) / 32_768 })
    #expect(tail.dropFirst(200).allSatisfy { $0 == 0 })
    let end = try playbackSnapshot(playback.pointer)
    #expect(end.finished && !end.buffering && end.underrunFrames == 100)
    _ = try await playback.stop()
}

@Test @MainActor func anInvalidPlaybackLayoutFailsWithoutConsumingAudioAndRestartClearsIt() async throws {
    let source = TestPCMSource(frameCount: 8_192)
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)
    var samples = [Float](repeating: .nan, count: 128)
    samples.withUnsafeMutableBufferPointer { buffer in
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.stride),
            mData: buffer.baseAddress
        ))
        cd_playback_render(playback.pointer, &output)
    }
    #expect(samples.allSatisfy { $0 == 0 })
    var snapshot = CDPlaybackSnapshot()
    var error = CDError()
    #expect(cd_playback_snapshot(playback.pointer, &snapshot, &error) == Int32(CD_FORMAT_UNAVAILABLE.rawValue))
    #expect(decodeCString(error.message) == "Core Audio supplied an unsupported output layout")
    #expect(snapshot.currentFrame == 0 && snapshot.bufferedFrames == 4_096 && snapshot.underrunFrames == 0)
    _ = try await playback.stop()
    try playback.prepare(at: 8_190)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 2 }
    cd_playback_enable_output(playback.pointer)
    let restarted = renderPlayback(playback.pointer, frames: 128)
    #expect(Array(restarted.prefix(4)) == pcmSamples(at: 8_190, count: 2).map { Float($0) / 32_768 })
    #expect(restarted.dropFirst(4).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).finished)
    _ = try await playback.stop()
}

@Test func onlyHDMIAndDisplayPortGetAOneSecondLeadIn() {
    #expect(CD_PLAYBACK_LEAD_IN_MILLISECONDS == 1_000)
    #expect(cd_output_lead_in_frames(kAudioDeviceTransportTypeHDMI, 44_100) == 44_100)
    #expect(cd_output_lead_in_frames(kAudioDeviceTransportTypeDisplayPort, 44_100) == 44_100)
    #expect(cd_output_lead_in_frames(kAudioDeviceTransportTypeHDMI, 48_000) == 48_000)
    #expect(cd_output_lead_in_frames(kAudioDeviceTransportTypeHDMI, 0) == 0)
    for transport in [
        kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeAirPlay,
        kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeUnknown,
    ] {
        #expect(cd_output_lead_in_frames(transport, 44_100) == 0)
    }
}

@Test @MainActor func theLeadInOverlapsStartupBufferingThenPlaysTheSourceFromTheStartFrame() async throws {
    let gate = PCMReadGate()
    gate.allow(through: 4_000)
    let source = TestPCMSource(frameCount: 8_192) { frame, capacity in
        pcmSamples(at: frame, count: try gate.count(at: frame, capacity: capacity))
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    defer { gate.allow(through: .max) }
    cd_playback_set_lead_in_frames(playback.pointer, 300)
    try playback.prepare()
    try await waitUntil { gate.waitingAt == 4_000 }

    // Silence before output is enabled is not part of the lead-in.
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    cd_playback_enable_output(playback.pointer)

    // 300 frames still buffering, then ready, then the rest of the last 128-frame block.
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    let waiting = try playbackSnapshot(playback.pointer)
    #expect(waiting.buffering && waiting.currentFrame == 0 && waiting.bufferedFrames == 4_000)
    gate.allow(through: 4_096)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    let ready = try playbackSnapshot(playback.pointer)
    #expect(!ready.buffering && ready.currentFrame == 0 && ready.bufferedFrames == 4_096)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)

    let first = renderPlayback(playback.pointer, frames: 128)
    #expect(first == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    let started = try playbackSnapshot(playback.pointer)
    #expect(!started.buffering && started.currentFrame == 128 && started.underrunFrames == 0)
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 128, count: 128).map { Float($0) / 32_768 })

    // Every prepare (resume, seek or track change) plays the lead-in again from its start frame.
    gate.allow(through: .max)
    let paused = try await playback.stop()
    #expect(paused.currentFrame == 256 && paused.underrunFrames == 0)
    try playback.prepare(at: 6_000)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 2_192 }
    cd_playback_enable_output(playback.pointer)
    for _ in 0..<3 {
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        let held = try playbackSnapshot(playback.pointer)
        #expect(held.currentFrame == 6_000 && held.bufferedFrames == 2_192 && held.underrunFrames == 0)
    }
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 6_000, count: 128).map { Float($0) / 32_768 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 6_128)
    _ = try await playback.stop()
}

@Test @MainActor func theLeadInIsNotChecksummedAndPlanarOutputGetsItToo() async throws {
    let playback = try OfflinePCMPlayback(
        source: TestPCMSource(frameCount: 8_192), bufferFrames: 4_096, silentOutput: true
    )
    cd_playback_set_lead_in_frames(playback.pointer, 256)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlanarPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    let leadIn = try playbackSnapshot(playback.pointer)
    #expect(leadIn.leadIn)
    #expect(leadIn.currentFrame == 0 && leadIn.bufferedFrames == 4_096 && leadIn.underrunFrames == 0)
    #expect(leadIn.pcmChecksum == PCMChecksum.initialValue)

    #expect(renderPlanarPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    let completedLeadIn = try playbackSnapshot(playback.pointer)
    #expect(!completedLeadIn.leadIn && completedLeadIn.currentFrame == 0)

    #expect(renderPlanarPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    let played = try playbackSnapshot(playback.pointer)
    #expect(!played.leadIn)
    #expect(played.currentFrame == 128 && played.underrunFrames == 0)
    #expect(played.pcmChecksum == expectedRenderedPCMChecksum(pcmSamples(at: 0, count: 128)))
    _ = try await playback.stop()
}
