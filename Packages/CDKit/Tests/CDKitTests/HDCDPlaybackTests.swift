import CDAudioCore
import Dispatch
import Foundation
import Testing
@testable import CDKit

private struct HDCDSignalSource: PCMSource {
    let samples: [Int16]
    let trackEnds: [UInt64]
    var trackGate: HDCDReadGate? = nil

    var format: AudioSourceFormat { .compactDisc }
    var frameCount: UInt64 { UInt64(samples.count / 2) }
    var readPacing: CDReadPacing { CD_READ_UNPACED }
    var hdcdEligible: Bool { true }

    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16] {
        try read(at: frame, maxFrames: maxFrames, context: PCMReadContext()).samples
    }

    func read(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCMReadResult {
        guard frame < frameCount, maxFrames > 0 else {
            return PCMReadResult(samples: [])
        }
        let trackIndex = trackEnds.firstIndex { frame < $0 } ?? trackEnds.count - 1
        if trackIndex == 2 { trackGate?.blockFirstRead() }
        let end = trackEnds[trackIndex]
        let frames = min(UInt64(maxFrames), end - frame)
        let start = Int(frame) * 2
        let finish = start + Int(frames) * 2
        return PCMReadResult(
            samples: Array(samples[start..<finish]),
            trackNumber: UInt32(trackIndex + 1)
        )
    }
}

private final class HDCDReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var didEnter = false

    var entered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didEnter
    }

    func blockFirstRead() {
        lock.lock()
        let shouldBlock = !didEnter
        didEnter = true
        lock.unlock()
        if shouldBlock { releaseSemaphore.wait() }
    }

    func release() {
        releaseSemaphore.signal()
    }

    func rearm() {
        lock.lock()
        didEnter = false
        lock.unlock()
    }
}

private func hdcdSignal(controlByte: UInt8, frames: Int, level: Int16 = 1_000) -> [Int16] {
    let bits = hdcdPacketBits(controlByte: controlByte)
    var samples = [Int16](repeating: level, count: frames * 2)
    for frame in 0..<min(frames, bits.count) {
        let value = Int16(level | Int16(bits[frame]))
        samples[frame * 2] = value
        samples[frame * 2 + 1] = value
    }
    return samples
}

private func hdcdPacketBits(controlByte: UInt8) -> [Int] {
    let prefixWindow: UInt32 = 0x7de0a5d0
    return (0..<32).map { Int((prefixWindow >> (31 - $0)) & 1) } +
        (0..<8).map { Int((controlByte >> (7 - $0)) & 1) }
}

private func peakExtendSignal(frames: Int) -> [Int16] {
    let bits = hdcdPacketBits(controlByte: 0x50)
    var samples = [Int16]()
    samples.reserveCapacity(frames * 2)
    for frame in 0..<frames {
        let phase = 2 * Double.pi * 110 * Double(frame) / 44_100 + Double.pi / 2
        var sample = Int((32_766 * sin(phase)).rounded()) & ~1
        let packetOffset = frame % 71
        if packetOffset < bits.count { sample |= bits[packetOffset] }
        let value = Int16(sample)
        samples.append(value)
        samples.append(value)
    }
    return samples
}

@MainActor
private func waitForBufferedFrames(_ expected: Int, playback: OfflinePCMPlayback) async throws {
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == expected }
}

@Test @MainActor func allInt16ValuesRemainExactThroughHDCDEligiblePipeline() async throws {
    let samples = Array(Int16.min...Int16.max)
    let source = HDCDSignalSource(samples: samples, trackEnds: [UInt64(samples.count / 2)])
    let playback = try OfflinePCMPlayback(source: source)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    try playback.prepare()
    try await waitForBufferedFrames(source.samples.count / 2, playback: playback)
    cd_playback_enable_output(playback.pointer)

    let output = renderPlayback(playback.pointer, frames: source.samples.count / 2)
    #expect(zip(samples, output).allSatisfy { Int32($0) == Int32($1 * 32_768) })
    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_NONE)
    #expect(!snapshot.hdcdDecoded)
}

@Test @MainActor func effectualSyntheticPacketIsDetectedAndDecodedOnWideOutput() async throws {
    let source = HDCDSignalSource(samples: hdcdSignal(controlByte: 0x50, frames: 4_096), trackEnds: [4_096])
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    try playback.prepare()
    try await waitForBufferedFrames(4_096, playback: playback)

    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_EFFECTUAL)
    #expect(snapshot.hdcdDecoded)
    #expect(snapshot.physicalOutputBits == 24)
    _ = try await playback.stop()
    try playback.prepare()
    try await waitForBufferedFrames(4_096, playback: playback)
    #expect(try playbackSnapshot(playback.pointer).hdcdDecoded)
    _ = try await playback.stop()
}

