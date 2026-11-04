import CDAudioCore
import Foundation

/// Why a disc read failed. The display shows only a short message; `message` is for the log.
public struct CDReadError: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// macOS or a managed policy refused access. It is reported, never worked around.
        case refused
        /// The disc or the drive is no longer there.
        case gone
        /// The drive could not read the requested sectors.
        case mediaError
        /// Anything else, including a request the drive rejected.
        case failed
    }

    public let kind: Kind
    public let message: String
    /// The system error number, or 0.
    public let systemError: Int32

    public init(_ kind: Kind, _ message: String, systemError: Int32 = 0) {
        self.kind = kind
        self.message = message
        self.systemError = systemError
    }

    init(_ error: CDError) {
        let kind: Kind
        switch Int64(error.code) {
        case Int64(CD_DISC_REFUSED.rawValue): kind = .refused
        case Int64(CD_DISC_GONE.rawValue): kind = .gone
        case Int64(CD_DISC_READ_ERROR.rawValue): kind = .mediaError
        default: kind = .failed
        }
        self.init(kind, decodeCString(error.message), systemError: error.systemStatus)
    }

    public var errorDescription: String? { message }
}

/// Audio read from a CD: 2,352-byte sectors of 16-bit little-endian stereo PCM (588 frames each) and,
/// when requested, their C2 error flags: 294 bytes per sector, one bit per audio byte.
public struct CDSectorBlock: Equatable, Sendable {
    public static let audioBytes = Int(CD_SECTOR_BYTES)
    public static let errorFlagBytes = Int(CD_ERROR_FLAG_BYTES)

    public let firstSector: UInt64
    public let audio: Data
    public let errorFlags: Data?
    public var sectorCount: Int { audio.count / Self.audioBytes }

    public init(firstSector: UInt64, audio: Data, errorFlags: Data?) {
        self.firstSector = firstSector
        self.audio = audio
        self.errorFlags = errorFlags
    }

    /// Splits a read in which each sector's audio is followed by its error flags.
    init(firstSector: UInt64, interleaved: Data, sectorCount: Int) {
        let block = Self.audioBytes + Self.errorFlagBytes
        var audio = Data(capacity: sectorCount * Self.audioBytes)
        var flags = Data(capacity: sectorCount * Self.errorFlagBytes)
        for sector in 0..<sectorCount {
            let start = interleaved.startIndex + sector * block
            audio.append(interleaved[start ..< start + Self.audioBytes])
            flags.append(interleaved[start + Self.audioBytes ..< start + block])
        }
        self.init(firstSector: firstSector, audio: audio, errorFlags: flags)
    }
}

/// One audio CD's sectors. Calls block on the drive, so make them off the main thread.
public protocol CDSectorSource: AnyObject {
    var readFeatures: CDReadFeatures { get }
    /// The disc's full track table, in the same format as the registry's TOC property.
    func readTableOfContents() throws -> Data
    /// Reads 1-75 sectors (up to one second of audio), with C2 error flags if asked.
    func read(from firstSector: UInt64, count: Int, errorFlags: Bool) throws -> CDSectorBlock
    /// The drive's reported speed in kB/s; 176 is about 1×.
    func speed() throws -> UInt16
    /// Only a request: a drive may accept it and still read at another speed.
    func setSpeed(_ kilobytesPerSecond: UInt16) throws
    func close()
}

/// Reads an audio CD through its raw device, opened read-only as the logged-in user.
public final class RawCDReader: CDSectorSource {
    public static let maxSectorsPerRead = Int(CD_MAX_READ_SECTORS)
    public static let minimumSpeed = cd_disc_min_speed()
    public let readFeatures: CDReadFeatures
    private var descriptor: Int32 = -1

    /// Opens `/dev/r<bsdName>` for a whole disc such as "disk4".
    public init(bsdName: String, readFeatures: CDReadFeatures = CDReadFeatures()) throws {
        self.readFeatures = readFeatures
        var opened: Int32 = -1
        var error = CDError()
        guard cd_disc_open(bsdName, &opened, &error) == 0 else { throw CDReadError(error) }
        descriptor = opened
    }

    deinit { cd_disc_close(descriptor) }

    public func readTableOfContents() throws -> Data {
        try requireOpen()
        var buffer = [UInt8](repeating: 0, count: Int(CD_TOC_CAPACITY))
        let capacity = buffer.count
        var length = 0
        var error = CDError()
        guard cd_disc_read_toc(descriptor, &buffer, capacity, &length, &error) == 0 else {
            throw CDReadError(error)
        }
        return Data(buffer[..<length])
    }

    public func read(from firstSector: UInt64, count: Int, errorFlags: Bool) throws -> CDSectorBlock {
        try requireOpen()
        guard (1...Self.maxSectorsPerRead).contains(count) else {
            throw CDReadError(.failed, "A read must cover 1 to \(Self.maxSectorsPerRead) sectors.")
        }
        let block = CDSectorBlock.audioBytes + (errorFlags ? CDSectorBlock.errorFlagBytes : 0)
        var buffer = Data(count: count * block)
        var error = CDError()
        let status = buffer.withUnsafeMutableBytes { bytes in
            cd_disc_read(
                descriptor, firstSector, UInt32(count), errorFlags,
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &error
            )
        }
        guard status == 0 else { throw CDReadError(error) }
        return errorFlags
            ? CDSectorBlock(firstSector: firstSector, interleaved: buffer, sectorCount: count)
            : CDSectorBlock(firstSector: firstSector, audio: buffer, errorFlags: nil)
    }

    public func speed() throws -> UInt16 {
        try requireOpen()
        var value: UInt16 = 0
        var error = CDError()
        guard cd_disc_get_speed(descriptor, &value, &error) == 0 else { throw CDReadError(error) }
        return value
    }

    public func setSpeed(_ kilobytesPerSecond: UInt16) throws {
        try requireOpen()
        var error = CDError()
        guard cd_disc_set_speed(descriptor, kilobytesPerSecond, &error) == 0 else { throw CDReadError(error) }
    }

    public func close() {
        cd_disc_close(descriptor)
        descriptor = -1
    }

    private func requireOpen() throws {
        guard descriptor >= 0 else { throw CDReadError(.failed, "The optical disc is closed.") }
    }
}
