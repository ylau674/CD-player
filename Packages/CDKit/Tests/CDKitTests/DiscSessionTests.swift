import CDAudioCore
import Foundation
import Testing
@testable import CDKit

private func audioCD(id: UInt64 = 10) throws -> (media: OpticalMedia, table: CDTableOfContents) {
    let table = try CDTableOfContents(data: tocFixture())
    return (OpticalMedia(id: id, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true), table)
}

@Test @MainActor func aSessionOpensOffTheMainThreadAndReadsUntilClosed() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    #expect(opener.opens == [.init(mediaID: 10, driveID: 1, onMainThread: false)])
    #expect(session.mediaID == 10 && session.driveID == 1)
    #expect(session.disc == Disc(tableOfContents: cd.table))
    #expect(await session.isOpen)
    #expect(try await session.read(from: 5, count: 2, errorFlags: false).audio == FakeCDSectorSource.audio(from: 5, count: 2))
    #expect(try await session.speed() == 4_234)
    await session.close()
    let disc = try #require(opener.discs.first)
    #expect(disc.isClosed)
    #expect(await session.isOpen == false)
    do {
        _ = try await session.read(from: 5, count: 1, errorFlags: false)
        Issue.record("A closed session must not read.")
    } catch {
        #expect((error as? CDReadError)?.message == "The disc session is closed.")
    }
    await session.close()
}

@Test @MainActor func aC2ProbeCountsFlaggedAudioBytesAndSectors() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.flaggedBytes = [.init(sector: 10, offset: 0), .init(sector: 10, offset: 1)]

    let probe = try await session.probeC2(at: 10)

    #expect(probe.support == .supported)
    #expect(probe.flaggedAudioBytes == 2 && probe.flaggedSectors == 1)
    #expect(disc.reads == [.init(firstSector: 10, count: 1, errorFlags: true)])
    _ = await session.close()
}

@Test @MainActor func aC2ProbeFallsBackOnlyAfterTheIdenticalPlainReadSucceeds() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.supportsErrorFlags = false

    let probe = try await session.probeC2(at: 10)

    #expect(probe.support == .unsupported)
    #expect(disc.reads.map(\.errorFlags) == [true, false])
    _ = await session.close()
}

@Test(arguments: [CDReadError.Kind.refused, .gone])
@MainActor func aC2ProbeNeverRetriesAnAccessRefusalOrRemovedDrive(_ kind: CDReadError.Kind) async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.supportsErrorFlags = false
    let failure = CDReadError(kind, "The C2 probe is refused or the drive was removed.", systemError: EPERM)
    disc.errorFlagRejection = failure

    do {
        _ = try await session.probeC2(at: 10)
        Issue.record("A refusal or removal must not be retried as a plain read.")
    } catch {
        #expect(error as? CDReadError == failure)
    }

    #expect(disc.reads.map(\.errorFlags) == [true])
    _ = await session.close()
}

@Test @MainActor func aDiscWhoseTrackTableDiffersIsClosedAndNotKept() async throws {
    let cd = try audioCD()
    let other = tocFixture([TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 1_000)])
    let opener = FakeDiscOpener(tableOfContents: other)
    do {
        _ = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
        Issue.record("A different disc must not be kept.")
    } catch {
        #expect((error as? CDReadError)?.message == "The disc's own track table does not match the one macOS reported.")
    }
    #expect(opener.discs.first?.isClosed == true)
}

@Test @MainActor func aRefusalIsReportedUntouchedAfterOneAttempt() async throws {
    let cd = try audioCD()
    let refusal = CDReadError(.refused, "Cannot open the optical disc for reading: Operation not permitted (errno 1).", systemError: EPERM)
    let opener = FakeDiscOpener(failure: refusal)
    do {
        _ = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
        Issue.record("A refused disc must not open.")
    } catch {
        #expect(error as? CDReadError == refusal)
    }
    #expect(opener.opens.count == 1)
    #expect(opener.discs.isEmpty)
}