@Test @MainActor func peakExtendRestoresHighLevelSyntheticSamplesWithoutClipping() async throws {
    let frames = 44_100 * 5
    let source = HDCDSignalSource(
        samples: peakExtendSignal(frames: frames),
        trackEnds: [UInt64(frames)]
    )
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: frames)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    try playback.prepare()
    try await waitForBufferedFrames(frames, playback: playback)

    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_EFFECTUAL)
    #expect(snapshot.hdcdDecoded)
    cd_playback_enable_output(playback.pointer)

    let output = renderPlayback(playback.pointer, frames: frames)
    let outputPeak = output.map { abs($0) }.max() ?? 0
    let audioPeak = output.dropFirst(40 * 2).map { abs($0) }.max() ?? 0
    #expect(outputPeak > 0.9)
    #expect(audioPeak > 0.9)
    #expect(outputPeak <= 1)
    #expect(output.allSatisfy { $0.isFinite })
    _ = try await playback.stop()
}

@Test @MainActor func laterEffectualPacketChangesModeOnlyAtTheNextTrackBoundary() async throws {
    let firstTrackFrames = 88_200
    let secondTrack = hdcdSignal(controlByte: 0x50, frames: 128)
    let thirdTrack = [Int16](repeating: 1_000, count: 128 * 2)
    let samples = [Int16](repeating: 1_000, count: firstTrackFrames * 2) + secondTrack + thirdTrack
    let gate = HDCDReadGate()
    let source = HDCDSignalSource(
        samples: samples,
        trackEnds: [UInt64(firstTrackFrames), UInt64(firstTrackFrames + 128), UInt64(firstTrackFrames + 256)],
        trackGate: gate
    )
    let playback = try OfflinePCMPlayback(source: source)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    defer { gate.release() }
    try playback.prepare()
    try await waitUntil { gate.entered }

    let beforeBoundary = try playbackSnapshot(playback.pointer)
    #expect(beforeBoundary.hdcdStatus == CD_HDCD_EFFECTUAL)
    #expect(!beforeBoundary.hdcdDecoded)
    cd_playback_enable_output(playback.pointer)
    let firstTracks = renderPlayback(playback.pointer, frames: firstTrackFrames + 128)
    let secondTrackStart = firstTrackFrames * 2
    let secondTrackEnd = (firstTrackFrames + 128) * 2
    #expect(Array(firstTracks[secondTrackStart..<secondTrackEnd]) ==
        secondTrack.map { Float($0) / 32_768 })

    gate.release()
    try await waitUntil { try playbackSnapshot(playback.pointer).hdcdDecoded }
    let decodedTrack = renderPlayback(playback.pointer, frames: 64)
    #expect(decodedTrack.allSatisfy { abs($0 - Float(1_000) / 65_536) < 0.000001 })
    _ = try await playback.stop()
}

@Test @MainActor func decodedStateFollowsThePlayingPositionNotTheReadAheadProducer() async throws {
    let firstTrackFrames = 88_200
    let secondTrack = hdcdSignal(controlByte: 0x50, frames: 128)
    let thirdTrack = [Int16](repeating: 1_000, count: 128 * 2)
    let samples = [Int16](repeating: 1_000, count: firstTrackFrames * 2) + secondTrack + thirdTrack
    let boundary = firstTrackFrames + 128
    let source = HDCDSignalSource(
        samples: samples,
        trackEnds: [UInt64(firstTrackFrames), UInt64(boundary), UInt64(boundary + 128)]
    )
    let playback = try OfflinePCMPlayback(source: source)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    try playback.prepare()
    try await waitForBufferedFrames(boundary + 128, playback: playback)

    // The producer has switched to decoding at the third track, but nothing has played yet.
    let readAhead = try playbackSnapshot(playback.pointer)
    #expect(readAhead.hdcdStatus == CD_HDCD_EFFECTUAL)
    #expect(readAhead.currentFrame == 0 && !readAhead.hdcdDecoded)

    cd_playback_enable_output(playback.pointer)
    let undecoded = renderPlayback(playback.pointer, frames: boundary - 1)
    #expect(undecoded == samples[..<((boundary - 1) * 2)].map { Float($0) / 32_768 })
    let beforeLastFrame = try playbackSnapshot(playback.pointer)
    #expect(beforeLastFrame.currentFrame == UInt64(boundary - 1) && !beforeLastFrame.hdcdDecoded)

    let lastUndecoded = renderPlayback(playback.pointer, frames: 1)
    #expect(lastUndecoded == samples[((boundary - 1) * 2)..<(boundary * 2)].map { Float($0) / 32_768 })
    let atBoundary = try playbackSnapshot(playback.pointer)
    #expect(atBoundary.currentFrame == UInt64(boundary) && atBoundary.hdcdDecoded)
    let decodedTrack = renderPlayback(playback.pointer, frames: 64)
    #expect(decodedTrack.allSatisfy { abs($0 - Float(1_000) / 65_536) < 0.000001 })
    _ = try await playback.stop()

    // The disc is now known to be effectual, so a run that starts anywhere decodes from its first frame.
    try playback.prepare()
    try await waitForBufferedFrames(boundary + 128, playback: playback)
    let restarted = try playbackSnapshot(playback.pointer)
    #expect(restarted.currentFrame == 0 && restarted.hdcdDecoded)
    _ = try await playback.stop()
}

