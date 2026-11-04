import CDAudioCore
import Dispatch
import Foundation
import Testing

@testable import CDKit

private func recoveryDisc() -> Data {
    tocFixture([TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 1_000)])
}

private func readRecoveryPCM(
    _ source: DiscPCMSource, at frame: UInt64 = 0, frames: Int = 1,
    context: PCMReadContext = PCMReadContext()
) async throws -> PCMReadResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do { continuation.resume(returning: try source.read(at: frame, maxFrames: frames, context: context)) } catch
            { continuation.resume(throwing: error) }
        }
    }
}

private final class RecoveryHarness {
    let source: FakeCDSectorSource
    let recovery: DiscReadRecovery
    let disc: Disc
    var statistics = DiscReadStatistics()

    init(streamAccurate: Bool = true, cacheBound: Int? = 0, data: Data = recoveryDisc()) throws {
        source = try FakeCDSectorSource(tableOfContents: data)
        let flags: UInt32 = streamAccurate ? 0x10 : 0
        let features =
            cacheBound.map { CDReadFeatures(cdFeatures: flags, cacheCapacitySectors: $0) }
            ?? CDReadFeatures(cdFeatures: flags)
        source.readFeatures = features
        disc = Disc(tableOfContents: try CDTableOfContents(data: data))
        recovery = DiscReadRecovery(disc: disc, features: features)
    }

    func read(
        _ sector: UInt64, count: Int = 1,
        context: PCMReadContext = PCMReadContext(bufferedFrames: 661_500, buffering: false)
    ) throws -> PCMReadResult {
        let track = try #require(
            disc.tracks.first { sector >= $0.firstSector && sector < $0.firstSector + $0.sectorCount })
        return try recovery.read(
            from: sector, count: count, track: track, context: context,
            statistics: { self.statistics },
            rawRead: { sector, count, flags in
                var bytes = 0
                defer { self.statistics.record(audioBytes: bytes, duration: .milliseconds(2)) }
                let block = try self.source.read(from: sector, count: count, errorFlags: flags)
                bytes = block.audio.count
                return block
            }
        )
    }
}