@Test @MainActor func closingWaitsForAReadInProgress() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    try await session.prepareForPlayback()
    let gate = TestGate()
    disc.readGate = gate
    defer { gate.release() }
    var readCompleted = false
    let reading = Task {
        let block = try await session.read(from: 0, count: 1, errorFlags: false)
        readCompleted = true
        return block
    }
    try await waitUntil { gate.hasEntered }
    var closeStarted = false
    var closeCompleted = false
    let closing = Task {
        closeStarted = true
        await session.close()
        closeCompleted = true
    }
    try await waitUntil { closeStarted }
    #expect(!readCompleted && !closeCompleted && !disc.isClosed)
    #expect(Array(disc.operations.suffix(1)) == [.read])
    gate.release()
    #expect(try await reading.value.sectorCount == 1)
    await closing.value
    #expect(readCompleted && closeCompleted && disc.isClosed)
    #expect(Array(disc.operations.suffix(3)) == [.setSpeed(4_234), .speed, .close])
}

@Test func theRealOpenerRejectsUnreadyOrStaleDiscsBeforeOpeningAnything() throws {
    let table = try CDTableOfContents(data: tocFixture())
    let unready = OpticalMedia(id: 1, bsdName: nil, contents: .audioCD(table), isMounted: nil, isEjectable: true)
    let missing = OpticalMedia(id: 1, bsdName: "disk9999", contents: .audioCD(table), isMounted: nil, isEjectable: true)
    let notReady = readError { _ = try RawDiscOpener().open(unready, driveID: 1) }
    #expect(notReady?.kind == .failed)
    #expect(notReady?.message == "The selected optical disc is not ready for reading.")
    let gone = readError { _ = try RawDiscOpener().open(missing, driveID: 1) }
    #expect(gone?.kind == .gone)
    #expect(gone?.message == "The selected disc was removed or replaced before it could be read.")
}

@Test @MainActor func playbackSpeedIsPreparedLazilyOnceAndRestoredBeforeClosing() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    #expect(RawCDReader.minimumSpeed == 176)
    #expect(DiscPCMSource(session: session).readPacing == CD_READ_STEADY)
    #expect(DiscPCMSource(session: session, readPacing: .burst).readPacing == CD_READ_BURST)
    #expect(disc.operations == [.tableOfContents])
    try await session.prepareForPlayback()
    let prepared = disc.operations
    #expect(prepared == [.tableOfContents, .speed, .setSpeed(176), .speed])
    #expect(try await session.speed() == 176)
    let afterInspection = disc.operations
    for _ in 0..<3 { try await session.prepareForPlayback() }
    #expect(disc.operations == afterInspection)
    let closeReport = await session.close()
    #expect(closeReport.speedChangeAttempted && closeReport.originalSpeed == 4_234)
    #expect(closeReport.speedRestored && closeReport.restoredSpeed == 4_234)
    #expect(Array(disc.operations.suffix(3)) == [.setSpeed(4_234), .speed, .close])
    #expect(disc.speedRequests == [176, 4_234] && disc.isClosed)
    #expect(!disc.usedMainThread)
    let closed = disc.operations
    await session.close()
    #expect(disc.operations == closed)
}

@Test @MainActor func aDriveCanIgnoreTheMinimumRequestWithoutBeingMisreportedAsOneTimes() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.obeysSpeedRequests = false
    try await session.prepareForPlayback()
    #expect(try await session.speed() == 4_234)
    #expect(await session.readStatistics.kilobytesPerSecond == nil)
    await session.close()
    #expect(disc.speedRequests == [176, 4_234] && disc.isClosed)
}

@Test(arguments: [UInt16(176), 1_000, UInt16.max])
@MainActor func validOriginalSpeedsIncludingTheMaximumSettingAreRestored(_ original: UInt16) async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.reportedSpeed = original
    try await session.prepareForPlayback()
    await session.close()
    #expect(disc.speedRequests == [176, original])
    #expect(disc.reportedSpeed == original && disc.isClosed)
}