@Test @MainActor func noEffectSyntheticPacketRemainsBitPerfect() async throws {
    let source = HDCDSignalSource(samples: hdcdSignal(controlByte: 0x43, frames: 128), trackEnds: [128])
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    try playback.prepare()
    try await waitForBufferedFrames(128, playback: playback)
    cd_playback_enable_output(playback.pointer)

    let output = renderPlayback(playback.pointer, frames: 128)
    #expect(output == source.samples.map { Float($0) / 32_768 })
    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_NO_EFFECT)
    #expect(!snapshot.hdcdDecoded)
}

@Test @MainActor func effectualPacketIsNotDecodedToA16BitPhysicalOutput() async throws {
    let source = HDCDSignalSource(samples: hdcdSignal(controlByte: 0x50, frames: 128), trackEnds: [128])
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    cd_playback_set_test_output_bits(playback.pointer, 16)
    try playback.prepare()
    try await waitForBufferedFrames(128, playback: playback)

    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_EFFECTUAL)
    #expect(!snapshot.hdcdDecoded)
    #expect(snapshot.physicalOutputBits == 16)
    _ = try await playback.stop()
}

@Test @MainActor func effectualPacketRemainsBitPerfectWhenDecodingIsDisabled() async throws {
    let source = HDCDSignalSource(samples: hdcdSignal(controlByte: 0x50, frames: 128), trackEnds: [128])
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    var error = CDError()
    #expect(cd_playback_set_hdcd_decode_enabled(playback.pointer, false, &error) == 0)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    try playback.prepare()
    try await waitForBufferedFrames(128, playback: playback)
    cd_playback_enable_output(playback.pointer)

    let output = renderPlayback(playback.pointer, frames: 128)
    #expect(output == source.samples.map { Float($0) / 32_768 })
    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_EFFECTUAL)
    #expect(!snapshot.hdcdDecoded)
    _ = try await playback.stop()
}

@Test @MainActor func shortSourceFinalizesDetectionWhenOutputDepthIsUnknown() async throws {
    let source = HDCDSignalSource(samples: [Int16](repeating: 1_000, count: 128 * 2), trackEnds: [128])
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    try playback.prepare()
    try await waitForBufferedFrames(128, playback: playback)

    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_NONE)
    #expect(!snapshot.hdcdDecoded)
    #expect(snapshot.physicalOutputBits == 0)
    _ = try await playback.stop()
}

private let hdcdStartupBytes = pageRounded(
    pageRounded(Int(CD_PLAYBACK_PREFILL_FRAMES) * 2 * 2) + Int(CD_PLAYBACK_PREFILL_FRAMES) * 2 * 4
)

