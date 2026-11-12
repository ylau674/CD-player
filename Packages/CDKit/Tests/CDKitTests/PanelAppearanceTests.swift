import Combine
import Foundation
import Testing
@testable import CDKit

@Test @MainActor func panelAppearanceDefaultsToSystemAndPersists() throws {
    let suite = "CDKitTests.Appearance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(50.0, forKey: PanelTransparency.defaultsKey)
    let setting = PanelAppearance(defaults: defaults)
    #expect(setting.selection == .system)
    #expect(defaults.object(forKey: PanelAppearance.defaultsKey) == nil)
    for selection in [PanelAppearance.Selection.dark, .light, .system] {
        setting.setSelection(selection)
        #expect(setting.selection == selection)
        #expect(defaults.string(forKey: PanelAppearance.defaultsKey) == selection.rawValue)
        #expect(PanelAppearance(defaults: defaults).selection == selection)
        #expect(PanelTransparency(defaults: defaults).percentage == 50)
    }
}

@Test @MainActor func panelAppearanceRepairsInvalidPreferences() throws {
    let suite = "CDKitTests.Appearance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for invalid: Any in ["sepia", "", 1, true, ["dark"]] {
        defaults.set(invalid, forKey: PanelAppearance.defaultsKey)
        #expect(PanelAppearance(defaults: defaults).selection == .system)
        #expect(defaults.string(forKey: PanelAppearance.defaultsKey) == "system")
    }
}

@Test @MainActor func panelAppearanceOnlyPublishesChanges() {
    let setting = PanelAppearance()
    var selections: [PanelAppearance.Selection] = []
    let subscription = setting.$selection.sink { selections.append($0) }
    defer { subscription.cancel() }
    for selection in [PanelAppearance.Selection.system, .dark, .dark, .light, .light, .system] {
        setting.setSelection(selection)
    }
    #expect(selections == [.system, .dark, .light, .system])
}
