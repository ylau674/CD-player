import Foundation
import Testing
@testable import CDKit

final class TestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func wait() throws {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        let deadline = Date().addingTimeInterval(10)
        while !released {
            guard condition.wait(until: deadline) else {
                throw CDReadError(.failed, "The offline test gate timed out.")
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A scripted audio CD for offline tests of everything built on `CDSectorSource`. Clean audio is a fixed
/// function of the absolute disc frame, so shifted or damaged reads can be detected exactly.
/// Tests hand it to a disc session's queue and only touch it while that session is idle.
final class FakeCDSectorSource: CDSectorSource, @unchecked Sendable {
    enum Operation: Equatable {
        case tableOfContents, read, speed, setSpeed(UInt16), close
    }

    struct Read: Equatable {
        let firstSector: UInt64
        let count: Int
        let errorFlags: Bool
    }

    /// One audio byte, by sector and offset within the sector (0-2351).
    struct AudioByte: Hashable {
        let sector: UInt64
        let offset: Int
    }

    let tableOfContents: Data
    let sectorCount: UInt64
    var readFeatures = CDReadFeatures(cdFeatures: 0x10)
    var audioCacheCapacity = 0
    var uncachedAudioVersions: [UInt64: [Data]] = [:]
    private var audioCache: [UInt64: Data] = [:]
    private var cacheOrder: [UInt64] = []
    /// Added to every call, like a slow or spinning-up drive.
    var delay: Duration = .zero
    var readGate: TestGate?
    var readNumberGates: [Int: TestGate] = [:]
    var closeGate: TestGate?
    /// Exact scripted replies, including malformed blocks to test consumers' validation.
    var readBlocks: [CDSectorBlock] = []
    /// Errors thrown in turn by reads that include the sector; afterwards it reads cleanly.
    var transientErrors: [UInt64: [CDReadError]] = [:]
    /// Sectors that can never be read.
    var unreadableSectors: [UInt64: CDReadError] = [:]
    /// Bytes returned damaged and flagged with C2.
    var flaggedBytes: Set<AudioByte> = []
    /// Bytes returned damaged without a flag, as a drive that patches bad data might.
    var silentlyDamagedBytes: Set<AudioByte> = []
    /// False for a drive without C2 support: reads that ask for error flags fail.
    var supportsErrorFlags = true
    var errorFlagRejection = CDReadError(.failed, "The drive rejected the C2 error-flag request.", systemError: EINVAL)
    /// Frame offsets for successive reads' starts, as on drives without stream-accurate reads.
    var readStartShifts: [Int] = []
    /// 24×, as the Pioneer reports.
    var reportedSpeed: UInt16 = 4_234
    var obeysSpeedRequests = true
    var speedReadReplies: [Result<UInt16, CDReadError>] = []
    var speedSetFailures: [CDReadError?] = []
    var speedSetGate: TestGate?
    private(set) var reads: [Read] = []
    private(set) var speedRequests: [UInt16] = []
    private(set) var isRemoved = false
    /// Locked, because tests may poll it while a session's queue closes the disc.
    var isClosed: Bool { closedLock.withLock { closed } }
    private let closedLock = NSLock()
    private var closed = false
    private let operationLock = NSLock()
    private var recordedOperations: [(Operation, Bool)] = []
    var operations: [Operation] { operationLock.withLock { recordedOperations.map(\.0) } }
    var usedMainThread: Bool { operationLock.withLock { recordedOperations.contains { $0.1 } } }

    init(tableOfContents: Data) throws {
        self.tableOfContents = tableOfContents
        sectorCount = try CDTableOfContents(data: tableOfContents).leadOutSector
    }

    func remove() { isRemoved = true }

    static func sample(frame: Int64, channel: Int) -> Int16 {
        Int16(truncatingIfNeeded: frame &* 37 &+ Int64(channel) &* 1_009)
    }

    /// Clean little-endian stereo audio for whole sectors, starting `shift` frames late (early if negative).
    static func audio(from firstSector: UInt64, count: Int, shift: Int = 0) -> Data {
        var data = Data(capacity: count * CDSectorBlock.audioBytes)
        let start = Int64(firstSector) * Int64(Disc.framesPerSector) + Int64(shift)
        for frame in start ..< start + Int64(count) * Int64(Disc.framesPerSector) {
            for channel in 0..<2 {
                let value = UInt16(bitPattern: sample(frame: frame, channel: channel))
                data.append(UInt8(value & 0xFF))
                data.append(UInt8(value >> 8))
            }
        }
        return data
    }

    func readTableOfContents() throws -> Data {
        record(.tableOfContents)
        try begin()
        return tableOfContents
    }

    func read(from firstSector: UInt64, count: Int, errorFlags: Bool) throws -> CDSectorBlock {
        record(.read)
        try begin()
        try readGate?.wait()
        try readNumberGates[reads.count + 1]?.wait()
        reads.append(Read(firstSector: firstSector, count: count, errorFlags: errorFlags))
        guard (1...RawCDReader.maxSectorsPerRead).contains(count), firstSector + UInt64(count) <= sectorCount else {
            throw CDReadError(.failed, "The audio sector request is invalid.", systemError: EINVAL)
        }
        if errorFlags && !supportsErrorFlags { throw errorFlagRejection }
        let sectors = firstSector ..< firstSector + UInt64(count)
        if let sector = sectors.first(where: { unreadableSectors[$0] != nil }), let error = unreadableSectors[sector] {
            throw error
        }
        if let sector = sectors.first(where: { transientErrors[$0]?.isEmpty == false }) {
            throw transientErrors[sector]!.removeFirst()
        }
        if !readBlocks.isEmpty { return readBlocks.removeFirst() }
        let shift = readStartShifts.isEmpty ? 0 : readStartShifts.removeFirst()
        var audio = Self.audio(from: firstSector, count: count, shift: shift)
        for byte in flaggedBytes.union(silentlyDamagedBytes) where sectors.contains(byte.sector) {
            audio[Int(byte.sector - firstSector) * CDSectorBlock.audioBytes + byte.offset] ^= 0x5A
        }
        for sector in sectors {
            let start = Int(sector - firstSector) * CDSectorBlock.audioBytes
            let range = start..<start + CDSectorBlock.audioBytes
            if let cached = audioCache[sector] {
                audio.replaceSubrange(range, with: cached)
            } else {
                if uncachedAudioVersions[sector]?.isEmpty == false {
                    audio.replaceSubrange(range, with: uncachedAudioVersions[sector]!.removeFirst())
                }
                if audioCacheCapacity > 0 {
                    audioCache[sector] = audio.subdata(in: range)
                    cacheOrder.append(sector)
                    while cacheOrder.count > audioCacheCapacity {
                        audioCache.removeValue(forKey: cacheOrder.removeFirst())
                    }
                }
            }
        }
        guard errorFlags else { return CDSectorBlock(firstSector: firstSector, audio: audio, errorFlags: nil) }
        // One bit per audio byte, most significant bit first; 2,352 bits fill each sector's 294 bytes exactly.
        var flags = Data(count: count * CDSectorBlock.errorFlagBytes)
        for byte in flaggedBytes where sectors.contains(byte.sector) {
            let bit = Int(byte.sector - firstSector) * CDSectorBlock.audioBytes + byte.offset
            flags[bit / 8] |= 0x80 >> UInt8(bit % 8)
        }
        return CDSectorBlock(firstSector: firstSector, audio: audio, errorFlags: flags)
    }

    func speed() throws -> UInt16 {
        record(.speed)
        try begin()
        if !speedReadReplies.isEmpty { return try speedReadReplies.removeFirst().get() }
        return reportedSpeed
    }

    func setSpeed(_ kilobytesPerSecond: UInt16) throws {
        record(.setSpeed(kilobytesPerSecond))
        try begin()
        try speedSetGate?.wait()
        speedRequests.append(kilobytesPerSecond)
        if !speedSetFailures.isEmpty, let failure = speedSetFailures.removeFirst() { throw failure }
        if obeysSpeedRequests { reportedSpeed = kilobytesPerSecond }
    }

    func close() {
        record(.close)
        do {
            try closeGate?.wait()
        } catch {
            Issue.record("Fake disc close failed: \(error)")
        }
        closedLock.withLock { closed = true }
    }

    private func record(_ operation: Operation) {
        operationLock.withLock { recordedOperations.append((operation, Thread.isMainThread)) }
    }

    private func begin() throws {
        if delay > .zero {
            Thread.sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
        }
        guard !isClosed else { throw CDReadError(.failed, "The optical disc is closed.") }
        guard !isRemoved else { throw CDReadError(.gone, "The disc or drive is no longer available.", systemError: ENXIO) }
    }
}

/// Opens a fresh fake disc each time, or fails like a refused or missing disc. Opens happen on a
/// session's queue, so its records are locked.
final class FakeDiscOpener: DiscOpener, @unchecked Sendable {
    struct Open: Equatable {
        let mediaID: UInt64
        let driveID: UInt64
        let onMainThread: Bool
    }

    struct DriveProfile: Sendable {
        let readFeatures: CDReadFeatures
        let supportsErrorFlags: Bool
    }

    private let lock = NSLock()
    private let tableOfContents: Data
    private let delay: Duration
    private let gate: TestGate?
    private let readFeatures: CDReadFeatures
    private let driveProfiles: [UInt64: DriveProfile]
    private var failure: CDReadError?
    private var recordedOpens: [Open] = []
    private var openedDiscs: [FakeCDSectorSource] = []

    init(
        tableOfContents: Data = tocFixture(), failure: CDReadError? = nil, delay: Duration = .zero,
        gate: TestGate? = nil, readFeatures: CDReadFeatures = CDReadFeatures(cdFeatures: 0x10),
        driveProfiles: [UInt64: DriveProfile] = [:]
    ) {
        self.tableOfContents = tableOfContents
        self.failure = failure
        self.delay = delay
        self.gate = gate
        self.readFeatures = readFeatures
        self.driveProfiles = driveProfiles
    }

    var opens: [Open] { lock.withLock { recordedOpens } }
    /// The fake disc handed out by each successful open, in order.
    var discs: [FakeCDSectorSource] { lock.withLock { openedDiscs } }

    func open(_ media: OpticalMedia, driveID: UInt64) throws -> any CDSectorSource {
        let (failure, profile) = lock.withLock {
            recordedOpens.append(Open(mediaID: media.id, driveID: driveID, onMainThread: Thread.isMainThread))
            return (self.failure, driveProfiles[driveID])
        }
        try gate?.wait()
        if delay > .zero {
            Thread.sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
        }
        if let failure { throw failure }
        let disc = try FakeCDSectorSource(tableOfContents: tableOfContents)
        disc.readFeatures = profile?.readFeatures ?? readFeatures
        disc.supportsErrorFlags = profile?.supportsErrorFlags ?? true
        lock.withLock { openedDiscs.append(disc) }
        return disc
    }
}
