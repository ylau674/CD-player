import CDAudioCore
import Dispatch
import Foundation
import Testing
@testable import CDKit

private final class SharedLevelTable: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

private final class ReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var isReleased = false

    var entered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didEnter
    }

    func waitUntilReleased() {
        condition.lock()
        didEnter = true
        condition.broadcast()
        while !isReleased { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private func releaseReadGate(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<ReadGate>.fromOpaque(context).release()
}

private func failedPCMRead(
    _ context: UnsafeMutableRawPointer?, _ frame: UInt64, _ stereo: UnsafeMutablePointer<Int16>?,
    _ capacity: Int, _ request: UnsafePointer<CDPCMReadContext>?,
    _ result: UnsafeMutablePointer<CDPCMReadResult>?, _ error: UnsafeMutablePointer<CDError>?
) -> Int32 {
    let failure = CDError(result: CD_DISC_READ_ERROR, message: "Expected offline test read failure.")
    error?.pointee = failure
    return failure.code
}

private func cancelledPCMRead(
    _ context: UnsafeMutableRawPointer?, _ frame: UInt64, _ stereo: UnsafeMutablePointer<Int16>?,
    _ capacity: Int, _ request: UnsafePointer<CDPCMReadContext>?,
    _ result: UnsafeMutablePointer<CDPCMReadResult>?, _ error: UnsafeMutablePointer<CDError>?
) -> Int32 {
    guard let context else { return Int32(CD_INVALID_ARGUMENT.rawValue) }
    Unmanaged<ReadGate>.fromOpaque(context).takeUnretainedValue().waitUntilReleased()
    let failure = CDError(result: CD_DISC_READ_ERROR, message: "Expected offline test cancellation.")
    error?.pointee = failure
    return failure.code
}

private func awaitCondition(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for the offline PCM producer.")
}

private func makeTestSource(
    context: UnsafeMutableRawPointer? = nil,
    read: (@convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutablePointer<Int16>?, Int,
                           UnsafePointer<CDPCMReadContext>?, UnsafeMutablePointer<CDPCMReadResult>?,
                           UnsafeMutablePointer<CDError>?) -> Int32)?,
    destroy: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil
) -> CDPCMSource {
    CDPCMSource(
        frameCount: 8_192, context: context, read: read, destroy: destroy,
        readPacing: CD_READ_UNPACED, format: cd_source_format_compact_disc(), hdcdEligible: false
    )
}

@Test func levelTableKeepsPerChannelPeaksAcrossSlotBoundaries() throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }
    let run = cd_level_table_begin_run(table)
    #expect(run != 0)

    let samples: [Int16] = [32_767, 0, -32_768, -32_768, 7, 0]
    let startFrame = UInt64(CD_LEVEL_SLOT_FRAMES) - 1
    #expect(samples.withUnsafeBufferPointer {
        cd_level_table_record_block(table, run, startFrame, $0.baseAddress, 3)
    })

    var firstSlot = CDLevelPeaks()
    var secondSlot = CDLevelPeaks()
    #expect(cd_level_table_read(table, run, startFrame, &firstSlot))
    #expect(cd_level_table_read(table, run, startFrame + 1, &secondSlot))
    #expect(firstSlot.leftPeak == 32_767)
    #expect(firstSlot.rightPeak == 0)
    #expect(secondSlot.leftPeak == 32_768)
    #expect(secondSlot.rightPeak == 32_768)
}

@Test func levelTableMergesBlocksThatShareASlot() throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }
    let run = cd_level_table_begin_run(table)

    let first: [Int16] = [100, -200, 80, -40]
    let second: [Int16] = [300, -100]
    #expect(first.withUnsafeBufferPointer {
        cd_level_table_record_block(table, run, 10, $0.baseAddress, 2)
    })
    #expect(second.withUnsafeBufferPointer {
        cd_level_table_record_block(table, run, 12, $0.baseAddress, 1)
    })

    var peaks = CDLevelPeaks()
    #expect(cd_level_table_read(table, run, 440, &peaks))
    #expect(peaks.leftPeak == 300)
    #expect(peaks.rightPeak == 200)
}

