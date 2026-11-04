import Dispatch
import Foundation
import OSLog

/// Opens a disc for reading. It is called on a session's own queue, never on the main thread.
public protocol DiscOpener: Sendable {
    func open(_ media: OpticalMedia, driveID: UInt64) throws -> any CDSectorSource
}

/// Re-checks the disc's identity in the registry, then opens its raw device read-only.
public struct RawDiscOpener: DiscOpener {
    public init() {}

    public func open(_ media: OpticalMedia, driveID: UInt64) throws -> any CDSectorSource {
        let features = try OpticalRegistry.verifyReadable(media, driveID: driveID)
        guard let bsdName = media.bsdName else {
            throw CDReadError(.failed, "The selected optical disc is not ready for reading.")
        }
        return try RawCDReader(bsdName: bsdName, readFeatures: features)
    }
}

/// Time inside raw reads only: pacing, queue waits and speed controls are excluded.
/// Cached reads and failed attempts affect this measurement; it is not spindle speed.
public struct DiscReadStatistics: Equatable, Sendable {
    public private(set) var readCount: UInt64 = 0
    public private(set) var audioBytes: UInt64 = 0
    public private(set) var readDuration: Duration = .zero

    public var kilobytesPerSecond: Double? {
        let parts = readDuration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return seconds > 0 ? Double(audioBytes) / 1_000 / seconds : nil
    }

    mutating func record(audioBytes: Int, duration: Duration) {
        readCount += 1
        self.audioBytes += UInt64(audioBytes)
        readDuration += duration
    }
}

public struct C2ProbeResult: Equatable, Sendable {
    public let support: C2Support
    /// Number of audio bytes flagged in the probe sector.
    public let flaggedAudioBytes: UInt64
    public let flaggedSectors: UInt64

    init(support: C2Support, flaggedAudioBytes: UInt64 = 0, flaggedSectors: UInt64 = 0) {
        self.support = support
        self.flaggedAudioBytes = flaggedAudioBytes
        self.flaggedSectors = flaggedSectors
    }
}

public struct DiscSessionCloseReport: Equatable, Sendable {
    public let speedChangeAttempted: Bool
    public let originalSpeed: UInt16?
    public let restoredSpeed: UInt16?
    public let speedRestored: Bool
    public let speedRestoreError: String?

    init(
        speedChangeAttempted: Bool = false, originalSpeed: UInt16? = nil, restoredSpeed: UInt16? = nil,
        speedRestored: Bool = true, speedRestoreError: String? = nil
    ) {
        self.speedChangeAttempted = speedChangeAttempted
        self.originalSpeed = originalSpeed
        self.restoredSpeed = restoredSpeed
        self.speedRestored = speedRestored
        self.speedRestoreError = speedRestoreError
    }
}