@Test @MainActor func hdcdStartupPagesAreHeldOnlyUntilDetectionDecides() async throws {
    let frames = Int(CD_PLAYBACK_PREFILL_FRAMES) + 4_096
    let gate = HDCDReadGate()
    let source = HDCDSignalSource(
        samples: hdcdSignal(controlByte: 0x50, frames: frames),
        trackEnds: [22_050, 44_100, UInt64(frames)], trackGate: gate
    )
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: frames)
    #expect(playbackMemory(playback.pointer).hdcdStartup.mappedBytes == hdcdStartupBytes)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    defer { gate.release() }
    try playback.prepare()
    try await waitUntil { gate.entered }

    // One second is held back while detection decides; the raw and decoded copies use separate pages.
    let detecting = playbackMemory(playback.pointer)
    #expect(detecting.ringWide && detecting.ring.claimedBytes == pageRounded(frames * 2 * 4))
    #expect(detecting.hdcdStartup.claimedBytes == hdcdStartupBytes)
    #expect(detecting.hdcdStartup.footprintBytes == pageRounded(44_100 * 2 * 2) + pageRounded(44_100 * 2 * 4))

    gate.release()
    try await waitForBufferedFrames(frames, playback: playback)
    #expect(try playbackSnapshot(playback.pointer).hdcdDecoded)
    let decided = playbackMemory(playback.pointer)
    #expect(decided.hdcdStartup.claimedBytes == 0 && decided.hdcdStartup.footprintBytes == 0)
    #expect(decided.ring.footprintBytes == decided.ring.claimedBytes)

    _ = try await playback.stop()
    let stopped = playbackMemory(playback.pointer)
    #expect(stopped.ring.claimedBytes == 0 && stopped.ring.footprintBytes == 0)
    #expect(stopped.hdcdStartup.claimedBytes == 0)

    // The disc is known to be effectual now, so later runs decode at once and need no start-up copy.
    try playback.prepare()
    #expect(playbackMemory(playback.pointer).hdcdStartup.claimedBytes == 0)
    try await waitForBufferedFrames(frames, playback: playback)
    let restarted = playbackMemory(playback.pointer)
    #expect(restarted.ringWide && restarted.hdcdStartup.footprintBytes == 0)
    #expect(try playbackSnapshot(playback.pointer).hdcdDecoded)
    _ = try await playback.stop()
}

@Test @MainActor func stoppingDuringHDCDDetectionReturnsTheStartupPages() async throws {
    let frames = Int(CD_PLAYBACK_PREFILL_FRAMES) + 4_096
    let gate = HDCDReadGate()
    let source = HDCDSignalSource(
        samples: [Int16](repeating: 1_000, count: frames * 2),
        trackEnds: [22_050, 44_100, UInt64(frames)], trackGate: gate
    )
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: frames)
    cd_playback_set_test_output_bits(playback.pointer, 24)
    defer { gate.release() }
    try playback.prepare()
    try await waitUntil { gate.entered }
    #expect(playbackMemory(playback.pointer).hdcdStartup.footprintBytes > 0)

    cd_playback_request_stop(playback.pointer)
    gate.release()
    _ = try await playback.stop()
    let stopped = playbackMemory(playback.pointer)
    #expect(stopped.hdcdStartup.claimedBytes == 0 && stopped.hdcdStartup.footprintBytes == 0)
    #expect(stopped.ring.claimedBytes == 0 && stopped.ring.footprintBytes == 0)

    // Detection has not decided, so the next run collects the start-up audio again.
    gate.rearm()
    try playback.prepare()
    try await waitUntil { gate.entered }
    let collecting = playbackMemory(playback.pointer)
    #expect(collecting.hdcdStartup.claimedBytes == hdcdStartupBytes)
    #expect(collecting.hdcdStartup.footprintBytes == pageRounded(44_100 * 2 * 2) + pageRounded(44_100 * 2 * 4))
    gate.release()
    try await waitForBufferedFrames(frames, playback: playback)
    #expect(try playbackSnapshot(playback.pointer).hdcdStatus == CD_HDCD_NONE)
    #expect(playbackMemory(playback.pointer).hdcdStartup.claimedBytes == 0)
    _ = try await playback.stop()
}

@Test(arguments: zip([UInt32(16), 24], [true, false]))
@MainActor func outputsThatCannotDecodeHDCDUseA16BitRingWithoutStartupPages(
    outputBits: UInt32, decodeEnabled: Bool
) async throws {
    let source = HDCDSignalSource(samples: hdcdSignal(controlByte: 0x50, frames: 4_096), trackEnds: [4_096])
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    var error = CDError()
    #expect(cd_playback_set_hdcd_decode_enabled(playback.pointer, decodeEnabled, &error) == 0)
    cd_playback_set_test_output_bits(playback.pointer, outputBits)
    try playback.prepare()
    try await waitForBufferedFrames(4_096, playback: playback)

    let memory = playbackMemory(playback.pointer)
    #expect(!memory.ringWide && memory.ring.claimedBytes == pageRounded(4_096 * 2 * 2))
    #expect(memory.hdcdStartup.claimedBytes == 0 && memory.hdcdStartup.footprintBytes == 0)
    let snapshot = try playbackSnapshot(playback.pointer)
    #expect(snapshot.hdcdStatus == CD_HDCD_EFFECTUAL && !snapshot.hdcdDecoded)
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 4_096) == source.samples.map { Float($0) / 32_768 })
    _ = try await playback.stop()
}
