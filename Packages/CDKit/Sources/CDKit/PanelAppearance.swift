import Combine
import Foundation
import OSLog

@MainActor
public final class PanelAppearance: ObservableObject {
    public enum Selection: String, CaseIterable, Sendable {
        case system
        case light
        case dark
    }

    public static let defaultsKey = "PanelAppearance"

    @Published public private(set) var selection: Selection
    private let defaults: UserDefaults?
    private static let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Appearance")

    /// Without a defaults store the setting stays in memory, for offline views and tests.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let stored = defaults?.object(forKey: Self.defaultsKey) else {
            selection = .system
            return
        }
        guard let value = stored as? String, let selection = Selection(rawValue: value) else {
            Self.logger.error("Invalid saved panel appearance; restoring Follow System")
            selection = .system
            defaults?.set(selection.rawValue, forKey: Self.defaultsKey)
            return
        }
        self.selection = selection
    }

    public func setSelection(_ selection: Selection) {
        guard self.selection != selection else { return }
        self.selection = selection
        defaults?.set(selection.rawValue, forKey: Self.defaultsKey)
    }
}
