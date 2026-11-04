import CDAudioCore
import Dispatch
import Foundation
import Testing
@testable import CDKit

/// Lifecycle operations are sequential, except atomic mute and rendering while Stop joins
/// a blocked producer. The test worker ensures that join never blocks the main actor.
final class OfflinePCMPlayback: @unchecked Sendable {
    let pointer: OpaquePointer
    private let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.test-pcm-lifecycle")

    init(
        source: any PCMSource, bufferFrames: Int = Int(CD_PLAYBACK_BUFFER_FRAMES),
        silentOutput: Bool = false, levelSource: CoreAudioLevelSource? = nil
    ) throws {
        pointer = try makePCMPlayback(
            source: source, bufferFrames: bufferFrames, silentOutput: silentOutput,
            levelSource: levelSource
        )
    }

    deinit {
        var error = CDError()
        #expect(cd_playback_destroy(pointer, &error) == 0, "\(decodeCString(error.message))")
    }

    func prepare(at frame: UInt64 = 0) throws {
        var error = CDError()
        guard cd_playback_prepare(pointer, frame, &error) == 0 else { throw AudioPlaybackError(error) }
    }

    func stop() async throws -> CDPlaybackSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var snapshot = CDPlaybackSnapshot()
                var error = CDError()
                if cd_playback_stop(self.pointer, &snapshot, &error) == 0 {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: AudioPlaybackError(error))
                }
            }
        }
    }
}

final class PCMSourceProbe: @unchecked Sendable {
    struct Read: Equatable {
        let frame: UInt64
        let maxFrames: Int
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Read] = []
    private var destroyed = false
    var reads: [Read] { lock.withLock { recorded } }
    var isDestroyed: Bool { lock.withLock { destroyed } }

    func record(frame: UInt64, maxFrames: Int) {
        lock.withLock {
            recorded.append(Read(frame: frame, maxFrames: maxFrames, onMainThread: Thread.isMainThread))
        }
    }

    func recordDestruction() { lock.withLock { destroyed = true } }
}

func pcmSamples(at frame: UInt64, count: Int) -> [Int16] {
    (0..<count).flatMap { offset in
        (0..<2).map { FakeCDSectorSource.sample(frame: Int64(frame) + Int64(offset), channel: $0) }
    }
}

private func oversizedNativePCMRead(
    _ context: UnsafeMutableRawPointer?, _ frame: UInt64, _ stereo: UnsafeMutablePointer<Int16>?,
    _ capacity: Int, _ request: UnsafePointer<CDPCMReadContext>?,
    _ result: UnsafeMutablePointer<CDPCMReadResult>?, _ error: UnsafeMutablePointer<CDError>?
) -> Int32 {
    result?.pointee.framesRead = capacity + 1
    return Int32(CD_OK.rawValue)
}

private func undocumentedNativePCMFailure(
    _ context: UnsafeMutableRawPointer?, _ frame: UInt64, _ stereo: UnsafeMutablePointer<Int16>?,
    _ capacity: Int, _ request: UnsafePointer<CDPCMReadContext>?,
    _ result: UnsafeMutablePointer<CDPCMReadResult>?, _ error: UnsafeMutablePointer<CDError>?
) -> Int32 {
    Int32(CD_DISC_GONE.rawValue)
}

final class TestPCMSource: PCMSource {
    let format: AudioSourceFormat
    let frameCount: UInt64
    let probe: PCMSourceProbe
    let readPacing: CDReadPacing
    private let body: @Sendable (UInt64, Int) throws -> [Int16]

    init(
        frameCount: UInt64, format: AudioSourceFormat = .compactDisc, probe: PCMSourceProbe = PCMSourceProbe(),
        readPacing: CDReadPacing = CD_READ_UNPACED,
        body: @escaping @Sendable (UInt64, Int) throws -> [Int16] = { pcmSamples(at: $0, count: $1) }
    ) {
        self.format = format
        self.frameCount = frameCount
        self.probe = probe
        self.readPacing = readPacing
        self.body = body
    }