@Test @MainActor func anUnknownSpeedReadbackStillRestoresTheSavedOriginal() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.speedReadReplies = [.success(4_234), .success(0)]
    try await session.prepareForPlayback()
    await session.close()
    #expect(disc.speedRequests == [176, 4_234] && disc.reportedSpeed == 4_234 && disc.isClosed)
}

@Test(arguments: [0, 1, 2], [CDReadError.Kind.failed, .mediaError])
@MainActor func optionalSpeedControlFailuresAreLoggedAndNotRetried(stage: Int, kind: CDReadError.Kind) async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    let failure = CDReadError(kind, "The drive does not support this speed operation.", systemError: ENOTSUP)
    switch stage {
    case 0: disc.speedReadReplies = [.failure(failure)]
    case 1: disc.speedSetFailures = [failure]
    default: disc.speedReadReplies = [.success(4_234), .failure(failure)]
    }
    try await session.prepareForPlayback()
    let prepared = disc.operations
    try await session.prepareForPlayback()
    #expect(disc.operations == prepared)
    #expect(try await session.read(from: 0, count: 1, errorFlags: false).sectorCount == 1)
    await session.close()
    let expected: [UInt16] = stage == 0 ? [] : [176, 4_234]
    #expect(disc.speedRequests == expected && disc.isClosed)
}

@Test(arguments: [0, 1, 2], [CDReadError.Kind.refused, .gone])
@MainActor func speedRefusalsAndRemovalStopPreparationWithoutRetrying(stage: Int, kind: CDReadError.Kind) async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    let failure = CDReadError(kind, "Speed control was refused or the drive disappeared.", systemError: EPERM)
    switch stage {
    case 0: disc.speedReadReplies = [.failure(failure)]
    case 1: disc.speedSetFailures = [failure]
    default: disc.speedReadReplies = [.success(4_234), .failure(failure)]
    }
    for _ in 0..<2 {
        do {
            try await session.prepareForPlayback()
            Issue.record("Refused or removed drives must not be used for PCM.")
        } catch {
            #expect(error as? CDReadError == failure)
        }
    }
    #expect(disc.operations.filter { $0 == .speed }.count == (stage == 2 ? 2 : 1))
    #expect(disc.reads.isEmpty)
    await session.close()
    #expect(disc.isClosed && !disc.usedMainThread)
}

@Test @MainActor func anUnknownOriginalSpeedIsNotChangedBecauseItCannotBeRestored() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.reportedSpeed = 0
    try await session.prepareForPlayback()
    try await session.prepareForPlayback()
    await session.close()
    #expect(disc.operations == [.tableOfContents, .speed, .close])
    #expect(disc.speedRequests.isEmpty)
}

@Test(arguments: [0, 1, 2, 3])
@MainActor func failedSpeedRestorationStillClosesTheDiscExactlyOnce(_ failureKind: Int) async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    try await session.prepareForPlayback()
    let failure = CDReadError(.failed, "Cannot restore the drive speed.", systemError: ENOTSUP)
    switch failureKind {
    case 0: disc.speedSetFailures = [failure]
    case 1: disc.speedReadReplies = [.failure(failure)]
    case 2: disc.obeysSpeedRequests = false
    default: disc.remove()
    }
    let closeReport = await session.close()
    #expect(closeReport.speedChangeAttempted && !closeReport.speedRestored)
    #expect(await session.isOpen == false)
    #expect(disc.operations.filter { $0 == .setSpeed(4_234) }.count == 1)
    #expect(disc.operations.last == .close && disc.isClosed)
    let closed = disc.operations
    await session.close()
    #expect(disc.operations == closed)
}

@Test @MainActor func explicitSessionSpeedChangesAlsoRestoreTheOriginalNotAnIntermediateSpeed() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    try await session.setSpeed(1_000)
    try await session.setSpeed(2_000)
    await session.close()
    #expect(disc.speedRequests == [1_000, 2_000, 4_234])
    #expect(disc.operations.filter { $0 == .speed }.count == 2)
    #expect(disc.reportedSpeed == 4_234 && disc.isClosed)
}

