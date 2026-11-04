import Combine
import Foundation
import OSLog

@MainActor
public final class PanelTransparency: ObservableObject {
    public static let defaultPercentage = 70.0
    public static let range = 0.0...90.0
    public static let defaultsKey = "BackgroundTransparency"

    @Published public private(set) var percentage: Double
    private let defaults: UserDefaults?
    private static let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Appearance")

    /// Without a defaults store the setting stays in memory, for offline views and tests.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let stored = defaults?.object(forKey: Self.defaultsKey) else {
            percentage = Self.defaultPercentage
            return
        }
        guard let value = stored as? Double, value.isFinite, Self.range.contains(value) else {
            Self.logger.error("Invalid saved background transparency; restoring the default")
            percentage = Self.defaultPercentage
            defaults?.set(percentage, forKey: Self.defaultsKey)
            return
        }
        percentage = value.rounded()
    }

    public func setPercentage(_ value: Double) {
        guard value.isFinite, Self.range.contains(value) else {
            Self.logger.error("Background transparency must be between 0 and 90 percent")
            return
        }
        let rounded = value.rounded()
        guard percentage != rounded else { return }
        percentage = rounded
        defaults?.set(rounded, forKey: Self.defaultsKey)
    }

    public func opacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : 1 - percentage / 100
    }
}
