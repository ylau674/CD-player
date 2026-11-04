import Foundation

@MainActor
public protocol HDCDDecodePreferenceStore {
    var isEnabled: Bool { get }
    func save(isEnabled: Bool)
}

@MainActor
public final class UserDefaultsHDCDDecodePreferenceStore: HDCDDecodePreferenceStore {
    public static let key = "DecodeHDCD"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    public func save(isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Self.key)
    }
}