    deinit { probe.recordDestruction() }

    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16] {
        probe.record(frame: frame, maxFrames: maxFrames)
        return try body(frame, maxFrames)
    }
}

private func fakeSession(_ data: Data = tocFixture()) async throws -> (DiscSession, FakeCDSectorSource) {
    let table = try CDTableOfContents(data: data)
    let media = OpticalMedia(id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
    let opener = FakeDiscOpener(tableOfContents: data)
    let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
    return (session, try #require(opener.discs.first))
}

private func blockingRead(_ source: any PCMSource, at frame: UInt64, maxFrames: Int) async throws -> [Int16] {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try source.read(at: frame, maxFrames: maxFrames))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
private func drainShortSource(_ pointer: OpaquePointer, from start: UInt64, to end: UInt64) async throws -> [Float] {
    let frames = Int(end - start)
    try await waitUntil { try playbackSnapshot(pointer).bufferedFrames == frames }
    cd_playback_enable_output(pointer)
    var samples: [Float] = []
    try await waitUntil {
        samples = renderPlayback(pointer, frames: frames + 4)
        return try playbackSnapshot(pointer).finished
    }
    #expect(samples.suffix(8).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(pointer).underrunFrames == 0)
    return Array(samples.prefix(frames * 2))
}

private func mixedPCMDisc() -> Data {
    tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0, control: 4),
            TOCTrackFixture(number: 2, sector: 3),
            TOCTrackFixture(number: 3, sector: 6),
            TOCTrackFixture(number: 4, sector: 9, control: 4)
        ], leadOut: 11),
        TOCSessionFixture(number: 2, tracks: [
            TOCTrackFixture(number: 5, sector: 20), TOCTrackFixture(number: 6, sector: 23)
        ], leadOut: 27)
    ])
}

@Test @MainActor func theDiscPCMProducerPreservesSamplesAcrossTracksDataAndSessionGaps() async throws {
    let (session, disc) = try await fakeSession(mixedPCMDisc())
    let timeline = session.disc
    #expect(timeline.tracks.map(\.number) == [2, 3, 5, 6])
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    for start: UInt64 in [0, 1, 587, 588, 1_763, 3_527, 3_528, timeline.totalFrames - 1] {
        try playback.prepare(at: start)
        let samples = try await drainShortSource(playback.pointer, from: start, to: timeline.totalFrames)
        let expected = try (start..<timeline.totalFrames).flatMap { frame in
            let position = try #require(timeline.sectorPosition(at: frame))
            return pcmSamples(at: position.sector * Disc.framesPerSector + position.frame, count: 1)
        }
        #expect(samples == expected.map { Float($0) / 32_768 }, "Playback start: \(start)")
        #expect(try playbackSnapshot(playback.pointer).currentFrame == timeline.totalFrames)
        _ = try await playback.stop()
    }
    #expect(!disc.reads.isEmpty)
    #expect(disc.reads.allSatisfy { read in
        read.errorFlags && (1...37).contains(read.count) && timeline.tracks.contains {
            read.firstSector >= $0.firstSector &&
                read.firstSector + UInt64(read.count) <= $0.firstSector + $0.sectorCount
        }
    })
    #expect(disc.speedRequests == [RawCDReader.minimumSpeed])
    #expect(await session.isOpen)
    await session.close()
    #expect(disc.speedRequests == [RawCDReader.minimumSpeed, 4_234])
}

@Test @MainActor func discPCMReadsBoundLargeRequestsAndValidateFramePositions() async throws {
    let (session, disc) = try await fakeSession()
    let source = DiscPCMSource(session: session)
    let samples = try await blockingRead(source, at: 587, maxFrames: Int.max)
    let expectedFrames = DiscPCMSource.maxSectorsPerRead * 588 - 587
    #expect(samples.count == expectedFrames * 2)
    #expect(samples == pcmSamples(at: 587, count: expectedFrames))
    #expect(disc.reads == [.init(firstSector: 0, count: DiscPCMSource.maxSectorsPerRead, errorFlags: true)])
    #expect(try await blockingRead(source, at: source.frameCount, maxFrames: 1).isEmpty)
    for (frame, count): (UInt64, Int) in [(0, 0), (0, -1), (source.frameCount + 1, 1), (.max, 1)] {
        do {
            _ = try await blockingRead(source, at: frame, maxFrames: count)
            Issue.record("An invalid PCM request must fail.")
        } catch {
            #expect((error as? CDReadError)?.message == "The PCM frame request is outside the disc.")
        }
    }
    #expect(disc.reads.count == 1)
    await session.close()
}

