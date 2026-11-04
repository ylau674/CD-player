import CDKit
import Darwin
import Foundation

/// Developer-only: copies a stretch of one stereo audio track, read-only at the drive's minimum speed, into
/// a new 16-bit WAV file so that an external analyser such as FFmpeg's `hdcd` filter can inspect the disc's
/// unaltered samples. It never plays audio, and the file holds the disc's audio, so delete it after analysis.
struct PCMCaptureCommand: Equatable, Sendable {
    static let maximumSeconds = 600
    static let sectorsPerSecond: UInt64 = 75
    static let usage = "AudioCheck --capture-pcm <drive registry ID> <track> <start seconds> " +
        "<1...\(maximumSeconds) seconds> <new.wav>"

    let driveID: UInt64
    let trackNumber: Int
    let startSeconds: Int
    let seconds: Int
    let path: String

    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.contains("--capture-pcm") else { return nil }
        guard arguments.count == 6, arguments[0] == "--capture-pcm",
              let driveID = UInt64(arguments[1]),
              let track = Int(arguments[2]), (1...99).contains(track),
              let start = Int(arguments[3]), (0...(100 * 60)).contains(start),
              let seconds = Int(arguments[4]), (1...maximumSeconds).contains(seconds),
              !arguments[5].isEmpty, !arguments[5].hasPrefix("--") else {
            throw CheckError.failed(usage)
        }
        return Self(driveID: driveID, trackNumber: track, startSeconds: start, seconds: seconds, path: arguments[5])
    }

    /// The sectors to copy, clipped to the track's end; a start at or beyond the end is refused.
    static func sectorRange(
        trackStart: UInt64, trackSectors: UInt64, startSeconds: Int, seconds: Int
    ) throws -> Range<UInt64> {
        let offset = UInt64(startSeconds) * sectorsPerSecond
        guard offset < trackSectors else {
            throw CheckError.failed("The start is at or beyond the end of the track (\(trackSectors / 75) s).")
        }
        let count = min(UInt64(seconds) * sectorsPerSecond, trackSectors - offset)
        return (trackStart + offset)..<(trackStart + offset + count)
    }

    /// A canonical 44-byte header for 44.1 kHz, 16-bit, stereo PCM; CD-DA bytes are already little-endian.
    static func waveHeader(dataBytes: UInt32) -> Data {
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + dataBytes)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(2)
        append32(44_100)
        append32(44_100 * 4)
        append16(4)
        append16(16)
        append("data")
        append32(dataBytes)
        return header
    }

    @MainActor
    func run() async throws {
        let service = MacOpticalDriveService()
        var latest = OpticalSnapshot()
        try service.start { snapshot in latest = snapshot }
        defer { service.stop() }
        if let message = latest.errorMessage { throw OpticalDriveError(message) }
        guard let drive = latest.drives.first(where: { $0.id == driveID }) else {
            throw OpticalDriveError("No optical drive with registry ID \(driveID) is available.")
        }
        if let issue = drive.issue { throw OpticalDriveError("Drive \(driveID) is unavailable: \(issue)") }
        guard let media = drive.media, let table = media.contents.tableOfContents else {
            throw OpticalDriveError("Drive \(driveID) does not contain a readable audio CD.")
        }
        guard let track = table.audioTracks.first(where: { $0.number == trackNumber }) else {
            throw CheckError.failed("The disc has no audio track \(trackNumber).")
        }
        guard track.format == .compactDisc else {
            throw CheckError.failed("Track \(trackNumber) is not two-channel audio; only stereo tracks are captured.")
        }
        let range = try Self.sectorRange(
            trackStart: track.startSector, trackSectors: track.sectorCount,
            startSeconds: startSeconds, seconds: seconds
        )
        let dataBytes = UInt64(range.count) * UInt64(CDSectorBlock.audioBytes)
        let file = try await CaptureFile.create(path)
        var captureError: (any Error)?
        do {
            try await file.write(Self.waveHeader(dataBytes: UInt32(dataBytes)))
            let session = try await DiscSession.open(
                media, driveID: driveID, tableOfContents: table, opener: RawDiscOpener()
            )
            do {
                print("Drive \(drive.id): \(drive.name), media \(media.id); track \(track.number), " +
                      "pre-emphasis \(track.hasPreEmphasis); sectors \(range.lowerBound)..<\(range.upperBound).")
                try await capture(range, session: session, into: file)
            } catch {
                captureError = error
            }
            let report = await session.close()
            if report.speedChangeAttempted {
                if report.speedRestored, let restored = report.restoredSpeed {
                    print("PASS: original drive speed restored and verified at \(restored) kB/s.")
                } else {
                    let message = report.speedRestoreError ?? "The original drive speed was not restored."
                    print("FAIL: drive speed restoration could not be verified: \(message)")
                    if captureError == nil { captureError = CheckError.failed(message) }
                }
            } else {
                print("Drive speed unchanged; no restoration was needed.")
            }
        } catch {
            if captureError == nil { captureError = error }
        }
        if let captureError {
            do {
                try await file.discard()
            } catch {
                throw CheckError.failed("\(captureError.localizedDescription); cleanup failed: \(error.localizedDescription)")
            }
            throw captureError
        }
        try await file.finish()
        print("Wrote \(path): \(dataBytes) PCM bytes. It holds the disc's audio; delete it after analysis.")
    }

    @MainActor
    private func capture(_ range: Range<UInt64>, session: DiscSession, into file: CaptureFile) async throws {
        do {
            let original = try await session.speed()
            guard original > 0 else {
                throw CDReadError(.failed, "The drive reported an unknown speed; no speed change was made.")
            }
            try await session.setSpeed(RawCDReader.minimumSpeed)
            let reported = try await session.speed()
            print("Speed: original \(original) kB/s; requested \(RawCDReader.minimumSpeed) kB/s; " +
                  "reported \(reported) kB/s.")
        } catch let error as CDReadError where error.kind == .failed || error.kind == .mediaError {
            print("Speed request unavailable: \(error.message); reading at the drive's chosen speed.")
        }
        let usesC2 = try await session.probeC2(at: range.lowerBound).support == .supported
        var checksum = PCMChecksum.initialValue
        var flaggedSectors: UInt64 = 0
        var sector = range.lowerBound
        while sector < range.upperBound {
            let count = Int(min(UInt64(DiscCaptureLimits.sectorsPerRead), range.upperBound - sector))
            let block = try await session.read(from: sector, count: count, errorFlags: usesC2)
            guard block.sectorCount == count else {
                throw CheckError.failed("The drive returned \(block.sectorCount) of \(count) sectors at LBA \(sector).")
            }
            if let flags = block.errorFlags {
                for offset in stride(from: flags.startIndex, to: flags.endIndex, by: CDSectorBlock.errorFlagBytes)
                where flags[offset..<(offset + CDSectorBlock.errorFlagBytes)].contains(where: { $0 != 0 }) {
                    flaggedSectors += 1
                }
            }
            checksum = PCMChecksum.appending(block.audio, to: checksum)
            try await file.write(block.audio)
            sector += UInt64(count)
        }
        let statistics = await session.readStatistics
        let rate = statistics.kilobytesPerSecond.map { String(format: "%.1f kB/s", $0) } ?? "unmeasured"
        print("Read \(range.count) sectors (\(UInt64(range.count) * 588) frames); checksum " +
              "\(PCMChecksum.hexadecimal(checksum)); \(rate).")
        print(usesC2 ? "C2: \(flaggedSectors) sectors flagged." : "C2 unavailable: errors cannot be counted.")
    }
}