@Test @MainActor func aFailedOptionalSpeedRequestStillAttemptsOriginalSpeedRestorationOnClose() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    let failure = CDReadError(.failed, "The speed request may have been partially applied.", systemError: ENOTSUP)
    disc.speedSetFailures = [failure]

    do {
        try await session.setSpeed(RawCDReader.minimumSpeed)
        Issue.record("The scripted speed request must fail.")
    } catch {
        #expect(error as? CDReadError == failure)
    }
    let report = await session.close()

    #expect(disc.speedRequests == [176, 4_234])
    #expect(report.speedChangeAttempted && report.speedRestored && report.restoredSpeed == 4_234)
    #expect(disc.isClosed)
}

@Test func readThroughputCountsRawAudioAndFailedReadTimeWithoutInferringDriveSpeed() {
    var statistics = DiscReadStatistics()
    #expect(statistics.kilobytesPerSecond == nil)
    statistics.record(audioBytes: 176_400, duration: .seconds(1))
    #expect(statistics.readCount == 1 && statistics.audioBytes == 176_400)
    #expect(statistics.kilobytesPerSecond == 176.4)
    statistics.record(audioBytes: 0, duration: .seconds(1))
    #expect(statistics.readCount == 2 && statistics.readDuration == .seconds(2))
    #expect(statistics.kilobytesPerSecond == 88.2)
}

@Test @MainActor func sessionThroughputExcludesC2BytesAndRetainsFailedAttemptTime() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    disc.delay = .milliseconds(20)
    let block = try await session.read(from: 0, count: 1, errorFlags: true)
    #expect(block.errorFlags?.count == 294)
    let failure = CDReadError(.mediaError, "A timed read failed.", systemError: EIO)
    disc.unreadableSectors[2] = failure
    do {
        _ = try await session.read(from: 2, count: 1, errorFlags: false)
        Issue.record("The scripted read must fail.")
    } catch {
        #expect(error as? CDReadError == failure)
    }
    let statistics = await session.readStatistics
    #expect(statistics.readCount == 2 && statistics.audioBytes == 2_352)
    #expect(statistics.readDuration >= .milliseconds(40))
    #expect(statistics.kilobytesPerSecond != nil)
    await session.close()
    #expect(disc.speedRequests.isEmpty)
}

@Test(arguments: [CDReadError.Kind.refused, .gone])
@MainActor func aFatalSpeedErrorReachesThePCMProducerWithoutAnAudioReadOrRetry(_ kind: CDReadError.Kind) async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    let failure = CDReadError(kind, "The speed request cannot proceed.", systemError: EPERM)
    disc.speedSetFailures = [failure]
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    for _ in 0..<2 {
        try playback.prepare()
        var snapshot = CDPlaybackSnapshot()
        var error = CDError()
        try await waitUntil { cd_playback_snapshot(playback.pointer, &snapshot, &error) != 0 }
        #expect(error.code == CDError(sourceError: failure).code && error.systemStatus == EPERM)
        #expect(decodeCString(error.message) == failure.message)
        cd_playback_enable_output(playback.pointer)
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        _ = try await playback.stop()
    }
    #expect(disc.reads.isEmpty && disc.speedRequests == [176])
    await session.close()
}