@Test(arguments: [0, 1, 2, 3, 4])
@MainActor func discPCMRejectsMalformedSectorBlocks(_ kind: Int) async throws {
    let (session, disc) = try await fakeSession()
    let sizes = [2_352, 0, 2_351, 4_704, 2_352]
    disc.readBlocks = [CDSectorBlock(
        firstSector: kind == 0 ? 1 : 0, audio: Data(count: sizes[kind]),
        errorFlags: kind == 4 ? Data(count: 293) : Data(count: 294)
    )]
    do {
        _ = try await blockingRead(DiscPCMSource(session: session), at: 0, maxFrames: 588)
        Issue.record("A malformed block must not become audio.")
    } catch {
        #expect((error as? CDReadError)?.message == "The disc returned an invalid audio sector block.")
    }
    #expect(disc.reads.count == 1)
    await session.close()
}

@Test @MainActor func demoTonesUseTheSameProducerWithoutChangingTheirPCM() async throws {
    let tracks = [
        CDDemoTrack(frameCount: 7, frequency: 220, amplitude: 3_276),
        CDDemoTrack(frameCount: 9, frequency: 330, amplitude: 3_276),
        CDDemoTrack(frameCount: 19, frequency: 440, amplitude: 3_276)
    ]
    var error = CDError()
    let playback = try #require(tracks.withUnsafeBufferPointer {
        cd_playback_create($0.baseAddress, $0.count, 4_096, &error)
    })
    defer { #expect(cd_playback_destroy(playback, &error) == 0) }
    #expect(cd_playback_prepare(playback, 3, &error) == 0)
    let output = try await drainShortSource(playback, from: 3, to: 35)
    var expected = [Int16](repeating: 0, count: output.count)
    tracks.withUnsafeBufferPointer { tracks in
        expected.withUnsafeMutableBufferPointer {
            #expect(cd_demo_render(tracks.baseAddress, tracks.count, 3, $0.baseAddress, 32) == 32)
        }
    }
    #expect(output == expected.map { Float($0) / 32_768 })
}

@Test @MainActor func thePCMProducerAcceptsShortReadsAndClampsItsFinalRequest() async throws {
    let source = TestPCMSource(frameCount: 71) { frame, count in
        pcmSamples(at: frame, count: min(7, count))
    }
    let playback = try OfflinePCMPlayback(source: source)
    try playback.prepare(at: 2)
    let samples = try await drainShortSource(playback.pointer, from: 2, to: 71)
    #expect(samples == pcmSamples(at: 2, count: 69).map { Float($0) / 32_768 })
    _ = try await playback.stop()
    #expect(source.probe.reads.map(\.frame) == [2, 9, 16, 23, 30, 37, 44, 51, 58, 65])
    #expect(source.probe.reads.last?.maxFrames == 6)
    #expect(source.probe.reads.allSatisfy { !$0.onMainThread })
}

@Test @MainActor func aPluggablePCMSourceStreamsExactlyAcrossRepeatedRingWraps() async throws {
    let source = TestPCMSource(frameCount: 20_000)
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    var cursor: UInt64 = 123
    try playback.prepare(at: cursor)
    cd_playback_enable_output(playback.pointer)
    var collected: [Float] = []
    while cursor < source.frameCount {
        let count = Int(min(257, source.frameCount - cursor))
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames >= count }
        var samples: [Float] = []
        try await waitUntil {
            samples = renderPlayback(playback.pointer, frames: count)
            return try playbackSnapshot(playback.pointer).currentFrame == cursor + UInt64(count)
        }
        collected += samples
        cursor += UInt64(count)
    }
    #expect(collected == pcmSamples(at: 123, count: 19_877).map { Float($0) / 32_768 })
    #expect(try playbackSnapshot(playback.pointer).finished)
    #expect(try playbackSnapshot(playback.pointer).underrunFrames == 0)
    _ = try await playback.stop()
    let reads = source.probe.reads
    #expect(reads.first?.frame == 123)
    #expect(reads.last.map { $0.frame + UInt64($0.maxFrames) } == 20_000)
    #expect(zip(reads, reads.dropFirst()).allSatisfy {
        $0.frame + UInt64($0.maxFrames) == $1.frame
    })
}

