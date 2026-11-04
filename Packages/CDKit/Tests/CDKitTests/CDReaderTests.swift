import CDAudioCore
import Darwin
import Foundation
import Testing
@testable import CDKit

func readError(_ body: () throws -> Void) -> CDReadError? {
    do {
        try body()
        return nil
    } catch {
        return error as? CDReadError
    }
}

@Test func onlyAWholeDiscNameIsEverOpened() {
    for name in ["", "disk", "disk4s1", "rdisk4", "../disk4", "disk4/../../etc/passwd", "/dev/disk4", "disk12345", "disk-1"] {
        let error = readError { _ = try RawCDReader(bsdName: name) }
        #expect(error?.kind == .failed, "\(name)")
        #expect(error?.message == "The optical disc identifier is invalid.", "\(name)")
    }
}

@Test func aMissingDiscIsReportedAsGone() {
    let error = readError { _ = try RawCDReader(bsdName: "disk9999") }
    #expect(error?.kind == .gone)
    #expect(error?.systemError == ENOENT)
}

@Test func systemErrorsMapToRefusedGoneOrUnreadable() {
    #expect(cd_disc_result_for_errno(EACCES) == CD_DISC_REFUSED)
    #expect(cd_disc_result_for_errno(EPERM) == CD_DISC_REFUSED)
    #expect(cd_disc_result_for_errno(ENOENT) == CD_DISC_GONE)
    #expect(cd_disc_result_for_errno(ENXIO) == CD_DISC_GONE)
    #expect(cd_disc_result_for_errno(ENODEV) == CD_DISC_GONE)
    #expect(cd_disc_result_for_errno(EIO) == CD_DISC_READ_ERROR)
    #expect(cd_disc_result_for_errno(EINVAL) == CD_DISC_FAILED)
    var error = CDError()
    error.code = Int32(CD_DISC_REFUSED.rawValue)
    #expect(CDReadError(error).kind == .refused)
    error.code = Int32(CD_DISC_READ_ERROR.rawValue)
    #expect(CDReadError(error).kind == .mediaError)
}

@Test func invalidRequestsAreRejectedBeforeReachingTheDrive() throws {
    var ends: [Int32] = [-1, -1]
    try #require(pipe(&ends) == 0)
    defer { ends.forEach { close($0) } }
    let invalid = Int32(CD_INVALID_ARGUMENT.rawValue)
    var buffer = [UInt8](repeating: 0, count: Int(CD_MAX_READ_SECTORS + 1) * Int(CD_SECTOR_BYTES + CD_ERROR_FLAG_BYTES))
    let capacity = buffer.count
    var error = CDError()
    #expect(cd_disc_read(-1, 0, 1, false, &buffer, capacity, &error) == invalid)
    #expect(cd_disc_read(ends[0], 0, 0, false, &buffer, capacity, &error) == invalid)
    #expect(cd_disc_read(ends[0], 0, CD_MAX_READ_SECTORS + 1, false, &buffer, capacity, &error) == invalid)
    #expect(cd_disc_read(ends[0], 0, 2, true, &buffer, Int(2 * CD_SECTOR_BYTES), &error) == invalid)
    #expect(cd_disc_read(ends[0], 0, 1, false, nil, capacity, &error) == invalid)
    #expect(cd_disc_read(ends[0], UInt64.max / 2_000, 1, false, &buffer, capacity, &error) == invalid)
    var length = 0
    #expect(cd_disc_read_toc(ends[0], &buffer, 3, &length, &error) == invalid)
    #expect(cd_disc_set_speed(-1, 176, &error) == invalid)
    #expect(error.message.0 != 0)
}

@Test func aDeviceThatIsNotADiscFailsWithoutBeingMistakenForRefusal() throws {
    var ends: [Int32] = [-1, -1]
    try #require(pipe(&ends) == 0)
    defer { ends.forEach { close($0) } }
    let failed = Int32(CD_DISC_FAILED.rawValue)
    var buffer = [UInt8](repeating: 0, count: Int(CD_TOC_CAPACITY))
    let capacity = buffer.count
    var error = CDError()
    #expect(cd_disc_read(ends[0], 0, 1, false, &buffer, capacity, &error) == failed)
    #expect(error.systemStatus == ENOTTY)
    #expect(CDReadError(error).message.hasPrefix("Cannot read audio sectors from the optical disc:"))
    var length = 0
    #expect(cd_disc_read_toc(ends[0], &buffer, capacity, &length, &error) == failed)
    var speed: UInt16 = 0
    #expect(cd_disc_get_speed(ends[0], &speed, &error) == failed)
    #expect(cd_disc_set_speed(ends[0], 176, &error) == failed)
}

@Test func errorFlagReadsSplitIntoAudioAndFlags() {
    var interleaved = Data()
    for sector in 0..<2 {
        interleaved.append(Data(repeating: UInt8(0x10 + sector), count: CDSectorBlock.audioBytes))
        interleaved.append(Data(repeating: UInt8(0x20 + sector), count: CDSectorBlock.errorFlagBytes))
    }
    let block = CDSectorBlock(firstSector: 40, interleaved: interleaved, sectorCount: 2)
    #expect(block.firstSector == 40)
    #expect(block.sectorCount == 2)
    #expect(block.audio == Data(repeating: 0x10, count: 2_352) + Data(repeating: 0x11, count: 2_352))
    #expect(block.errorFlags == Data(repeating: 0x20, count: 294) + Data(repeating: 0x21, count: 294))
}