/// Read access to one audio CD, kept from Play until eject, removal or replacement, a drive or
/// source change, or quit. Its work runs on the session's own serial queue, so blocking drive calls
/// never occupy the main thread or Swift's shared threads, and closing waits for a read in progress.
public actor DiscSession {
    public nonisolated let driveID: UInt64
    public nonisolated let mediaID: UInt64
    /// The playback timeline of the opened disc.
    public nonisolated let disc: Disc
    private let queue = DispatchSerialQueue(label: "io.github.ylau674.CDPlayer.disc-session", qos: .userInitiated)
    // Synchronize state shared by queue.sync producer work and regular actor jobs.
    private let stateLock = NSLock()
    private var reader: (any CDSectorSource)?
    private var savedSpeed: UInt16?
    private var speedPreparation: Result<Void, any Error>?
    private let recoveryLock = NSLock()
    private var recovery: DiscReadRecovery?
    public private(set) var readFeatures = CDReadFeatures()
    // Explicitly synchronize the metrics handoff from the blocking producer's queue.sync.
    private let statisticsLock = NSLock()
    private var statistics = DiscReadStatistics()
    private static let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Disc")

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    public var readStatistics: DiscReadStatistics { statisticsLock.withLock { statistics } }
    public var c2Support: C2Support { recoveryLock.withLock { recovery?.c2Support ?? .unknown } }
    public var sectorsClearedByRetry: UInt64 { recoveryLock.withLock { recovery?.sectorsClearedByRetry ?? 0 } }

    public var retryPolicy: DiscRetryPolicy { recoveryLock.withLock { recovery?.retryPolicy ?? .singlePass } }

    /// Applies to later reads of this open session; the default is `.singlePass`.
    public func setRetryPolicy(_ policy: DiscRetryPolicy) {
        recoveryLock.withLock { recovery?.retryPolicy = policy }
    }

    private init(driveID: UInt64, mediaID: UInt64, disc: Disc) {
        self.driveID = driveID
        self.mediaID = mediaID
        self.disc = disc
    }

    /// Opens the disc once. A refusal is returned to the caller, never retried another way.
    public static func open(
        _ media: OpticalMedia, driveID: UInt64, tableOfContents: CDTableOfContents, opener: any DiscOpener
    ) async throws -> DiscSession {
        let session = DiscSession(driveID: driveID, mediaID: media.id, disc: Disc(tableOfContents: tableOfContents))
        try await session.connect(media, expecting: tableOfContents, opener: opener)
        return session
    }

    private func connect(_ media: OpticalMedia, expecting tableOfContents: CDTableOfContents, opener: any DiscOpener) throws {
        let reader = try opener.open(media, driveID: driveID)
        do {
            // A different disc behind the same device name would have a different track table.
            guard try CDTableOfContents(data: reader.readTableOfContents()) == tableOfContents else {
                throw CDReadError(.failed, "The disc's own track table does not match the one macOS reported.")
            }
        } catch {
            reader.close()
            throw error
        }
        let features = reader.readFeatures
        stateLock.withLock { self.reader = reader }
        readFeatures = features
        recoveryLock.withLock { recovery = DiscReadRecovery(disc: disc, features: features) }
        Self.logger.info("Drive \(self.driveID) stream-accurate CD reads: \(features.streamAccurate); audio cache bound unknown unless independently established")
        Self.logger.info("Opened disc \(self.mediaID) in drive \(self.driveID) for reading")
    }

    public var isOpen: Bool { stateLock.withLock { reader != nil } }

    public func read(from firstSector: UInt64, count: Int, errorFlags: Bool) throws -> CDSectorBlock {
        let reader = try openReader()
        let started = ContinuousClock.now
        var audioBytes = 0
        defer {
            let duration = ContinuousClock.now - started
            statisticsLock.withLock { statistics.record(audioBytes: audioBytes, duration: duration) }
            let milliseconds = duration / .milliseconds(1)
            if audioBytes == 0 || milliseconds >= 500 {
                Self.logger.warning("Raw read at LBA \(firstSector) x\(count), C2 \(errorFlags), \(audioBytes == 0 ? "failed" : "succeeded", privacy: .public) after \(milliseconds, format: .fixed(precision: 0)) ms")
            }
        }
        let block = try reader.read(from: firstSector, count: count, errorFlags: errorFlags)
        audioBytes = block.audio.count
        return block
    }

    /// Probes C2 on one sector. A failed C2 request is called unsupported only if the
    /// identical plain read succeeds; access refusals and removal are never retried.
    public func probeC2(at firstSector: UInt64) throws -> C2ProbeResult {
        let flagged: CDSectorBlock
        do {
            flagged = try read(from: firstSector, count: 1, errorFlags: true)
        } catch let error as CDReadError where error.kind == .mediaError || error.kind == .failed {
            let plain = try read(from: firstSector, count: 1, errorFlags: false)
            try Self.validateProbeBlock(plain, firstSector: firstSector, withFlags: false)
            return C2ProbeResult(support: .unsupported)
        }
        try Self.validateProbeBlock(flagged, firstSector: firstSector, withFlags: true)
        let flags = flagged.errorFlags!
        let flaggedBytes = UInt64(flags.reduce(0) { $0 + $1.nonzeroBitCount })
        return C2ProbeResult(
            support: .supported, flaggedAudioBytes: flaggedBytes, flaggedSectors: flaggedBytes == 0 ? 0 : 1
        )
    }

    private static func validateProbeBlock(
        _ block: CDSectorBlock, firstSector: UInt64, withFlags: Bool
    ) throws {
        guard block.firstSector == firstSector, block.audio.count == CDSectorBlock.audioBytes,
              withFlags ? block.errorFlags?.count == CDSectorBlock.errorFlagBytes : block.errorFlags == nil else {
            throw CDReadError(.failed, "The drive returned an invalid C2 probe sector.")
        }
    }

    /// Only the dedicated C producer may wait here. No pointer or non-Sendable reader crosses
    /// the actor boundary, and reads still serialize with speed changes and close.
    nonisolated func readForProducer(
        from firstSector: UInt64, count: Int, track: Disc.Track, context: PCMReadContext
    ) throws -> PCMReadResult {
        return try queue.sync {
            try self.assumeIsolated { session in
                try context.checkCancellation()
                try session.prepareForPlayback()
                try context.checkCancellation()
                return try session.recoveryLock.withLock {
                    guard let recovery = session.recovery else {
                        throw CDReadError(.failed, "The disc session is closed.")
                    }
                    return try recovery.read(
                        from: firstSector, count: count, track: track, context: context,
                        statistics: { session.readStatistics },
                        rawRead: { try session.read(from: $0, count: $1, errorFlags: $2) }
                    )
                }
            }
        }
    }

    public func speed() throws -> UInt16 {
        try openReader().speed()
    }

    /// Saves the initial setting on the first successful change, for restoration on close.
    public func setSpeed(_ kilobytesPerSecond: UInt16) throws {
        let reader = try openReader()
        let saved = stateLock.withLock { savedSpeed }
        let original = try saved ?? reader.speed()
        guard original != 0 else {
            throw CDReadError(.failed, "The drive reported an unknown speed; leaving it unchanged.")
        }
        if saved == nil {
            stateLock.withLock { savedSpeed = original }
            do {
                try reader.setSpeed(kilobytesPerSecond)
            } catch let error as CDReadError where error.kind == .refused || error.kind == .gone {
                stateLock.withLock { savedSpeed = nil }
                throw error
            }
        } else {
            try reader.setSpeed(kilobytesPerSecond)
        }
    }

    /// Once per session, immediately before its first PCM read, not during discovery or open.
    func prepareForPlayback() throws {
        _ = try openReader()
        if let preparation = stateLock.withLock({ speedPreparation }) { return try preparation.get() }
        do {
            try setSpeed(RawCDReader.minimumSpeed)
            let reported = try speed()
            if reported == RawCDReader.minimumSpeed {
                Self.logger.info("Requested minimum drive speed \(RawCDReader.minimumSpeed) kB/s; reported \(reported) kB/s (not measured throughput)")
            } else {
                Self.logger.warning("Requested minimum drive speed \(RawCDReader.minimumSpeed) kB/s; reported \(reported) kB/s. Actual read throughput is measured separately.")
            }
            stateLock.withLock { speedPreparation = .success(()) }
        } catch let error as CDReadError where error.kind == .failed || error.kind == .mediaError {
            Self.logger.warning("Best-effort drive slowdown unavailable; continuing without a speed guarantee: \(error.message, privacy: .public)")
            stateLock.withLock { speedPreparation = .success(()) }
        } catch {
            Self.logger.error("Drive-speed setup failed; refusing PCM reads: \(error.localizedDescription, privacy: .public)")
            stateLock.withLock { speedPreparation = .failure(error) }
            throw error
        }
    }

    /// Restores speed and closes after any read in progress. Cleanup failures are logged;
    /// removal or a rejected restoration must not prevent closing. Closing twice is harmless.
    @discardableResult
    public func close() -> DiscSessionCloseReport {
        let (reader, savedSpeed) = stateLock.withLock { (self.reader, self.savedSpeed) }
        guard let reader else { return DiscSessionCloseReport() }
        var closeReport = DiscSessionCloseReport(
            speedChangeAttempted: savedSpeed != nil, originalSpeed: savedSpeed, speedRestored: savedSpeed == nil
        )
        if let savedSpeed {
            do {
                try reader.setSpeed(savedSpeed)
                let reported = try reader.speed()
                if reported != savedSpeed {
                    closeReport = DiscSessionCloseReport(
                        speedChangeAttempted: true, originalSpeed: savedSpeed, restoredSpeed: reported,
                        speedRestored: false, speedRestoreError: "The drive reported \(reported) kB/s after restoration."
                    )
                    Self.logger.error("Drive speed restoration requested \(savedSpeed) kB/s but reports \(reported) kB/s")
                } else {
                    closeReport = DiscSessionCloseReport(
                        speedChangeAttempted: true, originalSpeed: savedSpeed,
                        restoredSpeed: reported, speedRestored: true
                    )
                    Self.logger.info("Restored reported drive speed to \(reported) kB/s")
                }
            } catch {
                closeReport = DiscSessionCloseReport(
                    speedChangeAttempted: true, originalSpeed: savedSpeed, speedRestored: false,
                    speedRestoreError: error.localizedDescription
                )
                Self.logger.error("Cannot restore drive speed before close: \(error.localizedDescription, privacy: .public)")
            }
        }
        reader.close()
        stateLock.withLock {
            self.reader = nil
            self.savedSpeed = nil
        }
        let statistics = readStatistics
        if let throughput = statistics.kilobytesPerSecond {
            Self.logger.info("Disc raw-read throughput: \(throughput) kB/s over \(statistics.readCount) attempts, \(statistics.audioBytes) audio bytes (includes cache effects; excludes pacing)")
        }
        Self.logger.info("Closed disc \(self.mediaID)")
        return closeReport
    }

    private func openReader() throws -> any CDSectorSource {
        guard let reader = stateLock.withLock({ self.reader }) else {
            throw CDReadError(.failed, "The disc session is closed.")
        }
        return reader
    }
}
