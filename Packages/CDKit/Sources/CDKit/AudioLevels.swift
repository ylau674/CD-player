import CDAudioCore
import Foundation

public struct AudioLevelPeaks: Equatable, Sendable {
    public let leftPeak: UInt16
    public let rightPeak: UInt16

    public init(leftPeak: UInt16, rightPeak: UInt16) {
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
    }
}

public protocol AudioLevelSource: Sendable {
    func peaks(fromFrame: UInt64, throughFrame: UInt64) -> AudioLevelPeaks?
}

public final class CoreAudioLevelSource: AudioLevelSource, @unchecked Sendable {
    public static let shared = CoreAudioLevelSource()

    private let table: OpaquePointer?

    init() {
        table = cd_level_table_create()
    }

    deinit {
        if let table { cd_level_table_destroy(table) }
    }

    func playbackTable() throws -> OpaquePointer {
        guard let table else {
            throw AudioPlaybackError(CDError(
                result: CD_CORE_AUDIO_ERROR, message: "Cannot create the lock-free source audio level table."
            ))
        }
        return table
    }

    public func peaks(fromFrame: UInt64, throughFrame: UInt64) -> AudioLevelPeaks? {
        guard fromFrame <= throughFrame, let table else { return nil }
        let run = cd_level_table_current_run(table)
        guard run != 0 else { return nil }

        let slotFrames = UInt64(CD_LEVEL_SLOT_FRAMES)
        let firstSlot = fromFrame / slotFrames
        let lastSlot = throughFrame / slotFrames
        guard lastSlot - firstSlot < UInt64(CD_LEVEL_SLOT_COUNT) else { return nil }

        var result = AudioLevelPeaks(leftPeak: 0, rightPeak: 0)
        var found = false
        for slot in firstSlot...lastSlot {
            var peaks = CDLevelPeaks()
            guard cd_level_table_read(table, run, slot * slotFrames, &peaks) else { continue }
            result = AudioLevelPeaks(
                leftPeak: max(result.leftPeak, peaks.leftPeak),
                rightPeak: max(result.rightPeak, peaks.rightPeak)
            )
            found = true
        }
        guard found, cd_level_table_current_run(table) == run else { return nil }
        return result
    }
}

public struct AudioLevelMeter: Sendable {
    public enum SegmentState: Equatable, Sendable {
        case unlit, lit, peakHold
    }

    public struct ChannelReading: Equatable, Sendable {
        public let decibels: Double?
        public let litSegments: Int
        /// Counted like `litSegments`. Nil while the held peak is below the bar's top segment, as when a
        /// hold restarts from a quieter block while the bar is still falling, so a hold never shows inside the bar.
        public let peakHoldSegment: Int?

        /// Segments count from zero at -40 dB. A hold level with the bar's top shows on that top segment.
        public func state(ofSegment segment: Int) -> SegmentState {
            if segment + 1 == peakHoldSegment { return .peakHold }
            return segment < litSegments ? .lit : .unlit
        }

        func drawsSameSegments(as other: ChannelReading) -> Bool {
            litSegments == other.litSegments && peakHoldSegment == other.peakHoldSegment
        }
    }

    public struct Reading: Equatable, Sendable {
        public let left: ChannelReading
        public let right: ChannelReading

        public var isDark: Bool {
            left.litSegments == 0 && right.litSegments == 0 &&
                left.peakHoldSegment == nil && right.peakHoldSegment == nil
        }

        /// The exact level changes on almost every read while a bar falls; only the segments change the drawing.
        public func drawsSameSegments(as other: Reading) -> Bool {
            left.drawsSameSegments(as: other.left) && right.drawsSameSegments(as: other.right)
        }
    }

    public static let segmentThresholds: [Double] = [
        -40, -36, -32, -28, -24, -20, -18, -16, -14, -12,
        -10, -8, -6, -5, -4, -3, -2, -1, -0.5, 0
    ]

    private struct ChannelState: Sendable {
        var decibels: Double?
        var peakHoldDecibels: Double?
        var peakHoldSince: ContinuousClock.Instant?
    }

    private var left = ChannelState()
    private var right = ChannelState()
    private var lastUpdate: ContinuousClock.Instant?
    private let clock: @Sendable () -> ContinuousClock.Instant

    public init(clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.clock = clock
    }

    public var reading: Reading {
        Reading(left: reading(for: left), right: reading(for: right))
    }

    public mutating func update(with peaks: AudioLevelPeaks?) {
        let now = clock()
        let elapsed = lastUpdate.map { audioLevelElapsedSeconds(from: $0, to: now) } ?? 0
        Self.update(&left, with: peaks?.leftPeak, elapsed: elapsed, now: now)
        Self.update(&right, with: peaks?.rightPeak, elapsed: elapsed, now: now)
        lastUpdate = now
    }

    public mutating func reset() {
        left = ChannelState()
        right = ChannelState()
        lastUpdate = clock()
    }

    public static func decibels(for peak: UInt16) -> Double? {
        guard peak > 0 else { return nil }
        if peak >= UInt16(Int16.max) { return 0 }
        return 20 * log10(Double(peak) / 32_768)
    }

    public static func segmentCount(for decibels: Double?) -> Int {
        guard let decibels, decibels.isFinite else { return 0 }
        return segmentThresholds.prefix { decibels >= $0 }.count
    }

    private func reading(for state: ChannelState) -> ChannelReading {
        let segmentCount = Self.segmentCount(for: state.decibels)
        let holdSegment = state.peakHoldDecibels.map {
            Self.segmentCount(for: $0)
        }.flatMap { $0 > 0 && $0 >= segmentCount ? $0 : nil }
        return ChannelReading(
            decibels: state.decibels,
            litSegments: segmentCount,
            peakHoldSegment: holdSegment
        )
    }

    private static func update(
        _ state: inout ChannelState, with peak: UInt16?, elapsed: Double, now: ContinuousClock.Instant
    ) {
        let fall = max(0, elapsed) * 20 / 1.7
        if let current = state.decibels {
            let next = current - fall
            state.decibels = next < -60 ? nil : next
        }

        if let heldSince = state.peakHoldSince,
           audioLevelElapsedSeconds(from: heldSince, to: now) >= 1.5 {
            state.peakHoldDecibels = nil
            state.peakHoldSince = nil
        }

        guard let sample = peak.flatMap(Self.decibels(for:)) else { return }
        if let level = state.decibels {
            if sample > level { state.decibels = sample }
        } else {
            state.decibels = sample
        }
        if let held = state.peakHoldDecibels, sample <= held { return }
        state.peakHoldDecibels = sample
        state.peakHoldSince = now
    }
}

func audioLevelElapsedSeconds(
    from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}