private func fakeDisc() throws -> FakeCDSectorSource {
    try FakeCDSectorSource(tableOfContents: tocFixture())
}

@Test func fakeDiscReturnsFixedAudioCleanFlagsAndItsTrackTable() throws {
    let disc = try fakeDisc()
    let flagged = try disc.read(from: 10, count: 3, errorFlags: true)
    #expect(flagged.sectorCount == 3)
    #expect(flagged.audio == FakeCDSectorSource.audio(from: 10, count: 3))
    #expect(flagged.errorFlags == Data(count: 3 * CDSectorBlock.errorFlagBytes))
    #expect(try disc.read(from: 10, count: 3, errorFlags: false).errorFlags == nil)
    #expect(disc.reads == [.init(firstSector: 10, count: 3, errorFlags: true), .init(firstSector: 10, count: 3, errorFlags: false)])
    #expect(try CDTableOfContents(data: disc.readTableOfContents()).leadOutSector == 2_250)
    #expect(readError { _ = try disc.read(from: 2_249, count: 2, errorFlags: false) }?.kind == .failed)
    #expect(readError { _ = try disc.read(from: 0, count: 76, errorFlags: false) }?.kind == .failed)
}

@Test func fakeDiscScriptsTransientAndPersistentReadErrors() throws {
    let disc = try fakeDisc()
    let transient = CDReadError(.mediaError, "Read error.", systemError: EIO)
    disc.transientErrors[100] = [transient, transient]
    disc.unreadableSectors[200] = CDReadError(.mediaError, "Unreadable sector.", systemError: EIO)
    #expect(readError { _ = try disc.read(from: 99, count: 2, errorFlags: false) } == transient)
    #expect(readError { _ = try disc.read(from: 100, count: 1, errorFlags: false) } == transient)
    #expect(try disc.read(from: 99, count: 2, errorFlags: false).audio == FakeCDSectorSource.audio(from: 99, count: 2))
    for _ in 0..<3 {
        #expect(readError { _ = try disc.read(from: 195, count: 10, errorFlags: false) }?.message == "Unreadable sector.")
    }
}

@Test func fakeDiscDamagesFlaggedAndSilentlyPatchedBytes() throws {
    let disc = try fakeDisc()
    disc.flaggedBytes = [.init(sector: 51, offset: 9)]
    disc.silentlyDamagedBytes = [.init(sector: 52, offset: 0)]
    let block = try disc.read(from: 50, count: 3, errorFlags: true)
    let clean = FakeCDSectorSource.audio(from: 50, count: 3)
    let flagged = CDSectorBlock.audioBytes + 9
    let patched = 2 * CDSectorBlock.audioBytes
    #expect(block.audio[flagged] == clean[flagged] ^ 0x5A)
    #expect(block.audio[patched] == clean[patched] ^ 0x5A)
    let flags = try #require(block.errorFlags)
    #expect(flags[CDSectorBlock.errorFlagBytes + 1] == 0x40)
    #expect(flags.filter { $0 != 0 }.count == 1)
}

@Test func fakeDriveWithoutC2RejectsOnlyFlagRequests() throws {
    let disc = try fakeDisc()
    disc.supportsErrorFlags = false
    #expect(readError { _ = try disc.read(from: 0, count: 1, errorFlags: true) } == disc.errorFlagRejection)
    #expect(try disc.read(from: 0, count: 1, errorFlags: false).sectorCount == 1)
}

@Test func fakeDriveWithoutAccurateStreamShiftsReadStarts() throws {
    let disc = try fakeDisc()
    disc.readStartShifts = [3, -2]
    #expect(try disc.read(from: 20, count: 1, errorFlags: false).audio == FakeCDSectorSource.audio(from: 20, count: 1, shift: 3))
    #expect(try disc.read(from: 20, count: 1, errorFlags: false).audio == FakeCDSectorSource.audio(from: 20, count: 1, shift: -2))
    #expect(try disc.read(from: 20, count: 1, errorFlags: false).audio == FakeCDSectorSource.audio(from: 20, count: 1))
    #expect(FakeCDSectorSource.audio(from: 20, count: 1, shift: 3) != FakeCDSectorSource.audio(from: 20, count: 1))
}

@Test func fakeDiscDelaysIgnoresSpeedRequestsAndCanBeRemoved() throws {
    let disc = try fakeDisc()
    disc.delay = .milliseconds(30)
    let start = ContinuousClock.now
    _ = try disc.read(from: 0, count: 1, errorFlags: false)
    #expect(ContinuousClock.now - start >= .milliseconds(30))
    disc.delay = .zero
    disc.obeysSpeedRequests = false
    try disc.setSpeed(176)
    #expect(disc.speedRequests == [176])
    #expect(try disc.speed() == 4_234)
    disc.remove()
    #expect(readError { _ = try disc.read(from: 0, count: 1, errorFlags: false) }?.kind == .gone)
    #expect(readError { _ = try disc.readTableOfContents() }?.kind == .gone)
    disc.close()
    #expect(disc.isClosed)
}