@Test func newLevelRunHidesPriorRunAndWraparoundRejectsOldPosition() throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }

    let firstRun = cd_level_table_begin_run(table)
    let fullScale: [Int16] = [-32_768, 32_767]
    #expect(fullScale.withUnsafeBufferPointer {
        cd_level_table_record_block(table, firstRun, 0, $0.baseAddress, 1)
    })

    let nextRun = cd_level_table_begin_run(table)
    #expect(nextRun != firstRun)
    var peaks = CDLevelPeaks()
    #expect(!cd_level_table_read(table, nextRun, 0, &peaks))
    #expect(!cd_level_table_read(table, firstRun, 0, &peaks))

    let wrappedFrame = UInt64(CD_LEVEL_SLOT_COUNT) * UInt64(CD_LEVEL_SLOT_FRAMES)
    let lowerPeak: [Int16] = [123, -456]
    #expect(lowerPeak.withUnsafeBufferPointer {
        cd_level_table_record_block(table, nextRun, wrappedFrame, $0.baseAddress, 1)
    })
    #expect(!cd_level_table_read(table, nextRun, 0, &peaks))
    #expect(cd_level_table_read(table, nextRun, wrappedFrame, &peaks))
    #expect(peaks.leftPeak == 123)
    #expect(peaks.rightPeak == 456)
}

@Test func reusedRunTagClearsSlotsBeforePublishingTheNewRun() throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }
    let firstRun = cd_level_table_begin_run(table)
    let sample: [Int16] = [1_000, -1_000]
    #expect(sample.withUnsafeBufferPointer {
        cd_level_table_record_block(table, firstRun, 0, $0.baseAddress, 1)
    })

    var run = firstRun
    for _ in 0..<255 {
        run = cd_level_table_begin_run(table)
    }

    var peaks = CDLevelPeaks()
    #expect(run != firstRun)
    #expect(!cd_level_table_read(table, run, 0, &peaks))
}

@Test func levelSourceReadsOnlyTheCurrentRunAcrossRequestedSlots() throws {
    let source = CoreAudioLevelSource()
    let table = try source.playbackTable()
    #expect(cd_level_table_current_run(table) == 0)
    let run = cd_level_table_begin_run(table)
    let firstBlock: [Int16] = [1_000, -2_000]
    let secondBlock: [Int16] = [3_000, -4_000]
    #expect(firstBlock.withUnsafeBufferPointer {
        cd_level_table_record_block(table, run, 0, $0.baseAddress, 1)
    })
    #expect(secondBlock.withUnsafeBufferPointer {
        cd_level_table_record_block(table, run, UInt64(CD_LEVEL_SLOT_FRAMES), $0.baseAddress, 1)
    })
    #expect(cd_level_table_current_run(table) == run)
    #expect(source.peaks(fromFrame: 0, throughFrame: UInt64(CD_LEVEL_SLOT_FRAMES)) ==
        AudioLevelPeaks(leftPeak: 3_000, rightPeak: 4_000))
    #expect(source.peaks(fromFrame: 0, throughFrame: 0) ==
        AudioLevelPeaks(leftPeak: 1_000, rightPeak: 2_000))

    _ = cd_level_table_begin_run(table)
    #expect(source.peaks(fromFrame: 0, throughFrame: UInt64(CD_LEVEL_SLOT_FRAMES)) == nil)
}

@Test func producerRecordsDemoToneOnlyAfterItEntersTheRing() async throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }
    var track = CDDemoTrack(frameCount: 8_192, frequency: 220, amplitude: 3_276)
    var error = CDError()
    let createdPlayback = withUnsafePointer(to: &track) {
        cd_playback_create_with_levels($0, 1, 4_096, table, &error)
    }
    let playback = try #require(createdPlayback)
    defer {
        var destroyError = CDError()
        #expect(cd_playback_destroy(playback, &destroyError) == 0, "\(decodeCString(destroyError.message))")
    }
    #expect(cd_playback_prepare(playback, 0, &error) == 0, "\(decodeCString(error.message))")

    let run = cd_playback_level_run(playback)
    #expect(run != 0)
    var peaks = CDLevelPeaks()
    try await awaitCondition { cd_level_table_read(table, run, 0, &peaks) }
    let decibels = 20 * log10(Double(peaks.leftPeak) / 32_768)
    #expect(abs(decibels + 20) < 0.1)
    #expect(peaks.rightPeak == peaks.leftPeak)
}

