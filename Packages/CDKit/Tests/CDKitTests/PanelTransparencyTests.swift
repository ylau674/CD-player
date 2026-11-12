import Foundation
import Testing
@testable import CDKit

@Test @MainActor func panelTransparencyDefaultsTo15AndPersists() throws {
    let suite = "CDKitTests.Transparency.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let setting = PanelTransparency(defaults: defaults)
    #expect(setting.percentage == 15)
    #expect(abs(setting.opacity(reduceTransparency: false) - 0.85) < 0.001)
    for value in [0.0, 35, 70, 90] {
        setting.setPercentage(value)
        #expect(PanelTransparency(defaults: defaults).percentage == value)
        #expect(abs(setting.opacity(reduceTransparency: false) - (1 - value / 100)) < 0.001)
        #expect(setting.opacity(reduceTransparency: true) == 1)
        #expect(setting.percentage == value)
    }
}

@Test @MainActor func panelTransparencyPreservesExistingPreference() throws {
    let suite = "CDKitTests.Transparency.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(70.0, forKey: PanelTransparency.defaultsKey)
    #expect(PanelTransparency(defaults: defaults).percentage == 70)
}

@Test @MainActor func panelTransparencyRejectsInvalidChangesAndRoundsPercentages() {
    let setting = PanelTransparency()
    setting.setPercentage(42.6)
    #expect(setting.percentage == 43)
    for invalid in [-1.0, 91, .nan, .infinity, -.infinity] {
        setting.setPercentage(invalid)
        #expect(setting.percentage == 43)
    }
}

@Test @MainActor func panelTransparencyRepairsInvalidPreferences() throws {
    let suite = "CDKitTests.Transparency.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for invalid: Any in [-10.0, 100.0, "invalid"] {
        defaults.set(invalid, forKey: PanelTransparency.defaultsKey)
        #expect(PanelTransparency(defaults: defaults).percentage == 15)
        #expect(defaults.double(forKey: PanelTransparency.defaultsKey) == 15)
    }
}
