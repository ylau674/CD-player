import Foundation
import OSLog

struct RecoveredAudio {
    var samples: [Int16]
    var concealed: Set<UInt64> = []
    var unverified = false
}

/// What the recovery reader does when the drive's C2 pointers flag samples as uncorrectable.
public enum DiscRetryPolicy: Sendable, Equatable {
    /// The default. Read each block once and interpolate flagged samples, like a stand-alone CD
    /// player: no re-reads or cache read-away seeks, and without C2 no double-check read either.
    /// A block that fails outright is still split into single-sector reads to find the bad sector.
    case singlePass
    /// Re-read flagged blocks when the buffer has time to spare, never while BUFFERING.
    case retry
}

/// One producer's sector history. Every call belongs to the disc session's serial queue.
final class DiscReadRecovery {
    static let maximumReadSectors = 37
    static let maximumCacheDisplacementSectors = 74
    static let maximumRetries = 3
    private static let samplesPerSector = 1_176
    private static let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "DiscRead")
    let features: CDReadFeatures
    let disc: Disc
    private(set) var c2Support = C2Support.unknown
    var retryPolicy = DiscRetryPolicy.singlePass
    /// Sectors whose first read was C2-flagged but which retries resolved without concealment.
    private(set) var sectorsClearedByRetry: UInt64 = 0
    private var probedC2 = false
    private var cacheStart: UInt64 = 0
    private var cache = RecoveredAudio(samples: [])
    private var reportedConcealment: Set<UInt64> = []
    private var loggedUnverified = false

    init(disc: Disc, features: CDReadFeatures) {
        self.disc = disc
        self.features = features
    }

    func read(
        from firstSector: UInt64, count: Int, track: Disc.Track, context: PCMReadContext,
        statistics: () -> DiscReadStatistics,
        rawRead: (UInt64, Int, Bool) throws -> CDSectorBlock
    ) throws -> PCMReadResult {
        try context.checkCancellation()
        guard (1...DiscPCMSource.maxSectorsPerRead).contains(count), disc.tracks.contains(track),
              firstSector >= track.firstSector, firstSector - track.firstSector < track.sectorCount,
              UInt64(count) <= track.sectorCount - (firstSector - track.firstSector) else {
            throw CDReadError(.failed, "The recovery request is outside the selected audio track.")
        }
        if context.beginsPlayback {
            cache = RecoveredAudio(samples: [])
            reportedConcealment.removeAll()
            loggedUnverified = false
        }
        let end = firstSector + UInt64(count)
        let cacheEnd = cacheStart + UInt64(cache.samples.count / Self.samplesPerSector)
        var result = RecoveredAudio(samples: [])
        var cursor = firstSector
        if cursor >= cacheStart && cursor < cacheEnd {
            let cachedEnd = min(end, cacheEnd)
            let startIndex = Int(cursor - cacheStart) * Self.samplesPerSector
            let endIndex = Int(cachedEnd - cacheStart) * Self.samplesPerSector
            result.samples += cache.samples[startIndex..<endIndex]
            result.concealed = cache.concealed.filter { $0 >= cursor && $0 < cachedEnd }
            result.unverified = cache.unverified
            cursor = cachedEnd
        }
        if cursor < end {
            var anchor: [Int16]?
            if cursor == cacheEnd, cursor > track.firstSector, !cache.concealed.contains(cursor - 1),
               cache.samples.count >= Self.samplesPerSector {
                anchor = Array(cache.samples.suffix(Self.samplesPerSector))
            }
            var budget = ReadRecoveryBudget(context: context)
            let remaining = try recover(
                from: cursor, count: Int(end - cursor), track: track, anchor: anchor,
                isolated: false, context: context, budget: &budget, statistics: statistics, rawRead: rawRead
            )
            result.samples += remaining.samples
            result.concealed.formUnion(remaining.concealed)
            result.unverified = result.unverified || remaining.unverified
        }
        try context.checkCancellation()
        cacheStart = firstSector
        cache = result
        let newlyConcealed = result.concealed.subtracting(reportedConcealment)
        for sector in newlyConcealed.sorted() {
            Self.logger.warning("Concealed audio at CD LBA \(sector)")
        }
        reportedConcealment.formUnion(newlyConcealed)
        if result.unverified && !loggedUnverified {
            Self.logger.warning("CD audio is UNVERIFIED: cache independence, alignment or verification budget could not be established.")
            loggedUnverified = true
        }
        return PCMReadResult(
            samples: result.samples, concealedSectors: UInt64(newlyConcealed.count), unverified: result.unverified
        )
    }

    private struct Candidate {
        let samples: [Int16]
        let flags: [Bool]
        var independent = false
        var unverified = false
    }

    private enum AlignmentFailure: Error { case noMatch }
    private struct RecoveryBudgetExhausted: Error {}

    private func recover(
        from sector: UInt64, count: Int, track: Disc.Track, anchor: [Int16]?, isolated: Bool,
        context: PCMReadContext, budget: inout ReadRecoveryBudget,
        statistics: () -> DiscReadStatistics,
        rawRead: (UInt64, Int, Bool) throws -> CDSectorBlock
    ) throws -> RecoveredAudio {
        var candidates: [Candidate] = []
        if let initial = try attempt(
            from: sector, count: count, track: track, anchor: anchor, isolated: isolated,
            context: context, budget: &budget, rawRead: rawRead
        ) {
            candidates.append(initial)
            if c2Support == .supported && !initial.flags.contains(true) {
                return RecoveredAudio(samples: initial.samples, unverified: initial.unverified)
            }
        }
        let initialSucceeded = !candidates.isEmpty
        let optional = candidates.first.map { !$0.flags.contains(true) } ?? false
        // Single pass reads once and interpolates like a CD player. Even `.retry` never re-reads
        // while BUFFERING: that delays the start or seek by seconds and rarely clears physical damage.
        let retries = retryPolicy == .singlePass || context.buffering ? 0 : Self.maximumRetries
        for _ in 0..<retries {
            let excludedStart = sector - min(2, sector - track.firstSector)
            let excludedEnd = min(track.firstSector + track.sectorCount, sector + UInt64(count) + 1)
            let displacement = displacementRanges(excluding: excludedStart..<excludedEnd)
            let work = displacement.reduce(count + 3) { $0 + $1.count }
            guard budget.allows(sectors: work, statistics: statistics(), optional: optional) else { break }
            let independent = try displace(
                ranges: displacement, context: context, budget: &budget, rawRead: rawRead
            )
            guard budget.allows(sectors: count + 3, statistics: statistics(), optional: false) else { break }
            if var next = try attempt(
                from: sector, count: count, track: track, anchor: anchor, isolated: isolated,
                context: context, budget: &budget, rawRead: rawRead
            ) {
                next.independent = independent
                candidates.append(next)
                if allSectorsMatch(candidates, count: count) { break }
            }
        }
        if candidates.isEmpty && count > 1 {
            var result = RecoveredAudio(samples: [])
            for index in 0..<count {
                try context.checkCancellation()
                let lba = sector + UInt64(index)
                if budget.allows(sectors: 1, statistics: statistics(), optional: false) {
                    let part = try recover(
                        from: lba, count: 1, track: track, anchor: nil, isolated: true,
                        context: context, budget: &budget, statistics: statistics, rawRead: rawRead
                    )
                    result.samples += part.samples
                    result.concealed.formUnion(part.concealed)
                    result.unverified = result.unverified || part.unverified
                } else {
                    result.samples += [Int16](repeating: 0, count: Self.samplesPerSector)
                    result.concealed.insert(lba)
                }
            }
            return result
        }
        let resolved = resolve(
            candidates, from: sector, count: count, anchor: anchor, initialSucceeded: initialSucceeded, optional: optional
        )
        if initialSucceeded, candidates.count > 1, let initial = candidates.first {
            for index in 0..<count where !resolved.concealed.contains(sector + UInt64(index)) &&
                initial.flags[index * Self.samplesPerSector..<(index + 1) * Self.samplesPerSector].contains(true) {
                sectorsClearedByRetry += 1
            }
        }
        return resolved
    }

    private func attempt(
        from sector: UInt64, count: Int, track: Disc.Track, anchor: [Int16]?, isolated: Bool,
        context: PCMReadContext, budget: inout ReadRecoveryBudget,
        rawRead: (UInt64, Int, Bool) throws -> CDSectorBlock
    ) throws -> Candidate? {
        let prefix = isolated || anchor == nil ? 0 : Int(min(2, sector - track.firstSector))
        let end = sector + UInt64(count)
        let suffix = features.streamAccurate || isolated ? 0 : Int(min(1, track.firstSector + track.sectorCount - end))
        let start = sector - UInt64(prefix)
        let sectors = prefix + count + suffix
        do {
            let block = try readWithC2(from: start, count: sectors, context: context, budget: &budget, rawRead: rawRead)
            let candidate = try decode(block, firstSector: start, count: sectors, flags: c2Support == .supported)
            return try align(candidate, prefix: prefix, count: count, anchor: anchor)
        } catch let error as CDReadError where error.kind == .mediaError {
            Self.logger.debug("CD media read failed at LBA \(start): \(error.message, privacy: .public)")
            return nil
        } catch is AlignmentFailure {
            Self.logger.debug("CD overlap could not be aligned at LBA \(sector)")
            return nil
        } catch is RecoveryBudgetExhausted {
            return nil
        }
    }

    private func readWithC2(
        from sector: UInt64, count: Int, context: PCMReadContext, budget: inout ReadRecoveryBudget,
        rawRead: (UInt64, Int, Bool) throws -> CDSectorBlock
    ) throws -> CDSectorBlock {
        let flags = c2Support != .unsupported
        let probe = c2Support == .unknown && !probedC2
        if probe { probedC2 = true }
        let block: CDSectorBlock
        do {
            block = try checkedRead(sector, count, flags, context: context, budget: &budget, rawRead: rawRead)
        } catch let error as CDReadError where probe && (error.kind == .mediaError || error.kind == .failed) {
            let block = try checkedRead(
                sector, count, false, context: context, budget: &budget, negotiatingC2: true, rawRead: rawRead
            )
            try validate(block, firstSector: sector, count: count, flags: false)
            c2Support = .unsupported
            Self.logger.warning("C2 request failed but the same plain read succeeded; C2 is unavailable for this disc session.")
            return block
        }
        try validate(block, firstSector: sector, count: count, flags: flags)
        if flags { c2Support = .supported }
        return block
    }

    private static let invalidBlock = "The disc returned an invalid audio sector block."

    private func checkedRead(
        _ sector: UInt64, _ count: Int, _ flags: Bool, context: PCMReadContext,
        budget: inout ReadRecoveryBudget, negotiatingC2: Bool = false,
        rawRead: (UInt64, Int, Bool) throws -> CDSectorBlock
    ) throws -> CDSectorBlock {
        try context.checkCancellation()
        guard (1...Self.maximumReadSectors).contains(count) else {
            throw CDReadError(.failed, "The recovery reader exceeded its sector limit.")
        }
        guard budget.permitsRead(negotiatingC2: negotiatingC2) else { throw RecoveryBudgetExhausted() }
        budget.operations += 1
        let block = try rawRead(sector, count, flags)
        try context.checkCancellation()
        return block
    }

    private func validate(_ block: CDSectorBlock, firstSector: UInt64, count: Int, flags: Bool) throws {
        guard block.firstSector == firstSector, block.audio.count == count * CDSectorBlock.audioBytes,
              flags ? block.errorFlags?.count == count * CDSectorBlock.errorFlagBytes : block.errorFlags == nil else {
            throw CDReadError(.failed, Self.invalidBlock)
        }
    }

    private func decode(_ block: CDSectorBlock, firstSector: UInt64, count: Int, flags: Bool) throws -> Candidate {
        try validate(block, firstSector: firstSector, count: count, flags: flags)
        let sampleCount = count * Self.samplesPerSector
        let samples = [Int16](unsafeUninitializedCapacity: sampleCount) { buffer, initialized in
            block.audio.withUnsafeBytes { UnsafeMutableRawBufferPointer(buffer).copyMemory(from: $0) }
            // Disc audio is little-endian; on a little-endian Mac this loop compiles away.
            for index in 0..<sampleCount { buffer[index] = Int16(littleEndian: buffer[index]) }
            initialized = sampleCount
        }
        var suspect = [Bool](repeating: false, count: sampleCount)
        block.errorFlags?.withUnsafeBytes { bytes in
            // One bit per audio byte, most significant first, so each flag byte covers four samples.
            for (index, byte) in bytes.enumerated() where byte != 0 {
                for sample in 0..<4 where byte & (0xC0 >> UInt8(sample * 2)) != 0 {
                    suspect[index * 4 + sample] = true
                }
            }
        }
        return Candidate(samples: samples, flags: suspect)
    }

    private func align(_ raw: Candidate, prefix: Int, count: Int, anchor: [Int16]?) throws -> Candidate {
        let nominal = prefix * Self.samplesPerSector
        let length = count * Self.samplesPerSector
        guard let anchor, prefix > 0 else {
            return Candidate(
                samples: Array(raw.samples[nominal..<nominal + length]),
                flags: Array(raw.flags[nominal..<nominal + length]), unverified: !features.streamAccurate
            )
        }
        let sectorFrames = Int(Disc.framesPerSector)
        let shifts = features.streamAccurate ? 0...0 : -sectorFrames...sectorFrames
        var matches: [Int] = []
        for shift in shifts {
            let start = nominal + shift * 2
            let overlap = start - anchor.count
            guard overlap >= 0, start + length <= raw.samples.count else { continue }
            var compared = 0
            var equal = true
            for index in anchor.indices where !raw.flags[overlap + index] {
                if raw.samples[overlap + index] != anchor[index] { equal = false; break }
                compared += 1
            }
            if equal && compared >= 256 { matches.append(start) }
        }
        guard let start = matches.first else { throw AlignmentFailure.noMatch }
        let samples = Array(raw.samples[start..<start + length])
        let flags = Array(raw.flags[start..<start + length])
        // A periodic/silent overlap is safe only when every possible alignment emits identical
        // PCM and flags. Never pick an arbitrary offset from an ambiguous musical pattern.
        for alternative in matches.dropFirst() {
            guard raw.samples[alternative..<alternative + length].elementsEqual(samples),
                  raw.flags[alternative..<alternative + length].elementsEqual(flags) else {
                throw AlignmentFailure.noMatch
            }
        }
        return Candidate(samples: samples, flags: flags, unverified: matches.count > 1)
    }

    private func matchingPair(_ candidates: [Candidate], range: Range<Int>) -> (Candidate, Candidate)? {
        for (index, next) in candidates.enumerated().dropFirst() {
            guard !next.flags[range].contains(true) else { continue }
            for previous in candidates[..<index] where !previous.flags[range].contains(true) {
                if previous.samples[range].elementsEqual(next.samples[range]) { return (previous, next) }
            }
        }
        return nil
    }

    private func allSectorsMatch(_ candidates: [Candidate], count: Int) -> Bool {
        (0..<count).allSatisfy {
            matchingPair(candidates, range: $0 * Self.samplesPerSector..<($0 + 1) * Self.samplesPerSector) != nil
        }
    }

    private func resolve(
        _ candidates: [Candidate], from sector: UInt64, count: Int, anchor: [Int16]?,
        initialSucceeded: Bool, optional: Bool
    ) -> RecoveredAudio {
        var result = RecoveredAudio(samples: [])
        var suspect: [Bool] = []
        for index in 0..<count {
            let range = index * Self.samplesPerSector..<(index + 1) * Self.samplesPerSector
            if let (first, second) = matchingPair(candidates, range: range) {
                result.samples += second.samples[range]
                suspect += [Bool](repeating: false, count: Self.samplesPerSector)
                result.unverified = result.unverified || !second.independent || first.unverified || second.unverified
                continue
            }
            guard let best = candidates.min(by: { $0.flags[range].filter { $0 }.count < $1.flags[range].filter { $0 }.count }) else {
                result.samples += [Int16](repeating: 0, count: Self.samplesPerSector)
                suspect += [Bool](repeating: false, count: Self.samplesPerSector)
                result.concealed.insert(sector + UInt64(index))
                continue
            }
            let samples = Array(best.samples[range])
            var flags = Array(best.flags[range])
            for other in candidates {
                for (offset, sample) in range.enumerated() {
                    if other.flags[sample] ||
                        (!best.flags[sample] && !other.flags[sample] && best.samples[sample] != other.samples[sample]) {
                        flags[offset] = true
                    }
                }
            }
            let initiallyClean = initialSucceeded && (candidates.first.map { !$0.flags[range].contains(true) } ?? false)
            if !optional && !initiallyClean && !flags.contains(true) {
                result.samples += [Int16](repeating: 0, count: Self.samplesPerSector)
                suspect += [Bool](repeating: false, count: Self.samplesPerSector)
                result.concealed.insert(sector + UInt64(index))
                continue
            }
            result.samples += samples
            suspect += flags
            if flags.contains(true) { result.concealed.insert(sector + UInt64(index)) }
            result.unverified = result.unverified || c2Support != .supported || best.unverified ||
                (!flags.contains(true) && !initiallyClean)
        }
        Self.interpolate(&result.samples, suspect: suspect, preceding: anchor)
        return result
    }

    /// Use other audio sectors only, never data tracks, session gaps or the target window.
    func displacementRanges(excluding target: Range<UInt64>) -> [Range<UInt64>] {
        let bound = features.cacheCapacitySectors
        let wanted = min(Self.maximumCacheDisplacementSectors, bound.map { min($0, Self.maximumCacheDisplacementSectors) + 1 } ?? Self.maximumCacheDisplacementSectors)
        if bound == 0 { return [] }
        var remaining = wanted
        var ranges: [Range<UInt64>] = []
        for track in disc.tracks.reversed() {
            let trackEnd = track.firstSector + track.sectorCount
            let parts = [
                min(trackEnd, max(track.firstSector, target.upperBound))..<trackEnd,
                track.firstSector..<min(trackEnd, max(track.firstSector, target.lowerBound))
            ]
            for part in parts where !part.isEmpty {
                var end = min(part.upperBound, trackEnd)
                while remaining > 0 && end > part.lowerBound {
                    let count = min(remaining, Self.maximumReadSectors, Int(end - part.lowerBound))
                    ranges.append(end - UInt64(count)..<end)
                    end -= UInt64(count)
                    remaining -= count
                }
            }
            if remaining == 0 { break }
        }
        return ranges
    }

    private func displace(
        ranges: [Range<UInt64>], context: PCMReadContext, budget: inout ReadRecoveryBudget,
        rawRead: (UInt64, Int, Bool) throws -> CDSectorBlock
    ) throws -> Bool {
        var sectors = 0
        for range in ranges {
            do {
                let block = try checkedRead(range.lowerBound, range.count, false, context: context, budget: &budget, rawRead: rawRead)
                try validate(block, firstSector: range.lowerBound, count: range.count, flags: false)
                sectors += range.count
            } catch let error as CDReadError where error.kind == .mediaError {
                Self.logger.debug("Cache displacement read failed: \(error.message, privacy: .public)")
                return false
            } catch is RecoveryBudgetExhausted {
                return false
            }
        }
        guard let bound = features.cacheCapacitySectors else { return false }
        return bound == 0 || sectors > bound
    }

    static func interpolate(_ samples: inout [Int16], suspect: [Bool], preceding: [Int16]?) {
        for channel in 0..<2 {
            var index = channel
            while index < samples.count {
                if !suspect[index] { index += 2; continue }
                let first = index
                while index < samples.count && suspect[index] { index += 2 }
                let left = first >= 2 ? samples[first - 2] : preceding.map { $0[$0.count - 2 + channel] }
                let right: Int16? = index < samples.count ? samples[index] : nil
                let count = (index - first) / 2
                for offset in 0..<count {
                    let value: Int64
                    switch (left, right) {
                    case (.some(let a), .some(let b)):
                        value = Int64(a) + (Int64(b) - Int64(a)) * Int64(offset + 1) / Int64(count + 1)
                    case (.some(let a), .none): value = Int64(a)
                    case (.none, .some(let b)): value = Int64(b)
                    case (.none, .none): value = 0
                    }
                    samples[first + offset * 2] = Int16(value)
                }
            }
        }
    }
}