@Test(arguments: [DiscRetryPolicy.singlePass, .retry])
@MainActor func discProducerPublishesRecoveredSourcePeaks(_ policy: DiscRetryPolicy) async throws {
    let data = tocFixture()
    let tableOfContents = try CDTableOfContents(data: data)
    let media = OpticalMedia(
        id: 11, bsdName: "disk4", contents: .audioCD(tableOfContents), isMounted: false, isEjectable: true
    )
    let opener = FakeDiscOpener(tableOfContents: data)
    let session = try await DiscSession.open(
        media, driveID: 1, tableOfContents: tableOfContents, opener: opener
    )
    await session.setRetryPolicy(policy)
    let levelSource = CoreAudioLevelSource()
    let playback = try OfflinePCMPlayback(
        source: DiscPCMSource(session: session), bufferFrames: 4_096, levelSource: levelSource
    )

    try playback.prepare()
    var firstSlot: AudioLevelPeaks?
    for _ in 0..<1_000 where firstSlot == nil {
        firstSlot = levelSource.peaks(fromFrame: 0, throughFrame: 0)
        if firstSlot == nil { try await Task.sleep(for: .milliseconds(1)) }
    }
    #expect(firstSlot != nil)
    let actual = try #require(levelSource.peaks(fromFrame: 0, throughFrame: UInt64(CD_LEVEL_SLOT_FRAMES - 1)))
    let samples = pcmSamples(at: 0, count: Int(CD_LEVEL_SLOT_FRAMES))
    func magnitude(_ sample: Int16) -> UInt16 {
        UInt16(sample < 0 ? -Int32(sample) : Int32(sample))
    }
    let expected = AudioLevelPeaks(
        leftPeak: stride(from: 0, to: samples.count, by: 2).map { magnitude(samples[$0]) }.max() ?? 0,
        rightPeak: stride(from: 1, to: samples.count, by: 2).map { magnitude(samples[$0]) }.max() ?? 0
    )
    #expect(actual == expected)
    #expect(await session.retryPolicy == policy)
    _ = try await playback.stop()
    await session.close()
}

@Test func failedPCMReadDoesNotPublishLevels() async throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }
    var error = CDError()
    let source = makeTestSource(read: failedPCMRead)
    let playback = try #require(cd_playback_create_source_with_levels(
        source, 4_096, false, table, &error
    ))
    defer {
        var destroyError = CDError()
        #expect(cd_playback_destroy(playback, &destroyError) == 0, "\(decodeCString(destroyError.message))")
    }
    #expect(cd_playback_prepare(playback, 0, &error) == 0, "\(decodeCString(error.message))")

    try await awaitCondition {
        var snapshot = CDPlaybackSnapshot()
        var snapshotError = CDError()
        return cd_playback_snapshot(playback, &snapshot, &snapshotError) ==
            Int32(CD_DISC_READ_ERROR.rawValue)
    }
    var peaks = CDLevelPeaks()
    #expect(!cd_level_table_read(table, cd_playback_level_run(playback), 0, &peaks))
}

@Test func cancelledPCMReadDoesNotPublishLevels() async throws {
    let table = try #require(cd_level_table_create())
    defer { cd_level_table_destroy(table) }
    let gate = ReadGate()
    let context = Unmanaged.passRetained(gate)
    var error = CDError()
    let source = makeTestSource(
        context: context.toOpaque(), read: cancelledPCMRead, destroy: releaseReadGate
    )
    let playback = try #require(cd_playback_create_source_with_levels(
        source, 4_096, false, table, &error
    ))
    defer {
        gate.release()
        var destroyError = CDError()
        #expect(cd_playback_destroy(playback, &destroyError) == 0, "\(decodeCString(destroyError.message))")
    }
    #expect(cd_playback_prepare(playback, 0, &error) == 0, "\(decodeCString(error.message))")
    try await awaitCondition { gate.entered }

    cd_playback_request_stop(playback)
    gate.release()
    var snapshot = CDPlaybackSnapshot()
    #expect(cd_playback_stop(playback, &snapshot, &error) == 0, "\(decodeCString(error.message))")
    var peaks = CDLevelPeaks()
    #expect(!cd_level_table_read(table, cd_playback_level_run(playback), 0, &peaks))
}

@Test func producerAndReaderObserveWholeAtomicPeakPairs() throws {
    let table = SharedLevelTable(try #require(cd_level_table_create()))
    defer { cd_level_table_destroy(table.pointer) }
    let run = cd_level_table_begin_run(table.pointer)
    let writerDone = DispatchSemaphore(value: 0)
    let invalidPair = LockedFlag()

    DispatchQueue.global(qos: .userInitiated).async {
        for value in 1...32_767 {
            let samples = [Int16(value), Int16(-value)]
            let recorded = samples.withUnsafeBufferPointer {
                cd_level_table_record_block(table.pointer, run, 0, $0.baseAddress, 1)
            }
            if !recorded {
                invalidPair.set()
                break
            }
        }
        writerDone.signal()
    }

    while writerDone.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
        var peaks = CDLevelPeaks()
        if cd_level_table_read(table.pointer, run, 0, &peaks),
           peaks.leftPeak != peaks.rightPeak {
            invalidPair.set()
        }
    }
    var finalPeaks = CDLevelPeaks()
    #expect(cd_level_table_read(table.pointer, run, 0, &finalPeaks))
    #expect(finalPeaks.leftPeak == 32_767)
    #expect(finalPeaks.rightPeak == 32_767)
    #expect(!invalidPair.isSet)
}