private enum DiscCaptureLimits {
    // The same per-read size the player's producer uses, inside the drive's 37-sector cap.
    static let sectorsPerRead = 33
}

/// A new file opened exclusively, so an existing file is never overwritten; file I/O stays off the main actor.
final class CaptureFile: Sendable {
    private static let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.pcm-capture", qos: .userInitiated)
    private let descriptor: Int32
    private let path: String

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    static func create(_ path: String) async throws -> CaptureFile {
        try await perform {
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw CheckError.failed("Cannot create \(path): \(String(cString: strerror(errno))).")
            }
            return CaptureFile(descriptor: descriptor, path: path)
        }
    }

    func write(_ data: Data) async throws {
        try await Self.perform {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(self.descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw CheckError.failed("Cannot write \(self.path): \(String(cString: strerror(errno))).")
                    }
                    guard written > 0 else {
                        throw CheckError.failed("Cannot write \(self.path): no progress.")
                    }
                    offset += written
                }
            }
        }
    }

    /// Close even when flushing fails; report a failed removal rather than claiming cleanup succeeded.
    func finish() async throws {
        try await Self.perform {
            let synced = fsync(self.descriptor) == 0
            let failure = errno
            let closed = Darwin.close(self.descriptor) == 0
            guard synced, closed else {
                let reason = String(cString: strerror(synced ? errno : failure))
                if unlink(self.path) != 0, errno != ENOENT {
                    let cleanup = String(cString: strerror(errno))
                    throw CheckError.failed("Cannot finish \(self.path): \(reason); cannot remove file: \(cleanup).")
                }
                throw CheckError.failed("Cannot finish \(self.path): \(reason); no capture file remains.")
            }
        }
    }

    func discard() async throws {
        try await Self.perform {
            var failures: [String] = []
            if Darwin.close(self.descriptor) != 0 {
                failures.append("close: \(String(cString: strerror(errno)))")
            }
            if unlink(self.path) != 0, errno != ENOENT {
                failures.append("remove: \(String(cString: strerror(errno)))")
            }
            if !failures.isEmpty {
                throw CheckError.failed("Cannot discard \(self.path): \(failures.joined(separator: "; ")).")
            }
        }
    }

    private static func perform<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            Self.queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
