/// Places row 2's status, output name and menu indicator. The status stays at the left and the
/// indicator at the right; neither ever moves. The name is shown in a space just left of the
/// indicator, no wider than `maximumNameWidth` and never overlapping the status. When the name
/// fits there it keeps still; otherwise only the name moves: it scrolls within that space or,
/// with Reduce Motion, keeps still, truncated in the middle. Widths come from `measure`, so the
/// rules work without a font.
public struct OutputLineLayout: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case fitted
        case scrolling
        case truncated
    }

    /// The least space between the status and the name.
    public static let gap = 12.0
    /// The menu indicator after the name. Its leading space keeps the name off the indicator.
    public static let indicator = " ▾"
    /// The space after the name before it starts again.
    public static let loopGap = 60.0
    /// Points per second.
    public static let speed = 24.0
    /// Seconds the name rests at its start before each pass.
    public static let pause = 2.0
    /// The fewest name characters kept, besides the ellipsis, before the status gives way.
    public static let minimumNameCharacters = 6

    public let mode: Mode
    /// The status, ending in an ellipsis only when it would leave too little room for the name.
    public let status: String
    public let statusWidth: Double
    /// The name without the indicator, truncated in `.truncated` mode.
    public let name: String
    public let nameWidth: Double
    /// Where the name's space starts. The name rests there and, when scrolling, moves within the
    /// space up to `indicatorX`.
    public let nameX: Double
    public let indicatorX: Double
    public let indicatorWidth: Double
    /// The distance from the name to its repeated copy; 0 unless scrolling.
    public let cycle: Double

    /// The width of the space the name is shown in.
    public var nameSpaceWidth: Double { indicatorX - nameX }
    /// The output selector's extent, the name's space and the indicator, from `nameX`.
    public var selectorWidth: Double { indicatorX + indicatorWidth - nameX }
    /// One pass: the rest at the start, then the move by `cycle`.
    public var duration: Double { mode == .scrolling ? Self.pause + cycle / Self.speed : 0 }

    public init(
        status: String, name: String, width: Double, maximumNameWidth: Double = .infinity, reduceMotion: Bool,
        measure: (String) -> Double
    ) {
        let statusWidth = measure(status)
        let nameWidth = measure(name)
        let indicatorWidth = measure(Self.indicator)
        let nameEnd = width - indicatorWidth
        let nameLimit = max(maximumNameWidth, 0)
        // Before the first layout there is no width to fit; nothing scrolls until there is.
        if width <= 0 || (statusWidth + Self.gap + nameWidth <= nameEnd && nameWidth <= nameLimit) {
            let indicatorX = max(nameEnd, statusWidth + Self.gap + nameWidth)
            self.init(mode: .fitted, status: status, statusWidth: statusWidth, name: name, nameWidth: nameWidth,
                      nameX: indicatorX - nameWidth, indicatorX: indicatorX, indicatorWidth: indicatorWidth)
            return
        }
        // The status stays whole unless that would leave less than the shortest truncated name.
        let shortestName = min(
            nameWidth, nameLimit, measure(Self.middleTruncated(name, keeping: Self.minimumNameCharacters))
        )
        let statusBudget = nameEnd - Self.gap - shortestName
        let shownStatus = statusWidth <= statusBudget ? status : Self.fit(
            status, within: statusBudget, measure: measure
        ) { status, count in String(status.prefix(count)) + "…" }
        let shownStatusWidth = measure(shownStatus)
        let space = min(nameEnd - shownStatusWidth - Self.gap, nameLimit)
        if nameWidth <= space {
            self.init(mode: .fitted, status: shownStatus, statusWidth: shownStatusWidth, name: name,
                      nameWidth: nameWidth, nameX: nameEnd - nameWidth, indicatorX: nameEnd,
                      indicatorWidth: indicatorWidth)
        } else if !reduceMotion {
            self.init(mode: .scrolling, status: shownStatus, statusWidth: shownStatusWidth, name: name,
                      nameWidth: nameWidth, nameX: nameEnd - space, indicatorX: nameEnd,
                      indicatorWidth: indicatorWidth, cycle: nameWidth + Self.loopGap)
        } else {
            let truncatedName = Self.fit(name, within: space, measure: measure) { name, count in
                Self.middleTruncated(name, keeping: count)
            }
            let truncatedWidth = measure(truncatedName)
            self.init(mode: .truncated, status: shownStatus, statusWidth: shownStatusWidth, name: truncatedName,
                      nameWidth: truncatedWidth, nameX: nameEnd - truncatedWidth, indicatorX: nameEnd,
                      indicatorWidth: indicatorWidth)
        }
    }

    private init(
        mode: Mode, status: String, statusWidth: Double, name: String, nameWidth: Double, nameX: Double,
        indicatorX: Double, indicatorWidth: Double, cycle: Double = 0
    ) {
        self.mode = mode
        self.status = status
        self.statusWidth = statusWidth
        self.name = name
        self.nameWidth = nameWidth
        self.nameX = nameX
        self.indicatorX = indicatorX
        self.indicatorWidth = indicatorWidth
        self.cycle = cycle
    }

    /// Whether `other` moves the same name the same way, so a pass under way can carry on.
    public func scrollsLike(_ other: OutputLineLayout) -> Bool {
        mode == .scrolling && other.mode == .scrolling && name == other.name && cycle == other.cycle
    }

    /// How far the name has moved left, `time` seconds into a pass.
    public func offset(at time: Double) -> Double {
        guard mode == .scrolling, duration > 0 else { return 0 }
        let time = max(time, 0).truncatingRemainder(dividingBy: duration)
        return time <= Self.pause ? 0 : (time - Self.pause) * Self.speed
    }

    /// The longest `shorten(text, count)` that fits, trying fewer characters until one does.
    private static func fit(
        _ text: String, within width: Double, measure: (String) -> Double,
        shorten: (String, Int) -> String
    ) -> String {
        var count = text.count
        while count > 0 {
            let candidate = shorten(text, count)
            if measure(candidate) <= width { return candidate }
            count -= 1
        }
        return shorten(text, 0)
    }

    /// The first and last characters of `text` around an ellipsis, `count` in all.
    private static func middleTruncated(_ text: String, keeping count: Int) -> String {
        guard count < text.count else { return text }
        let head = (count + 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(count - head))
    }
}