/// A bounded recovery window, not an ioctl timeout. Every retry also has an operation cap.
struct ReadRecoveryBudget {
    static let maximumOperations = 96
    let context: PCMReadContext
    let started: ContinuousClock.Instant
    var operations = 0

    init(context: PCMReadContext, started: ContinuousClock.Instant = .now) {
        self.context = context
        self.started = started
    }

    private var limit: Double {
        let available = max(0, Double(context.bufferedFrames) / Double(Disc.sampleRate) - 2)
        return context.buffering ? 2 : min(2, available)
    }

    private var seconds: Double {
        let elapsed = ContinuousClock.now - started
        let parts = elapsed.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func permitsRead(negotiatingC2: Bool = false) -> Bool {
        guard operations < Self.maximumOperations else { return false }
        // The first read and its one C2 negotiation are required for ordinary playback.
        return operations == 0 || seconds < limit || (negotiatingC2 && operations == 1 && seconds < 2)
    }

    func allows(sectors: Int, statistics: DiscReadStatistics, optional: Bool) -> Bool {
        guard operations < Self.maximumOperations, seconds < limit else { return false }
        let throughput = statistics.kilobytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        if optional && (context.buffering || throughput == nil) { return false }
        let estimate = throughput.map { Double(sectors * CDSectorBlock.audioBytes) / ($0 * 1_000) } ?? 0
        return estimate + 0.005 < limit - seconds
    }
}
