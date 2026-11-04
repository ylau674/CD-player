@testable import AudioCheck
import Foundation
import Testing

@Suite struct PCMCaptureTests {
    @Test func parsesTheCaptureCommandAndIgnoresOtherCommands() throws {
        #expect(try PCMCaptureCommand.parse(["--list-outputs"]) == nil)
        #expect(try PCMCaptureCommand.parse(["--capture-pcm", "4295303415", "3", "0", "30", "/tmp/t3.wav"]) ==
            PCMCaptureCommand(driveID: 4_295_303_415, trackNumber: 3, startSeconds: 0, seconds: 30, path: "/tmp/t3.wav"))
    }

    @Test(arguments: [
        ["--capture-pcm"],
        ["--capture-pcm", "1", "1", "0", "30"],
        ["--capture-pcm", "x", "1", "0", "30", "a.wav"],
        ["--capture-pcm", "1", "0", "0", "30", "a.wav"],
        ["--capture-pcm", "1", "100", "0", "30", "a.wav"],
        ["--capture-pcm", "1", "1", "-1", "30", "a.wav"],
        ["--capture-pcm", "1", "1", "0", "0", "a.wav"],
        ["--capture-pcm", "1", "1", "0", "601", "a.wav"],
        ["--capture-pcm", "1", "1", "0", "30", "--retry"],
        ["--capture-pcm", "1", "1", "0", "30", ""],
        ["--capture-pcm", "1", "1", "0", "30", "a.wav", "extra"],
        ["--disc", "1", "--capture-pcm", "1", "1", "0"]
    ])
    func rejectsMalformedCaptureCommands(_ arguments: [String]) {
        #expect(throws: CheckError.self) { try PCMCaptureCommand.parse(arguments) }
    }

    @Test func capturesSeventyFiveSectorsPerSecondFromTheRequestedOffset() throws {
        let range = try PCMCaptureCommand.sectorRange(
            trackStart: 1_000, trackSectors: 75 * 300, startSeconds: 10, seconds: 30
        )
        #expect(range == 1_750..<4_000)
    }

    @Test func clipsTheCaptureToTheTrackEnd() throws {
        let range = try PCMCaptureCommand.sectorRange(
            trackStart: 150, trackSectors: 75 * 40 + 20, startSeconds: 30, seconds: 600
        )
        let start: UInt64 = 150 + 75 * 30
        let end: UInt64 = 150 + 75 * 40 + 20
        #expect(range == start..<end)
    }

    @Test func refusesAStartAtOrBeyondTheTrackEnd() {
        #expect(throws: CheckError.self) {
            try PCMCaptureCommand.sectorRange(trackStart: 0, trackSectors: 75 * 20, startSeconds: 20, seconds: 1)
        }
        #expect(throws: CheckError.self) {
            try PCMCaptureCommand.sectorRange(trackStart: 0, trackSectors: 75 * 20, startSeconds: 21, seconds: 1)
        }
    }

    @Test func writesACanonicalCompactDiscWaveHeader() {
        let dataBytes: UInt32 = 75 * 2_352
        let header = PCMCaptureCommand.waveHeader(dataBytes: dataBytes)
        #expect(header.count == 44)
        func text(_ offset: Int) -> String { String(decoding: header[offset..<(offset + 4)], as: UTF8.self) }
        func value32(_ offset: Int) -> UInt32 {
            header[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        func value16(_ offset: Int) -> UInt16 { UInt16(header[offset]) | UInt16(header[offset + 1]) << 8 }
        #expect(text(0) == "RIFF" && value32(4) == 36 + dataBytes && text(8) == "WAVE")
        #expect(text(12) == "fmt " && value32(16) == 16 && value16(20) == 1 && value16(22) == 2)
        #expect(value32(24) == 44_100 && value32(28) == 176_400 && value16(32) == 4 && value16(34) == 16)
        #expect(text(36) == "data" && value32(40) == dataBytes)
    }

    @Test func captureFileWritesPrivateBytesWithoutOverwriting() async throws {
        let path = temporaryPath()
        defer { removeFixture(path) }
        let file = try await CaptureFile.create(path.path)
        await #expect(throws: CheckError.self) { try await CaptureFile.create(path.path) }
        let bytes = Data([0, 1, 2, 3])
        try await file.write(bytes)
        try await file.finish()
        #expect(try Data(contentsOf: path) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test func discardingCaptureRemovesPartialFile() async throws {
        let path = temporaryPath()
        defer { removeFixture(path) }
        let file = try await CaptureFile.create(path.path)
        try await file.write(Data([1, 2]))
        try await file.discard()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func failedCaptureRemovalIsReported() async throws {
        let path = temporaryPath()
        defer { removeFixture(path) }
        let file = try await CaptureFile.create(path.path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await #expect(throws: CheckError.self) { try await file.discard() }
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    private func temporaryPath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cdplayer-pcm-capture-\(UUID().uuidString)")
    }

    private func removeFixture(_ path: URL) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do { try FileManager.default.removeItem(at: path) }
        catch { Issue.record(error) }
    }
}