@Test @MainActor func aSourceFailureAfterPrefillMutesTheRemainingBufferedAudio() async throws {
    let source = TestPCMSource(frameCount: 8_192) { frame, count in
        if frame >= 4_096 { throw CDReadError(.mediaError, "The next sector is unreadable.", systemError: 5) }
        return pcmSamples(at: frame, count: count)
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    try playback.prepare()
    cd_playback_enable_output(playback.pointer)
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    var output: [Float] = []
    var error = CDError()
    var snapshot = CDPlaybackSnapshot()
    try await waitUntil {
        output = renderPlayback(playback.pointer, frames: 128)
        let status = cd_playback_snapshot(playback.pointer, &snapshot, &error)
        #expect(status == 0 || status == Int32(CD_DISC_READ_ERROR.rawValue))
        return snapshot.currentFrame == 128
    }
    #expect(output == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
    #expect(error.code == Int32(CD_DISC_READ_ERROR.rawValue))
    #expect(snapshot.bufferedFrames == 3_968 && snapshot.currentFrame == 128)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    _ = try await playback.stop()
    #expect(source.probe.reads.count == 2)
}

@Test(arguments: [CDReadError.Kind.refused, .gone, .failed])
@MainActor func discReadFailuresKeepTheirCategoryAndDetailAcrossTheCProducer(_ kind: CDReadError.Kind) async throws {
    let (session, disc) = try await fakeSession()
    let failure = CDReadError(kind, "The scripted sector read failed.", systemError: 5)
    disc.unreadableSectors[0] = failure
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    try playback.prepare()
    var error = CDError()
    var snapshot = CDPlaybackSnapshot()
    var status: Int32 = 0
    try await waitUntil {
        status = cd_playback_snapshot(playback.pointer, &snapshot, &error)
        return status != 0
    }
    #expect(error.code == CDError(sourceError: failure).code)
    #expect(error.code == status)
    #expect(error.systemStatus == 5)
    #expect(decodeCString(error.message) == failure.message)
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(snapshot.currentFrame == 0 && snapshot.bufferedFrames == 0)
    _ = try await playback.stop()
    #expect(disc.reads.count == (kind == .failed ? 2 : 1))
    await session.close()
}

@Test(arguments: [0, 1, 2])
@MainActor func malformedPCMIsAnErrorRatherThanSilenceOrAnInventedDiscEnd(_ kind: Int) async throws {
    let source = TestPCMSource(frameCount: 100) { _, count in
        switch kind {
        case 0: []
        case 1: [1]
        default: [Int16](repeating: 1, count: (count + 1) * 2)
        }
    }
    let playback = try OfflinePCMPlayback(source: source)
    try playback.prepare()
    var error = CDError()
    var snapshot = CDPlaybackSnapshot()
    try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
    #expect(error.code == Int32(CD_PRODUCER_ERROR.rawValue))
    #expect(!decodeCString(error.message).isEmpty)
    #expect(!snapshot.finished && snapshot.currentFrame == 0 && snapshot.bufferedFrames == 0)
    _ = try await playback.stop()
    #expect(source.probe.reads.count == 1)
}

private struct PCMTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Test @MainActor func anUnexpectedPCMErrorIsReportedWithABoundedDiagnostic() async throws {
    let source = TestPCMSource(frameCount: 100) { _, _ in
        throw PCMTestError(message: String(repeating: "x", count: 500))
    }
    let playback = try OfflinePCMPlayback(source: source)
    try playback.prepare()
    var error = CDError()
    var snapshot = CDPlaybackSnapshot()
    try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
    #expect(error.code == Int32(CD_PRODUCER_ERROR.rawValue))
    #expect(decodeCString(error.message) == String(repeating: "x", count: 383))
    #expect(error.systemStatus == 0)
    _ = try await playback.stop()
}

@Test @MainActor func theCProducerRejectsAnOversizedNativeReadCountBeforeCopying() async throws {
    let source = CDPCMSource(
        frameCount: 100, context: nil, read: oversizedNativePCMRead, destroy: nil, readPacing: CD_READ_UNPACED,
        format: cd_source_format_compact_disc(), hdcdEligible: false
    )
    var error = CDError()
    let playback = try #require(cd_playback_create_source(source, 4_096, false, &error))
    defer { #expect(cd_playback_destroy(playback, &error) == 0) }
    #expect(cd_playback_prepare(playback, 0, &error) == 0)
    var snapshot = CDPlaybackSnapshot()
    try await waitUntil { cd_playback_snapshot(playback, &snapshot, &error) != 0 }
    #expect(error.code == Int32(CD_PRODUCER_ERROR.rawValue))
    #expect(decodeCString(error.message) == "The PCM source returned an invalid frame count")
    #expect(snapshot.bufferedFrames == 0 && !snapshot.finished)
}

@Test @MainActor func theCProducerReportsAnUndocumentedSourceFailureExplicitly() async throws {
    let source = CDPCMSource(
        frameCount: 100, context: nil, read: undocumentedNativePCMFailure, destroy: nil, readPacing: CD_READ_UNPACED,
        format: cd_source_format_compact_disc(), hdcdEligible: false
    )
    var error = CDError()
    let playback = try #require(cd_playback_create_source(source, 4_096, false, &error))
    defer { #expect(cd_playback_destroy(playback, &error) == 0) }
    #expect(cd_playback_prepare(playback, 0, &error) == 0)
    var snapshot = CDPlaybackSnapshot()
    try await waitUntil { cd_playback_snapshot(playback, &snapshot, &error) != 0 }
    #expect(error.code == Int32(CD_PRODUCER_ERROR.rawValue))
    #expect(error.systemStatus == Int32(CD_DISC_GONE.rawValue))
    #expect(decodeCString(error.message).hasPrefix("The PCM source failed without an error code"))
}

@Test @MainActor func aBlockedDiscProducerMutesImmediatelyAndDiscardsItsLateRead() async throws {
    let (session, disc) = try await fakeSession()
    let gate = TestGate()
    defer { gate.release() }
    disc.readGate = gate
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    try playback.prepare()
    try await waitUntil { gate.hasEntered }
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)
    cd_playback_request_stop(playback.pointer)
    var stopped = false
    let stopping = Task {
        _ = try await playback.stop()
        stopped = true
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!stopped)
    #expect(!disc.isClosed)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    gate.release()
    try await stopping.value
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 0)
    #expect(disc.reads.count == 1)

    // The cancelled block must never appear in a later run's buffer.
    let start = session.disc.totalFrames - 31
    try playback.prepare(at: start)
    let output = try await drainShortSource(playback.pointer, from: start, to: session.disc.totalFrames)
    #expect(output == pcmSamples(at: start, count: 31).map { Float($0) / 32_768 })
    _ = try await playback.stop()
    await session.close()
}

@Test @MainActor func aClosedDiscSessionFailsItsPCMProducerWithoutReopening() async throws {
    let (session, disc) = try await fakeSession()
    await session.close()
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    try playback.prepare()
    var error = CDError()
    var snapshot = CDPlaybackSnapshot()
    try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
    #expect(error.code == Int32(CD_DISC_FAILED.rawValue))
    #expect(decodeCString(error.message) == "The disc session is closed.")
    _ = try await playback.stop()
    #expect(disc.reads.isEmpty)
}

@Test(arguments: [CDReadError.Kind.refused, .gone, .failed])
@MainActor func discSessionFailuresAfterPlaybackBeginsMuteBufferedAudioWithoutRetrying(
    _ kind: CDReadError.Kind
) async throws {
    let (session, disc) = try await fakeSession()
    let failure = CDReadError(kind, "The next disc read failed.", systemError: 5)
    disc.unreadableSectors[7] = failure
    let adapter = DiscPCMSource(session: session)
    let gate = TestGate()
    let source = TestPCMSource(frameCount: adapter.frameCount) { frame, count in
        if frame >= 4_096 { try gate.wait() }
        return try adapter.read(at: frame, maxFrames: count)
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    defer { gate.release() }
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)
    let first = renderPlayback(playback.pointer, frames: 128)
    #expect(first == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    try await waitUntil { gate.hasEntered }
    gate.release()
    var snapshot = CDPlaybackSnapshot()
    var error = CDError()
    try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
    #expect(error.code == CDError(sourceError: failure).code && error.systemStatus == 5)
    #expect(decodeCString(error.message) == failure.message)
    #expect(snapshot.currentFrame == 128 && snapshot.bufferedFrames == 3_968 && !snapshot.finished)
    for _ in 0..<3 {
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        #expect(cd_playback_snapshot(playback.pointer, &snapshot, &error) == CDError(sourceError: failure).code)
    }
    _ = try await playback.stop()
    #expect(source.probe.reads.count == 2 && disc.reads.count == 2)
    #expect(disc.speedRequests == [RawCDReader.minimumSpeed] && disc.reads.allSatisfy { $0.errorFlags })
    await session.close()
}

@Test(arguments: [false, true])
@MainActor func removingOrClosingADiscSessionDuringReadAheadStopsOldAudio(close: Bool) async throws {
    let (session, disc) = try await fakeSession()
    let adapter = DiscPCMSource(session: session)
    let gate = TestGate()
    let source = TestPCMSource(frameCount: adapter.frameCount) { frame, count in
        if frame >= 4_096 { try gate.wait() }
        return try adapter.read(at: frame, maxFrames: count)
    }
    let playback = try OfflinePCMPlayback(source: source, bufferFrames: 4_096)
    defer { gate.release() }
    try playback.prepare()
    try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 4_096 }
    cd_playback_enable_output(playback.pointer)
    #expect(renderPlayback(playback.pointer, frames: 128) == pcmSamples(at: 0, count: 128).map { Float($0) / 32_768 })
    try await waitUntil { gate.hasEntered }
    if close { await session.close() }
    else { disc.remove() }
    gate.release()
    var snapshot = CDPlaybackSnapshot()
    var error = CDError()
    try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
    #expect(error.code == Int32((close ? CD_DISC_FAILED : CD_DISC_GONE).rawValue))
    #expect(!decodeCString(error.message).isEmpty)
    #expect(snapshot.currentFrame == 128 && snapshot.bufferedFrames == 3_968)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    _ = try await playback.stop()
    #expect(source.probe.reads.count == 2 && disc.reads.count == 1)
    await session.close()
    #expect(disc.isClosed)
}

