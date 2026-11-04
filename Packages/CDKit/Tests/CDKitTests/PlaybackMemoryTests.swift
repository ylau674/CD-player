import CDAudioCore
import Darwin
import Testing
@testable import CDKit

func playbackMemory(_ playback: OpaquePointer) -> CDPlaybackMemory {
    var memory = CDPlaybackMemory()
    cd_playback_memory(playback, &memory)
    return memory
}

func pageRounded(_ bytes: Int) -> Int {
    let page = Int(getpagesize())
    return (bytes + page - 1) / page * page
}

@Test(arguments: [CD_READ_STEADY, CD_READ_BURST])
@MainActor func stoppedPlaybackReturnsItsReadAheadPagesAndReclaimsThemToResume(_ pacing: CDReadPacing) async throws {
    let source = TestPCMSource(frameCount: 16_384, readPacing: pacing)
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    let unused = playbackMemory(playback.pointer)
    #expect(unused.ring.mappedBytes == pageRounded(4_096 * 2 * 4) && unused.ring.footprintBytes == 0)
    #expect(unused.hdcdStartup.mappedBytes == 0)

    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    let playing = playbackMemory(playback.pointer)
    #expect(!playing.ringWide && playing.ring.claimedBytes == pageRounded(4_096 * 2 * 2))
    #expect(playing.ring.footprintBytes == playing.ring.claimedBytes)
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })

    let paused = try await playback.stop()
    let released = playbackMemory(playback.pointer)
    #expect(released.ring.claimedBytes == 0 && released.ring.footprintBytes == 0)
    #expect(paused.currentFrame == 128 && paused.bufferedFrames > 0)
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == paused.bufferedFrames)

    try playback.prepare(at: 128)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    let resumed = playbackMemory(playback.pointer)
    #expect(resumed.ring.claimedBytes == playing.ring.claimedBytes)
    #expect(resumed.ring.footprintBytes == resumed.ring.claimedBytes)
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 128, count: 128).map { Float($0) / 32_768 })
    #expect(try playbackSnapshot(playback.pointer).underrunFrames == 0)
    _ = try await playback.stop()
    #expect(playbackMemory(playback.pointer).ring.footprintBytes == 0)
}

@Test @MainActor func aStopRequestAloneKeepsTheReadAheadPages() async throws {
    let playback = try OfflinePCMPlayback(source: TestPCMSource(frameCount: 4_096), bufferFrames: 4_096)
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_request_stop(playback.pointer)
    // Only Stop, after the workers have joined, may return the pages.
    #expect(playbackMemory(playback.pointer).ring.claimedBytes == pageRounded(4_096 * 2 * 2))
    _ = try await playback.stop()
    #expect(playbackMemory(playback.pointer).ring.claimedBytes == 0)
}