@Suite(.serialized)
struct DiscReadRecoveryTests {
    @Test func streamAccuracyUsesTheSDKBitAndMissingOrInvalidMetadataIsConservative() {
        #expect(cd_disc_stream_accurate_mask() == 0x10)
        #expect(CDReadFeatures(cdFeatures: 2_047).streamAccurate)
        #expect(!CDReadFeatures(cdFeatures: 2_047 & ~0x10).streamAccurate)
        for metadata: [String: Any] in [
            [:], ["CD Features": true], ["CD Features": -1], ["CD Features": 4.5],
            ["CD Features": "2047"], ["CD Features": UInt64.max],
        ] {
            let features = CDReadFeatures.decode(deviceCharacteristics: metadata)
            #expect(features.cdFeatures == nil && !features.streamAccurate)
            #expect(features.cacheCapacitySectors == nil)
        }
        let features = CDReadFeatures.decode(deviceCharacteristics: ["CD Features": NSNumber(value: 2_047)])
        #expect(features.cdFeatures == 2_047 && features.streamAccurate)
        #expect(features.cacheCapacitySectors == nil)
        #expect(CDReadFeatures.decode(deviceCharacteristics: ["CD Features": 0]).cdFeatures == 0)
        #expect(CDReadFeatures.decode(deviceCharacteristics: ["CD Features": 16]).streamAccurate)
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], [0, 8, -1])
    func allDriveFeatureCombinationsPreserveCleanPCMWithoutInventingCacheCertainty(
        capabilities: (Bool, Bool), cache: Int
    ) throws {
        let (accurate, c2) = capabilities
        for policy in [DiscRetryPolicy.singlePass, .retry] {
            let harness = try RecoveryHarness(streamAccurate: accurate, cacheBound: cache < 0 ? nil : cache)
            harness.recovery.retryPolicy = policy
            harness.source.supportsErrorFlags = c2
            harness.source.audioCacheCapacity = max(0, cache)
            let first = try harness.read(10, count: 7)
            #expect(first.samples == pcmSamples(at: 10 * 588, count: 7 * 588))
            #expect(first.concealedSectors == 0)
            // Without C2, only a retry's matching re-read after a known cache bound can verify PCM.
            #expect(first.unverified == (!accurate || (!c2 && (policy == .singlePass || cache < 0))))
            let second = try harness.read(17, count: 7)
            #expect(second.samples == pcmSamples(at: 17 * 588, count: 7 * 588))
            #expect(second.concealedSectors == 0)
            #expect(harness.recovery.c2Support == (c2 ? .supported : .unsupported))
            #expect(harness.source.reads.filter { $0.errorFlags }.count == (c2 ? 2 : 1))
            #expect(harness.source.reads.allSatisfy { (1...37).contains($0.count) })
        }
    }

    @Test(arguments: [CDReadError.Kind.refused, .gone])
    func aC2AccessRefusalNeverTriggersAPlainReadOrRetry(_ kind: CDReadError.Kind) throws {
        let harness = try RecoveryHarness()
        harness.source.supportsErrorFlags = false
        let failure = CDReadError(kind, "The C2 read cannot proceed.", systemError: EPERM)
        harness.source.errorFlagRejection = failure
        #expect(throws: failure) { try harness.read(10) }
        #expect(harness.source.reads == [.init(firstSector: 10, count: 1, errorFlags: true)])
        #expect(harness.recovery.c2Support == .unknown)
    }

    @Test(arguments: [false, true], [DiscRetryPolicy.singlePass, .retry])
    func aFailedC2ProbeOnlyDisablesFlagsAfterTheIdenticalPlainReadSucceeds(
        plainSucceeds: Bool, policy: DiscRetryPolicy
    ) throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = policy
        harness.source.supportsErrorFlags = false
        if !plainSucceeds {
            harness.source.unreadableSectors[10] = CDReadError(
                .mediaError, "The plain read also failed.", systemError: EIO)
        }
        if !plainSucceeds && policy == .retry {
            #expect(throws: harness.source.errorFlagRejection) { try harness.read(10) }
            #expect(harness.recovery.c2Support == .unknown)
            #expect(harness.source.reads.count == 3)
            return
        }
        let result = try harness.read(10)
        #expect(
            Array(harness.source.reads.prefix(2)) == [
                .init(firstSector: 10, count: 1, errorFlags: true), .init(firstSector: 10, count: 1, errorFlags: false),
            ])
        if !plainSucceeds {
            // Single pass patches the unreadable sector instead of retrying into the C2 rejection.
            #expect(harness.recovery.c2Support == .unknown)
            #expect(result.concealedSectors == 1 && harness.source.reads.count == 2)
            return
        }
        #expect(harness.recovery.c2Support == .unsupported)
        // One read without C2 cannot be verified; a retry's independent matching read can.
        #expect(result.concealedSectors == 0 && result.unverified == (policy == .singlePass))
    }

    @Test func recheckingOneDiscDoesNotReuseAnotherDrivesC2OrStreamFeatures() async throws {
        let data = recoveryDisc()
        let table = try CDTableOfContents(data: data)
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let accurate = FakeDiscOpener(tableOfContents: data, readFeatures: CDReadFeatures(cdFeatures: 0x10))
        let unknown = FakeDiscOpener(tableOfContents: data, readFeatures: CDReadFeatures())
        let first = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: accurate)
        let second = try await DiscSession.open(media, driveID: 2, tableOfContents: table, opener: unknown)
        #expect(await first.readFeatures.streamAccurate)
        #expect(await second.readFeatures.cdFeatures == nil)
        #expect(await first.c2Support == .unknown)
        #expect(await second.c2Support == .unknown)
        #expect(accurate.discs.first?.reads.isEmpty == true && unknown.discs.first?.reads.isEmpty == true)
        accurate.discs.first?.supportsErrorFlags = false
        _ = try await readRecoveryPCM(DiscPCMSource(session: first))
        #expect(await first.c2Support == .unsupported)
        #expect(await second.c2Support == .unknown)
        _ = try await readRecoveryPCM(DiscPCMSource(session: second))
        #expect(await second.c2Support == .supported)
        #expect(await first.c2Support == .unsupported)
        await first.close()
        await second.close()
    }

    @Test(arguments: [DiscRetryPolicy.singlePass, .retry])
    func aTransientReadErrorNeedsMatchingCleanRecoveryAndDoesNotChangeThePCM(policy: DiscRetryPolicy) throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = policy
        harness.source.transientErrors[10] = [
            CDReadError(.mediaError, "The first read failed."),
            CDReadError(.mediaError, "The plain probe also failed."),
        ]
        let result = try harness.read(10, count: 2)
        #expect(result.samples == pcmSamples(at: 10 * 588, count: 2 * 588))
        #expect(result.concealedSectors == 0 && !result.unverified)
        // Single pass recovers through the failed block's single-sector reads, not retries.
        #expect(harness.source.reads.filter { $0.firstSector == 10 }.count >= (policy == .retry ? 4 : 3))
        if policy == .singlePass {
            #expect(harness.source.reads.suffix(2).map(\.firstSector) == [10, 11])
        }
    }

    @Test func cacheDisplacementActuallyExposesAStaleSilentErrorInsteadOfTrustingCachedMatches() throws {
        let harness = try RecoveryHarness(cacheBound: 8)
        harness.recovery.retryPolicy = .retry
        harness.source.supportsErrorFlags = false
        harness.source.audioCacheCapacity = 8
        let clean = FakeCDSectorSource.audio(from: 10, count: 1)
        var damaged = clean
        damaged[123] ^= 0x7F
        harness.source.uncachedAudioVersions[10] = [damaged, clean, clean]
        let result = try harness.read(10)
        #expect(result.samples == pcmSamples(at: 10 * 588, count: 588))
        #expect(result.concealedSectors == 0 && !result.unverified)
        let targetIndices = harness.source.reads.indices.filter {
            harness.source.reads[$0].firstSector == 10 && !harness.source.reads[$0].errorFlags
        }
        #expect(targetIndices.count == 3)
        for (first, next) in zip(targetIndices, targetIndices.dropFirst()) {
            let between = harness.source.reads[(first + 1)..<next]
            #expect(between.reduce(0) { $0 + $1.count } > 8)
            #expect(between.allSatisfy { $0.firstSector > 10 || $0.firstSector + UInt64($0.count) <= 10 })
        }
    }

    @Test(arguments: [-1, 200])
    func unknownCacheOrInsufficientDisplacementRemainsUnverifiedEvenWhenCachedDamageMatches(_ bound: Int) throws {
        let harness = try RecoveryHarness(cacheBound: bound < 0 ? nil : bound)
        harness.recovery.retryPolicy = .retry
        harness.source.supportsErrorFlags = false
        harness.source.audioCacheCapacity = 500
        let clean = FakeCDSectorSource.audio(from: 10, count: 1)
        var damaged = clean
        damaged[123] ^= 0x7F
        harness.source.uncachedAudioVersions[10] = [damaged, clean]
        let result = try harness.read(10)
        #expect(result.samples != pcmSamples(at: 10 * 588, count: 588))
        #expect(result.unverified && result.concealedSectors == 0)
        #expect(harness.source.reads.contains { $0.firstSector != 10 })
    }

    @Test func startupAndInsufficientHeadroomSkipOptionalDoubleReadsButStayUnverified() throws {
        for context in [
            PCMReadContext(),
            PCMReadContext(bufferedFrames: 88_200, buffering: false),
        ] {
            let harness = try RecoveryHarness()
            harness.source.supportsErrorFlags = false
            let result = try harness.read(10, context: context)
            #expect(result.samples == pcmSamples(at: 10 * 588, count: 588))
            #expect(result.unverified && result.concealedSectors == 0)
            #expect(harness.source.reads.count == 2)
        }
    }

    @Test func optionalVerificationRequiresMeasuredThroughputAndFitsTheActualHeadroom() {
        let context = PCMReadContext(bufferedFrames: 3 * 44_100, buffering: false)
        let budget = ReadRecoveryBudget(context: context)
        #expect(!budget.allows(sectors: 37, statistics: DiscReadStatistics(), optional: true))
        var slow = DiscReadStatistics()
        slow.record(audioBytes: 2_352, duration: .seconds(1))
        #expect(!budget.allows(sectors: 37, statistics: slow, optional: true))
        var failedOnly = DiscReadStatistics()
        failedOnly.record(audioBytes: 0, duration: .milliseconds(10))
        #expect(!budget.allows(sectors: 1, statistics: failedOnly, optional: true))
        #expect(budget.allows(sectors: 1, statistics: failedOnly, optional: false))
        var fast = DiscReadStatistics()
        fast.record(audioBytes: 2_352 * 75, duration: .milliseconds(100))
        #expect(budget.allows(sectors: 37, statistics: fast, optional: true))
        var capped = budget
        capped.operations = 96
        #expect(!capped.allows(sectors: 1, statistics: fast, optional: false))
        #expect(!capped.permitsRead(negotiatingC2: true))
        var expired = ReadRecoveryBudget(context: context, started: .now.advanced(by: .seconds(-3)))
        expired.operations = 1
        #expect(!expired.allows(sectors: 1, statistics: fast, optional: false))
        #expect(!expired.permitsRead(negotiatingC2: true))
    }

    @Test(arguments: [false, true])
    func persistentC2FlagsInterpolateOnlyTheAffectedChannelSamplesAndCountOneSector(twoBytes: Bool) throws {
        let harness = try RecoveryHarness()
        let flagged = FakeCDSectorSource.AudioByte(sector: 10, offset: 100 * 4)
        harness.source.flaggedBytes = [flagged]
        if twoBytes { harness.source.flaggedBytes.insert(.init(sector: 10, offset: 100 * 4 + 1)) }
        let result = try harness.read(10)
        let clean = pcmSamples(at: 10 * 588, count: 588)
        #expect(result.samples == clean)
        #expect(result.concealedSectors == 1)
        #expect(try harness.read(10).concealedSectors == 0)
        let restart = try harness.read(
            10, context: PCMReadContext(bufferedFrames: 661_500, buffering: false, beginsPlayback: true))
        #expect(restart.concealedSectors == 1)
        #expect(harness.source.reads.filter { $0.firstSector == 10 }.count <= 8)
    }

    @Test func C2FlagsThatClearOnlyCountAsRecoveredAfterTwoMatchingCleanReads() throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = .retry
        let clean = FakeCDSectorSource.audio(from: 10, count: 1)
        var damaged = clean
        damaged[400] ^= 0x55
        var flags = Data(count: 294)
        flags[400 / 8] = 0x80 >> UInt8(400 % 8)
        harness.source.readBlocks = [CDSectorBlock(firstSector: 10, audio: damaged, errorFlags: flags)]
        let result = try harness.read(10)
        #expect(result.samples == pcmSamples(at: 10 * 588, count: 588))
        #expect(result.concealedSectors == 0 && !result.unverified)
        #expect(harness.source.reads.filter { $0.firstSector == 10 }.count == 3)
        #expect(harness.recovery.sectorsClearedByRetry == 1)
    }

    @Test(arguments: [DiscRetryPolicy.retry, .singlePass], [false, true])
    func flaggedBlocksAreRetriedOnlyWithSpareBufferTimeOtherwiseReadOnceAndInterpolated(
        policy: DiscRetryPolicy, buffering: Bool
    ) throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = policy
        let clean = FakeCDSectorSource.audio(from: 10, count: 1)
        var damaged = clean
        damaged[400] ^= 0x55
        var flags = Data(count: 294)
        flags[400 / 8] = 0x80 >> UInt8(400 % 8)
        harness.source.readBlocks = [CDSectorBlock(firstSector: 10, audio: damaged, errorFlags: flags)]
        let context = buffering ? PCMReadContext() : PCMReadContext(bufferedFrames: 661_500, buffering: false)
        let result = try harness.read(10, context: context)
        let retried = policy == .retry && !buffering
        // Clean PCM either way: a retry recovers the sample, or interpolation rebuilds the ramp.
        #expect(result.samples == pcmSamples(at: 10 * 588, count: 588))
        #expect(!result.unverified)
        #expect(result.concealedSectors == (retried ? 0 : 1))
        #expect(harness.source.reads.count == (retried ? 3 : 1))
        #expect(harness.recovery.sectorsClearedByRetry == (retried ? 1 : 0))
    }

    @Test(arguments: [DiscRetryPolicy.retry, .singlePass])
    func aFailedBlockStillSplitsIntoSingleReadsWhileBufferingWithoutRetries(policy: DiscRetryPolicy) throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = policy
        harness.source.unreadableSectors[11] = CDReadError(
            .mediaError, "The middle sector cannot be read.", systemError: EIO)
        let result = try harness.read(10, count: 3, context: PCMReadContext())
        let expected =
            pcmSamples(at: 10 * 588, count: 588) + [Int16](repeating: 0, count: 1_176)
            + pcmSamples(at: 12 * 588, count: 588)
        #expect(result.samples == expected)
        #expect(result.concealedSectors == 1)
        #expect(harness.source.reads.filter { $0.firstSector == 11 }.count == 1)
        #expect(harness.source.reads.filter { $0.count == 1 }.map(\.firstSector) == [10, 11, 12])
    }

    @Test func aSessionReadsFlaggedBlocksOnceByDefaultAndRetriesOnlyWhenAskedTo() async throws {
        let data = recoveryDisc()
        let table = try CDTableOfContents(data: data)
        let opener = FakeDiscOpener(tableOfContents: data, readFeatures: CDReadFeatures(cdFeatures: 0x10))
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
        let disc = try #require(opener.discs.first)
        disc.flaggedBytes = [.init(sector: 0, offset: 400)]
        let spareTime = PCMReadContext(bufferedFrames: 661_500, buffering: false)
        #expect(await session.retryPolicy == .singlePass)
        let result = try await readRecoveryPCM(DiscPCMSource(session: session), at: 100, context: spareTime)
        #expect(result.samples == pcmSamples(at: 100, count: 1) && result.concealedSectors == 1)
        #expect(disc.reads.count == 1)

        await session.setRetryPolicy(.retry)
        #expect(await session.retryPolicy == .retry)
        _ = try await readRecoveryPCM(
            DiscPCMSource(session: session), at: 100,
            context: PCMReadContext(bufferedFrames: 661_500, buffering: false, beginsPlayback: true))
        #expect(disc.reads.count > 2)
        #expect(await session.sectorsClearedByRetry == 0)
        await session.close()
    }

    @Test func unreadableSectorsBecomeSilenceWithoutChangingReadableNeighbours() throws {
        let harness = try RecoveryHarness()
        harness.source.unreadableSectors[11] = CDReadError(
            .mediaError, "The middle sector cannot be read.", systemError: EIO)
        let result = try harness.read(10, count: 3)
        let expected =
            pcmSamples(at: 10 * 588, count: 588) + [Int16](repeating: 0, count: 1_176)
            + pcmSamples(at: 12 * 588, count: 588)
        #expect(result.samples == expected)
        #expect(result.concealedSectors == 1)
        #expect(harness.source.reads.count <= 96)
    }

    @Test(arguments: [-7, 9])
    func nonStreamAccurateReadsAlignTheirOverlapWithoutAddingOrLosingFrames(_ shift: Int) throws {
        let harness = try RecoveryHarness(streamAccurate: false)
        let first = try harness.read(10, count: 7)
        harness.source.readStartShifts = [shift]
        let second = try harness.read(17, count: 7)
        #expect(first.samples + second.samples == pcmSamples(at: 10 * 588, count: 14 * 588))
        #expect(first.unverified && second.concealedSectors == 0)
        #expect(harness.source.reads.last == .init(firstSector: 15, count: 10, errorFlags: true))
    }

    @Test(arguments: [DiscRetryPolicy.singlePass, .retry])
    func aClaimedStreamAccurateDriveStillHasItsOverlapsChecked(policy: DiscRetryPolicy) throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = policy
        _ = try harness.read(10, count: 7)
        harness.source.readStartShifts = [5, 0, 0]
        let result = try harness.read(17, count: 7)
        #expect(result.samples == pcmSamples(at: 17 * 588, count: 7 * 588))
        #expect(result.concealedSectors == 0)
        // Single pass treats the misaligned block as failed and reads its sectors one at a time.
        #expect(harness.source.reads.count == (policy == .retry ? 4 : 9))
    }

    @Test func persistentUnalignableReadsAreConcealedRatherThanEmittingShiftedPCM() throws {
        let harness = try RecoveryHarness(streamAccurate: false)
        _ = try harness.read(10, count: 7)
        harness.source.readStartShifts = [Int](repeating: 800, count: 30)
        let result = try harness.read(17)
        #expect(result.samples.allSatisfy { $0 == 0 })
        #expect(result.concealedSectors == 1)
    }

    @Test func aNonAccurateDriveCannotClaimAnAbsoluteAnchorAtStartupOrAfterASeek() throws {
        let harness = try RecoveryHarness(streamAccurate: false)
        #expect(try harness.read(10).unverified)
        #expect(try harness.read(11).unverified == false)
        let seek = try harness.read(50)
        #expect(seek.unverified && seek.concealedSectors == 0)
        #expect(seek.samples == pcmSamples(at: 50 * 588, count: 588))
    }

    @Test func displacementNeverReadsDataTracksGapsOrTheTargetWindow() throws {
        let data = tocFixture([
            TOCSessionFixture(
                tracks: [
                    TOCTrackFixture(number: 1, sector: 0, control: 4),
                    TOCTrackFixture(number: 2, sector: 100), TOCTrackFixture(number: 3, sector: 150, control: 4),
                ], leadOut: 200),
            TOCSessionFixture(number: 2, tracks: [TOCTrackFixture(number: 4, sector: 300)], leadOut: 350),
        ])
        let harness = try RecoveryHarness(cacheBound: nil, data: data)
        let target: Range<UInt64> = 100..<110
        let ranges = harness.recovery.displacementRanges(excluding: target)
        #expect(ranges.reduce(0) { $0 + $1.count } == 74)
        for range in ranges {
            #expect(!range.overlaps(target) && range.count <= 37)
            #expect(
                harness.disc.tracks.contains {
                    range.lowerBound >= $0.firstSector && range.upperBound <= $0.firstSector + $0.sectorCount
                })
        }
    }

    @Test func interpolationNeverMixesChannelsAndLeavesAllUnflaggedSamplesUnchanged() {
        var samples: [Int16] = [100, -100, 999, 999, 999, -300, 400, -400]
        let mask = [false, false, true, true, true, false, false, false]
        DiscReadRecovery.interpolate(&samples, suspect: mask, preceding: nil)
        #expect(samples == [100, -100, 200, -200, 300, -300, 400, -400])
        var extremes: [Int16] = [.min, .max, 0, 0, .max, .min]
        DiscReadRecovery.interpolate(&extremes, suspect: [false, false, true, true, false, false], preceding: nil)
        #expect(extremes == [.min, .max, -1, 0, .max, .min])
    }

    @Test(arguments: [0, 1, 2, 3, 7, 8, 2_350, 2_351])
    func eachC2ByteBitMapsToTheCorrectLittleEndianChannelSample(_ offset: Int) throws {
        let harness = try RecoveryHarness()
        harness.source.flaggedBytes = [.init(sector: 10, offset: offset)]
        var expected = pcmSamples(at: 10 * 588, count: 588)
        let sample = offset / 2
        if sample < 2 {
            expected[sample] = expected[sample + 2]
        } else if sample + 2 >= expected.count {
            expected[sample] = expected[sample - 2]
        } else {
            let left = Int64(expected[sample - 2])
            expected[sample] = Int16(left + (Int64(expected[sample + 2]) - left) / 2)
        }
        let result = try harness.read(10)
        #expect(result.samples == expected && result.concealedSectors == 1)
    }

    @Test func silentMismatchesConcealOnlyDisputedSamplesInsteadOfTrustingOneRead() throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = .retry
        harness.source.supportsErrorFlags = false
        let clean = FakeCDSectorSource.audio(from: 10, count: 1)
        harness.source.uncachedAudioVersions[10] = (1...4).map {
            var damaged = clean
            damaged[400] ^= UInt8($0)
            return damaged
        }
        let result = try harness.read(10)
        #expect(result.samples == pcmSamples(at: 10 * 588, count: 588))
        #expect(result.concealedSectors == 1 && result.unverified)
        #expect(harness.source.reads.filter { $0.firstSector == 10 && !$0.errorFlags }.count == 4)
    }

    @Test(arguments: [false, true])
    func silentOverlapsNeverResolveAnAmbiguousOffsetUnlessAllPossibleOutputsAreIdentical(ambiguous: Bool) throws {
        let harness = try RecoveryHarness(streamAccurate: false)
        let initial = CDSectorBlock(firstSector: 10, audio: Data(count: 2 * 2_352), errorFlags: Data(count: 2 * 294))
        var next = Data(count: 4 * 2_352)
        if ambiguous { next[2 * 2_352] = 42 }
        let block = CDSectorBlock(firstSector: 9, audio: next, errorFlags: Data(count: 4 * 294))
        harness.source.readBlocks = [initial] + Array(repeating: block, count: 4)
        #expect(try harness.read(10).samples.allSatisfy { $0 == 0 })
        let result = try harness.read(11)
        #expect(result.samples.allSatisfy { $0 == 0 })
        #expect(result.concealedSectors == (ambiguous ? 1 : 0))
        if !ambiguous { #expect(result.unverified) }
    }

    @Test func exhaustedRecoveryStopsAtExactlyNinetySixRawOperationsIncludingTheProbe() throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = .retry
        for sector in UInt64(0)..<33 {
            harness.source.unreadableSectors[sector] = CDReadError(.mediaError, "No readable audio.")
        }
        let result = try harness.read(0, count: 33)
        #expect(result.samples.count == 33 * 1_176 && result.samples.allSatisfy { $0 == 0 })
        #expect(result.concealedSectors == 33)
        #expect(harness.source.reads.count == ReadRecoveryBudget.maximumOperations)
    }

    @Test func oneCleanRetryBeforeBudgetExhaustionOnlyConcealsTheOriginallyFlaggedSamples() throws {
        let harness = try RecoveryHarness()
        harness.recovery.retryPolicy = .retry
        for sector in UInt64(0)..<22 {
            harness.source.unreadableSectors[sector] = CDReadError(.mediaError, "No readable audio.")
        }
        let clean22 = FakeCDSectorSource.audio(from: 22, count: 1)
        let clean23 = FakeCDSectorSource.audio(from: 23, count: 1)
        var damaged = clean23
        damaged[400] ^= 0x55
        var flags = Data(count: 294)
        flags[400 / 8] = 0x80 >> UInt8(400 % 8)
        harness.source.readBlocks = [
            CDSectorBlock(firstSector: 22, audio: clean22, errorFlags: Data(count: 294)),
            CDSectorBlock(firstSector: 23, audio: damaged, errorFlags: flags),
            CDSectorBlock(firstSector: 23, audio: clean23, errorFlags: Data(count: 294)),
        ]
        let result = try harness.read(0, count: 33)
        #expect(Array(result.samples[22 * 1_176..<24 * 1_176]) == pcmSamples(at: 22 * 588, count: 2 * 588))
        #expect(result.concealedSectors == 32)
        #expect(harness.source.reads.count == ReadRecoveryBudget.maximumOperations)
        #expect(harness.source.reads.last?.firstSector == 23)
    }

    @Test func invalidRecoveryRequestsFailBeforeUnsignedArithmeticOrDriveAccess() throws {
        let harness = try RecoveryHarness()
        let track = try #require(harness.disc.tracks.first)
        for (sector, count): (UInt64, Int) in [(0, -1), (0, 0), (0, 34), (UInt64.max, 1), (999, 2)] {
            #expect(throws: CDReadError.self) {
                try harness.recovery.read(
                    from: sector, count: count, track: track, context: PCMReadContext(),
                    statistics: { harness.statistics }, rawRead: harness.source.read
                )
            }
        }
        #expect(harness.source.reads.isEmpty)
    }

    @Test func partialSectorReadsCountConcealmentOnceAndClosedSessionsCannotServeCachedPCM() async throws {
        let data = recoveryDisc()
        let table = try CDTableOfContents(data: data)
        let opener = FakeDiscOpener(tableOfContents: data)
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
        let disc = try #require(opener.discs.first)
        disc.flaggedBytes = [.init(sector: 0, offset: 400)]
        let adapter = DiscPCMSource(session: session)
        let first = try await readRecoveryPCM(adapter, at: 100)
        let next = try await readRecoveryPCM(adapter, at: 101)
        #expect(first.samples == pcmSamples(at: 100, count: 1) && first.concealedSectors == 1)
        #expect(next.samples == pcmSamples(at: 101, count: 1) && next.concealedSectors == 0)
        let reads = disc.reads.count
        await session.close()
        do {
            _ = try await readRecoveryPCM(adapter, at: 101)
            Issue.record("A closed session must not return cached PCM.")
        } catch let error as CDReadError {
            #expect(error.kind == .failed && error.message == "The disc session is closed.")
        }
        #expect(disc.reads.count == reads)
    }

    @Test @MainActor func concealedCountsAndUnverifiedStateCrossTheProducerAndResetOnRestart() async throws {
        let data = tocFixture([TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 2)])
        let table = try CDTableOfContents(data: data)
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let opener = FakeDiscOpener(tableOfContents: data, readFeatures: CDReadFeatures(cdFeatures: 0x10))
        let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
        let source = try #require(opener.discs.first)
        source.supportsErrorFlags = false
        let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
        try playback.prepare()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 1_176 }
        #expect(try playbackSnapshot(playback.pointer).unverified)
        #expect(try playbackSnapshot(playback.pointer).concealedSectors == 0)
        _ = try await playback.stop()
        // A restart forgets read-ahead and its quality counters, but retains the session's C2 probe.
        source.unreadableSectors[0] = CDReadError(.mediaError, "The restarted first sector cannot be read.")
        try playback.prepare()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 1_176 }
        let snapshot = try playbackSnapshot(playback.pointer)
        #expect(snapshot.concealedSectors == 1 && snapshot.unverified)
        #expect(source.reads.filter { $0.errorFlags }.count == 1)
        cd_playback_enable_output(playback.pointer)
        let output = renderPlayback(playback.pointer, frames: 1_176)
        #expect(output.prefix(1_176).allSatisfy { $0 == 0 })
        #expect(Array(output.suffix(1_176)) == pcmSamples(at: 588, count: 588).map { Float($0) / 32_768 })
        _ = try await playback.stop()
        await session.close()
    }

    @Test(arguments: [false, true])
    @MainActor func cancellationDuringCacheDisplacementNeverRetriesOrCommitsLateQuality(fails: Bool) async throws {
        let data = recoveryDisc()
        let table = try CDTableOfContents(data: data)
        let opener = FakeDiscOpener(tableOfContents: data)
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
        await session.setRetryPolicy(.retry)
        let disc = try #require(opener.discs.first)
        // Retries need spare buffer time: sector 225 is the first read after a full 3-second ring.
        disc.flaggedBytes = [.init(sector: 225, offset: 400)]
        if fails { disc.unreadableSectors[999] = CDReadError(.mediaError, "The cancelled displacement failed.") }
        let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session), bufferFrames: 132_300)
        let gate = TestGate()
        defer { gate.release() }
        try playback.prepare()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 132_300 }
        // The next read is sector 225's flagged first read; the one after it is the first displacement.
        let reads = disc.reads.count
        disc.readNumberGates[reads + 2] = gate
        cd_playback_enable_output(playback.pointer)
        _ = renderPlayback(playback.pointer, frames: 4_096)
        try await waitUntil { gate.hasEntered }
        cd_playback_request_stop(playback.pointer)
        let stopping = Task { try await playback.stop() }
        let closing = Task { await session.close() }
        #expect(renderPlayback(playback.pointer, frames: 128).allSatisfy { $0 == 0 })
        gate.release()
        let snapshot = try await stopping.value
        _ = await closing.value
        #expect(snapshot.currentFrame == 4_096)
        #expect(snapshot.concealedSectors == 0 && !snapshot.unverified)
        #expect(disc.reads.count == reads + 2 && disc.isClosed)
    }

    @Test @MainActor func aNewRunClearsLatchedUnverifiedQualityAfterRecoveryBecomesClean() async throws {
        let data = recoveryDisc()
        let table = try CDTableOfContents(data: data)
        let opener = FakeDiscOpener(tableOfContents: data)
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
        await session.setRetryPolicy(.retry)
        let disc = try #require(opener.discs.first)
        // As above, the failure is placed where retries have spare buffer time.
        disc.transientErrors[225] = [CDReadError(.mediaError, "The first steady-state read failed.")]
        let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session), bufferFrames: 132_300)
        try playback.prepare()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 132_300 }
        #expect(try !playbackSnapshot(playback.pointer).unverified)
        cd_playback_enable_output(playback.pointer)
        _ = renderPlayback(playback.pointer, frames: 4_096)
        try await waitUntil {
            let snapshot = try playbackSnapshot(playback.pointer)
            return snapshot.bufferedFrames == 132_300 && snapshot.unverified
        }
        #expect(try playbackSnapshot(playback.pointer).concealedSectors == 0)
        _ = try await playback.stop()
        try playback.prepare()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 132_300 }
        let snapshot = try playbackSnapshot(playback.pointer)
        #expect(!snapshot.unverified && snapshot.concealedSectors == 0)
        #expect(await session.c2Support == .supported)
        _ = try await playback.stop()
        await session.close()
    }

    @Test @MainActor func aFirstFailedProducerReadStillRecoversReadableSectorsWithNoThroughputHistory() async throws {
        let data = tocFixture([TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 3)])
        let table = try CDTableOfContents(data: data)
        let opener = FakeDiscOpener(tableOfContents: data)
        let media = OpticalMedia(
            id: 1, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true)
        let session = try await DiscSession.open(media, driveID: 1, tableOfContents: table, opener: opener)
        let disc = try #require(opener.discs.first)
        disc.unreadableSectors[1] = CDReadError(.mediaError, "The middle sector is unreadable.")
        let playback = try OfflinePCMPlayback(source: DiscPCMSource(session: session))
        try playback.prepare()
        try await waitUntil { try playbackSnapshot(playback.pointer).bufferedFrames == 1_764 }
        #expect(try playbackSnapshot(playback.pointer).concealedSectors == 1)
        cd_playback_enable_output(playback.pointer)
        let output = renderPlayback(playback.pointer, frames: 1_764)
        let expected =
            pcmSamples(at: 0, count: 588).map { Float($0) / 32_768 } + [Float](repeating: 0, count: 1_176)
            + pcmSamples(at: 1_176, count: 588).map { Float($0) / 32_768 }
        #expect(output == expected)
        _ = try await playback.stop()
        await session.close()
    }

}