@Test @MainActor func aCancelledDiscReadFailureDoesNotOutliveStopOrSessionClose() async throws {
    let (session, disc) = try await fakeSession()
    let gate = TestGate()
    disc.readGate = gate
    disc.unreadableSectors[0] = CDReadError(.mediaError, "The cancelled disc read failed.", systemError: EIO)
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    defer { gate.release() }
    try playback.prepare()
    try await waitUntil { gate.hasEntered }
    cd_playback_enable_output(playback.pointer)
    cd_playback_request_stop(playback.pointer)
    var stopped = false
    let stopping = Task {
        let result = try await playback.stop()
        stopped = true
        return result
    }
    let closing = Task { await session.close() }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!stopped && !disc.isClosed)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    gate.release()
    let result = try await stopping.value
    _ = await closing.value
    #expect(result.currentFrame == 0 && result.bufferedFrames == 0 && !result.finished)
    #expect(result.concealedSectors == 0 && !result.unverified)
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)
    #expect(disc.isClosed && disc.reads.count == 1)
    #expect(await session.isOpen == false)
}

@Test @MainActor func thePCMSourceIsRetainedUntilItsPlaybackStorageIsDestroyed() async throws {
    let probe = PCMSourceProbe()
    var source: TestPCMSource? = TestPCMSource(frameCount: 100, probe: probe)
    var playback: OfflinePCMPlayback? = try OfflinePCMPlayback(source: #require(source))
    source = nil
    #expect(!probe.isDestroyed)
    try playback?.prepare()
    try await waitUntil { probe.reads.count == 1 }
    _ = try await playback?.stop()
    #expect(!probe.isDestroyed)
    playback = nil
    #expect(probe.isDestroyed)
}

@Test @MainActor func playbackRefusesASourceFormatItCannotCarryUnchanged() async {
    let probe = PCMSourceProbe()
    var source: TestPCMSource? = TestPCMSource(
        frameCount: 4_096, format: .compactDiscAudio(channels: 4), probe: probe
    )
    do {
        let playback = try makePCMPlayback(source: #require(source), bufferFrames: 4_096)
        var error = CDError()
        #expect(cd_playback_destroy(playback, &error) == 0)
        Issue.record("A four-channel source must be refused.")
    } catch let error as AudioPlaybackError {
        #expect(error.code == Int32(CD_FORMAT_UNAVAILABLE.rawValue))
        #expect(error.message == "This disc's audio (44.1 kHz, 16-bit, 4 channels) is not supported. " +
            "CD Player plays 44.1 kHz 16-bit stereo audio CDs")
    } catch {
        Issue.record("Unexpected construction failure: \(error)")
    }
    source = nil
    #expect(probe.isDestroyed)
    #expect(probe.reads.isEmpty)
}

@Test @MainActor func rejectedPCMConstructionDoesNotKeepItsSource() async {
    for (frames, buffer): (UInt64, Int) in [(0, 4_096), (100, 4_095)] {
        let probe = PCMSourceProbe()
        var source: TestPCMSource? = TestPCMSource(frameCount: frames, probe: probe)
        do {
            let playback = try makePCMPlayback(source: #require(source), bufferFrames: buffer)
            var error = CDError()
            #expect(cd_playback_destroy(playback, &error) == 0)
            Issue.record("Invalid construction must fail.")
        } catch let error as AudioPlaybackError {
            #expect(error.code == Int32(CD_INVALID_ARGUMENT.rawValue))
        } catch {
            Issue.record("Unexpected construction failure: \(error)")
        }
        source = nil
        #expect(probe.isDestroyed)
        #expect(probe.reads.isEmpty)
    }
    var error = CDError()
    let missingRead = CDPCMSource(
        frameCount: 100, context: nil, read: nil, destroy: nil, readPacing: CD_READ_UNPACED,
        format: cd_source_format_compact_disc(), hdcdEligible: false
    )
    #expect(cd_playback_create_source(missingRead, 4_096, false, &error) == nil)
    #expect(error.code == Int32(CD_INVALID_ARGUMENT.rawValue))
}

@Test @MainActor func physicalTimelinesCannotSilentlyUseTheDemoTonePath() async throws {
    let (session, disc) = try await fakeSession()
    let incorrect = CoreAudioPlaybackEngine(disc: session.disc)
    do {
        _ = try await incorrect.start(at: 0)
        Issue.record("A physical timeline must not be played as silent demo tones.")
    } catch let error as AudioPlaybackError {
        #expect(error.code == Int32(CD_INVALID_ARGUMENT.rawValue))
        #expect(error.message == "A physical disc requires an open disc session, not a demo source.")
    }
    let correct = CoreAudioPlaybackEngine(session: session)
    do {
        _ = try await correct.start(at: session.disc.totalFrames)
        Issue.record("An out-of-range start must fail before audio-device access.")
    } catch let error as AudioPlaybackError {
        #expect(error.message == "Playback must start within the disc")
    }
    #expect(disc.reads.isEmpty)
    await session.close()
}