@Test @MainActor func stoppingDuringBlockedSlowdownMutesBeforeWaitingAndStillRestoresOnClose() async throws {
    let cd = try audioCD()
    let opener = FakeDiscOpener()
    let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
    let disc = try #require(opener.discs.first)
    let gate = TestGate()
    disc.speedSetGate = gate
    defer { gate.release() }
    let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
    try playback.prepare()
    try await waitUntil { gate.hasEntered }
    cd_playback_enable_output(playback.pointer)
    cd_playback_request_stop(playback.pointer)
    var stopStarted = false
    var stopped = false
    let stopping = Task {
        stopStarted = true
        _ = try await playback.stop()
        stopped = true
    }
    var closeStarted = false
    var closed = false
    let closing = Task {
        closeStarted = true
        await session.close()
        closed = true
    }
    try await waitUntil { stopStarted && closeStarted }
    #expect(!stopped && !closed && !disc.isClosed)
    #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
    gate.release()
    try await stopping.value
    await closing.value
    #expect(try playbackSnapshot(playback.pointer).bufferedFrames == 0)
    #expect(try playbackSnapshot(playback.pointer).currentFrame == 0)
    #expect(disc.speedRequests == [176, 4_234] && disc.isClosed && !disc.usedMainThread)
}

@Test(arguments: [false, true])
@MainActor func readStatisticsAreHandedOffSafelyDuringProducerCancellationAndClose(fails: Bool) async throws {
    let cd = try audioCD()
    for _ in 0..<10 {
        let opener = FakeDiscOpener()
        let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
        let disc = try #require(opener.discs.first)
        let gate = TestGate()
        disc.readGate = gate
        if fails { disc.unreadableSectors[0] = CDReadError(.mediaError, "The cancelled read failed.") }
        defer { gate.release() }
        let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
        try playback.prepare()
        try await waitUntil { gate.hasEntered }
        cd_playback_request_stop(playback.pointer)
        let stopping = Task { try await playback.stop() }
        var samplingStarted = false
        var sampled = false
        let sampling = Task {
            samplingStarted = true
            let statistics = await session.readStatistics
            sampled = true
            return statistics
        }

        var closeStarted = false
        var closed = false
        let closing = Task {
            closeStarted = true
            await session.close()
            closed = true
        }
        try await waitUntil { samplingStarted && closeStarted }
        #expect(!sampled && !closed && !disc.isClosed)
        gate.release()
        let statistics = await sampling.value
        let result = try await stopping.value
        await closing.value
        #expect(statistics.readCount == 1 && statistics.readDuration > .zero)
        #expect(statistics.audioBytes == (fails ? 0 : 7 * 2_352))
        #expect(await session.readStatistics == statistics)
        #expect(result.currentFrame == 0 && result.bufferedFrames == 0)
        #expect(disc.reads.count == 1 && disc.isClosed && !disc.usedMainThread)
    }
}

@Test(arguments: [false, true])
@MainActor func speedPreparationStateIsHandedOffDuringCancellationAndClose(fails: Bool) async throws {
    let cd = try audioCD()
    for _ in 0..<10 {
        let opener = FakeDiscOpener()
        let session = try await DiscSession.open(cd.media, driveID: 1, tableOfContents: cd.table, opener: opener)
        let disc = try #require(opener.discs.first)
        let gate = TestGate()
        disc.speedSetGate = gate
        if fails { disc.speedSetFailures = [CDReadError(.refused, "The cancelled speed request was refused.")] }
        defer { gate.release() }
        let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
        try playback.prepare()
        try await waitUntil { gate.hasEntered }
        cd_playback_request_stop(playback.pointer)
        let stopping = Task { try await playback.stop() }
        var closeStarted = false
        var closed = false
        let closing = Task {
            closeStarted = true
            await session.close()
            closed = true
        }
        try await waitUntil { closeStarted }
        #expect(!closed && !disc.isClosed)
        gate.release()
        let result = try await stopping.value
        await closing.value
        #expect(result.currentFrame == 0 && result.bufferedFrames == 0)
        #expect(result.concealedSectors == 0 && !result.unverified)
        #expect(await session.readStatistics.readCount == 0)
        #expect(await session.c2Support == .unknown)
        #expect(await session.isOpen == false)
        #expect(disc.reads.isEmpty && disc.isClosed && !disc.usedMainThread)
        #expect(disc.speedRequests == (fails ? [176] : [176, 4_234]))
    }
}
