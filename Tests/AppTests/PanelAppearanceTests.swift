import AppKit
import CDKit
import SwiftUI
import XCTest

@MainActor
final class PanelAppearanceTests: XCTestCase {
    func testMenuSelectionAppliesImmediatelyAndPersistsWithoutChangingTransparency() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Liquid Glass needs macOS 26") }
        let suite = "CDPlayerUITests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: PanelAppearance.defaultsKey)
        defaults.set(50.0, forKey: PanelTransparency.defaultsKey)
        let setting = PanelAppearance(defaults: defaults)
        let transparency = PanelTransparency(defaults: defaults)
        let player = PlayerModel.offline()
        let window = PlayerWindow(
            player: player, transparency: transparency, panelStyle: .glass, panelAppearance: setting
        )
        defer { window.close() }
        let glass = try XCTUnwrap(window.contentView as? NSGlassEffectView)
        let application = NSApplication.shared
        let applicationAppearance = application.appearance
        let state = player.state
        let frame = window.frame
        XCTAssertEqual(window.appearance?.name, .darkAqua, "The saved selection must apply at creation")

        let menu = NSHostingMenu(rootView: PanelAppearanceCommands(appearance: setting))
        menu.update()
        let submenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(menu.items.first?.title, "Appearance")
        XCTAssertEqual(submenu.items.map(\.title), ["Follow System", "Light", "Dark"])
        XCTAssertEqual(submenu.items.map(\.state), [.off, .off, .on])

        let choices: [(String, PanelAppearance.Selection, NSAppearance.Name?)] = [
            ("Light", .light, .aqua), ("Dark", .dark, .darkAqua),
            ("Follow System", .system, nil)
        ]
        for (title, selection, name) in choices {
            let index = try XCTUnwrap(submenu.items.firstIndex { $0.title == title })
            XCTAssertTrue(submenu.items[index].isEnabled)
            submenu.performActionForItem(at: index)
            XCTAssertEqual(setting.selection, selection)
            XCTAssertEqual(window.appearance?.name, name)
            XCTAssertEqual(PanelAppearance(defaults: defaults).selection, selection)
            XCTAssertEqual(transparency.percentage, 50)
            XCTAssertEqual(PanelTransparency(defaults: defaults).percentage, 50)
            XCTAssertEqual(glass.tintColor?.resolved(for: window.effectiveAppearance).alphaComponent, 0.5)
            XCTAssertTrue(application.appearance === applicationAppearance)
            XCTAssertEqual(player.state, state)
            XCTAssertEqual(window.frame, frame)
            try await Task.sleep(for: .milliseconds(100))
            menu.update()
            XCTAssertEqual(submenu.items.map(\.state), submenu.items.map { $0.title == title ? .on : .off })
        }
        try await player.shutdown()
    }

    func testFollowSystemTracksAppearanceAndOverridesAreConfinedToGlassWindow() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Liquid Glass needs macOS 26") }
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        application.appearance = NSAppearance(named: .aqua)
        let setting = PanelAppearance()
        let player = PlayerModel.offline()
        let window = PlayerWindow(player: player, panelStyle: .glass, panelAppearance: setting)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        XCTAssertNil(window.appearance)
        let choices: [(PanelAppearance.Selection, NSAppearance.Name?)] = [
            (.dark, .darkAqua), (.light, .aqua), (.system, nil)
        ]
        for (selection, forcedName) in choices {
            setting.setSelection(selection)
            for inheritedName in [NSAppearance.Name.darkAqua, .aqua] {
                application.appearance = NSAppearance(named: inheritedName)
                XCTAssertEqual(window.appearance?.name, forcedName)
                XCTAssertEqual(window.effectiveAppearance.name, forcedName ?? inheritedName)
                XCTAssertEqual(window.contentView?.effectiveAppearance.name, forcedName ?? inheritedName)
                XCTAssertNil(other.appearance)
                XCTAssertEqual(other.effectiveAppearance.name, inheritedName)
                XCTAssertEqual(application.appearance?.name, inheritedName)
            }
        }
        try await player.shutdown()
    }

    func testClassicWindowIgnoresTheGlassAppearancePreference() async throws {
        let setting = PanelAppearance()
        setting.setSelection(.dark)
        let player = PlayerModel.offline()
        let window = PlayerWindow(player: player, panelStyle: .classic, panelAppearance: setting)
        defer { window.close() }
        for selection in PanelAppearance.Selection.allCases {
            setting.setSelection(selection)
            XCTAssertNil(window.appearance)
            XCTAssertTrue(window.contentView === window.hostingView)
            XCTAssertEqual(window.hostingView.rootView.panelStyle, .classic)
        }
        if #available(macOS 14.4, *) {
            if #unavailable(macOS 26) {
                let menu = NSHostingMenu(rootView: PanelAppearanceCommands(appearance: setting))
                menu.update()
                XCTAssertTrue(menu.items.isEmpty)
            }
        }
        try await player.shutdown()
    }
}
