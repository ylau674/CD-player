import AppKit
import CDKit
import Combine
import SwiftUI
import XCTest

@MainActor
final class PanelTransparencyMenuTests: XCTestCase {
    func testSliderActionsPersistAndAccessibilityOverridePreservesSelection() throws {
        let suite = "CDPlayerUITests.Transparency.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = PanelTransparency(defaults: defaults)
        let probe = TransparencyAccessibilityProbe()
        let view = PanelTransparencyMenuView(transparency: setting, reduceTransparency: { probe.reduced })
        XCTAssertEqual(view.slider.minValue, 0)
        XCTAssertEqual(view.slider.maxValue, 90)
        XCTAssertTrue(view.slider.isContinuous)
        XCTAssertEqual(view.slider.accessibilityLabel(), "Background Transparency")

        for value in [0.0, 35, 70, 90] {
            view.slider.doubleValue = value
            XCTAssertTrue(view.slider.sendAction(view.slider.action, to: view.slider.target))
            XCTAssertEqual(setting.percentage, value)
            XCTAssertEqual(view.valueLabel.stringValue, "\(Int(value))% transparent")
            XCTAssertEqual(view.slider.accessibilityValueDescription(), "\(Int(value)) percent transparent")
            XCTAssertEqual(PanelTransparency(defaults: defaults).percentage, value)
        }

        probe.reduced = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        XCTAssertFalse(view.slider.isEnabled)
        XCTAssertTrue(view.overrideLabel.stringValue.contains("background is solid"))
        XCTAssertEqual(setting.percentage, 90)
        probe.reduced = false
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        XCTAssertTrue(view.slider.isEnabled)
        XCTAssertEqual(view.slider.doubleValue, 90)
    }

    func testSwiftUIMenuContainsWorkingSliderAndTintsTheGlassWhileTracking() throws {
        let setting = PanelTransparency()
        let controller = PanelTransparencyMenuController(transparency: setting)
        let hosting = NSHostingMenu(rootView: PanelTransparencyCommands(transparency: setting))
        hosting.update()
        let submenu = try XCTUnwrap(hosting.items.first?.submenu)
        XCTAssertEqual(submenu.title, "Background Transparency")
        XCTAssertNil(controller.sliderItem.view, "The slider view should be created only when the submenu first opens")
        XCTAssertEqual(submenu.items.map(\.title), ["Reset to 15%"])
        let player = PlayerModel.offline()
        addTeardownBlock { @MainActor in try await player.shutdown() }
        let window = PlayerWindow(player: player, transparency: setting)
        window.center()
        window.orderFrontRegardless()
        defer { window.close() }
        let glass = try XCTUnwrap(window.contentView as? NSGlassEffectView)
        let host = window.hostingView
        for value in [0.0, 90] {
            var examined = false
            var adjusted = false
            let probe = TransparencyMenuTrackingProbe {
                if !adjusted {
                    let views = submenu.items.compactMap { $0.view as? PanelTransparencyMenuView }
                    XCTAssertEqual(views.count, 1)
                    guard let view = views.first else { submenu.cancelTracking(); return }
                    XCTAssertNotNil(controller.sliderItem.view)
                    XCTAssertNotNil(view.window, "The slider must be hosted in the actual open menu")
                    XCTAssertEqual(view.slider.doubleValue, setting.percentage)
                    XCTAssertTrue(view.slider.isEnabled)
                    for _ in 0..<100 where view.slider.doubleValue != value {
                        let previous = view.slider.doubleValue
                        _ = value == 90
                            ? view.slider.accessibilityPerformIncrement()
                            : view.slider.accessibilityPerformDecrement()
                        XCTAssertNotEqual(view.slider.doubleValue, previous)
                    }
                    XCTAssertEqual(setting.percentage, value)
                    XCTAssertEqual(view.valueLabel.stringValue, "\(Int(value))% transparent")
                    adjusted = true
                } else {
                    defer { submenu.cancelTracking() }
                    let tint = glass.tintColor?.resolved(for: window.effectiveAppearance)
                    XCTAssertEqual(tint?.alphaComponent ?? -1, 1 - value / 100, accuracy: 0.001)
                    examined = true
                }
            }
            let timer = Timer(timeInterval: 0.15, target: probe, selector: #selector(probe.check),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .eventTracking)
            submenu.popUp(positioning: nil, at: NSPoint(x: 20, y: 80), in: host)
            timer.invalidate()
            XCTAssertTrue(examined)
        }
        XCTAssertEqual(setting.percentage, 90)
        let reset = try XCTUnwrap(submenu.items.firstIndex(where: { $0.title == "Reset to 15%" }))
        submenu.performActionForItem(at: reset)
        XCTAssertEqual(setting.percentage, 15)
        XCTAssertEqual(submenu.items.compactMap { $0.view as? PanelTransparencyMenuView }.count, 1)
        let replacement = NSMenu(title: PanelTransparencyCommands.title)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: replacement)
        XCTAssertEqual(replacement.items.compactMap { $0.view as? PanelTransparencyMenuView }.count, 1)
        withExtendedLifetime(controller) {}
    }

    func testSliderSurvivesSwiftUIRefillingOrReplacingTheSubmenu() throws {
        let titles = ["Reset to 15%"]
        let mainMenu = NSMenu(title: "Main")
        let viewMenu = NSMenu(title: "View")
        mainMenu.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu
        let parent = viewMenu.addItem(withTitle: PanelTransparencyCommands.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: PanelTransparencyCommands.title)
        for title in titles { submenu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        parent.submenu = submenu
        let playback = NSMenu(title: "Playback")
        mainMenu.addItem(withTitle: "Playback", action: nil, keyEquivalent: "").submenu = playback

        let controller = PanelTransparencyMenuController(transparency: PanelTransparency())
        defer { withExtendedLifetime(controller) {} }
        func assertInstalled(_ menu: NSMenu, after expected: [String], line: UInt = #line) {
            XCTAssertEqual(menu.items.dropLast(2).map(\.title), expected, line: line)
            XCTAssertEqual(menu.items.dropLast().last?.isSeparatorItem, true, line: line)
            XCTAssertTrue(menu.items.last === controller.sliderItem, line: line)
            XCTAssertTrue(controller.sliderItem.view is PanelTransparencyMenuView, line: line)
        }
        XCTAssertEqual(submenu.items.count, 1, "Menus built before launch wait for the menu bar")
        XCTAssertNil(controller.sliderItem.view, "The slider view should stay unallocated until the menu opens")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: mainMenu)
        XCTAssertNotNil(controller.sliderItem.view)
        assertInstalled(submenu, after: titles)

        // SwiftUI empties and refills the submenu the first time the View menu opens.
        submenu.removeAllItems()
        for (index, title) in titles.enumerated() {
            submenu.insertItem(withTitle: title, action: nil, keyEquivalent: "", at: index)
        }
        assertInstalled(submenu, after: titles)
        submenu.removeAllItems()
        for title in titles { submenu.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        assertInstalled(submenu, after: titles)
        submenu.removeItem(at: 0)
        submenu.insertItem(withTitle: "Reset to 15%", action: nil, keyEquivalent: "", at: 0)
        assertInstalled(submenu, after: titles)

        // A replacement submenu takes the one slider, whether it is filled before or after attaching.
        let replacement = NSMenu(title: PanelTransparencyCommands.title)
        replacement.addItem(withTitle: "Reset to 15%", action: nil, keyEquivalent: "")
        assertInstalled(replacement, after: ["Reset to 15%"])
        XCTAssertFalse(submenu.items.contains(controller.sliderItem))
        let prefilled = NSMenu(title: "Pending")
        prefilled.addItem(withTitle: "Reset to 15%", action: nil, keyEquivalent: "")
        prefilled.title = PanelTransparencyCommands.title
        parent.submenu = prefilled
        viewMenu.itemChanged(parent)
        assertInstalled(prefilled, after: ["Reset to 15%"])
        XCTAssertFalse(replacement.items.contains(controller.sliderItem))

        playback.addItem(withTitle: "Play", action: nil, keyEquivalent: "")
        XCTAssertEqual(playback.items.map(\.title), ["Play"])
    }

    func testSliderDragReleasedOutsideOpenMenuEndsAndNextDragStillWorks() throws {
        let setting = PanelTransparency()
        var seen: [Double] = []
        let subscription = setting.$percentage.dropFirst().sink { seen.append($0) }
        defer { subscription.cancel() }
        let controller = PanelTransparencyMenuController(transparency: setting)
        defer { withExtendedLifetime(controller) {} }
        let menu = NSMenu(title: PanelTransparencyCommands.title)
        menu.addItem(withTitle: "Reset to 15%", action: nil, keyEquivalent: "")
        XCTAssertNil(controller.sliderItem.view)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertTrue(menu.items.last === controller.sliderItem)
        let view = try XCTUnwrap(controller.sliderItem.view as? PanelTransparencyMenuView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        defer { window.close() }

        var step = 0
        var finished = false
        let probe = TransparencyMenuTrackingProbe {
            guard let menuWindow = view.window else { return }
            step += 1
            guard step < 5 else { menu.cancelTracking(); return }
            let slider = view.slider
            let outside = NSPoint(x: menuWindow.frame.width + 80, y: slider.convert(NSPoint.zero, to: nil).y + 40)
            switch step {
            case 1:
                let knob = slider.convert(Self.location(of: slider.doubleValue, in: slider), to: nil)
                let content = menuWindow.contentView
                XCTAssertTrue(content?.hitTest(content?.superview?.convert(knob, from: nil) ?? knob) === slider,
                              "Mouse events on the knob must reach the slider itself")
                Self.post(.leftMouseDown, at: 30, on: slider)
                Self.post(.leftMouseDragged, at: 60, on: slider)
                Self.post(.leftMouseDragged, windowPoint: NSPoint(x: outside.x, y: slider.convert(NSPoint.zero, to: nil).y), on: slider)
                Self.post(.leftMouseUp, windowPoint: outside, on: slider)
            case 2:
                XCTAssertEqual(seen, [30, 60, 90])
                Self.post(.leftMouseDown, at: 90, on: slider)
                Self.post(.leftMouseDragged, at: 50, on: slider)
                Self.post(.leftMouseUp, at: 25, on: slider)
            case 3:
                XCTAssertEqual(seen, [30, 60, 90, 50, 25])
                XCTAssertEqual(view.valueLabel.stringValue, "25% transparent")
                finished = true
                menu.cancelTracking()
            default:
                menu.cancelTracking()
            }
        }
        let timer = Timer(timeInterval: 0.25, target: probe, selector: #selector(probe.check), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 80), in: host)
        timer.invalidate()
        XCTAssertTrue(finished)
        XCTAssertEqual(setting.percentage, 25)
    }

    func testMenuSliderMapsPointerToRenderedKnobKeepsGrabAndIgnoresInputWhenDisabled() throws {
        let slider = MenuTrackingSlider(value: 0, minValue: 0, maxValue: 90, target: nil, action: nil)
        slider.frame = NSRect(x: 16, y: 35, width: 248, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 92))
        container.addSubview(slider)
        for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            slider.userInterfaceLayoutDirection = direction
            for value in [0.0, 20, 45, 90] {
                slider.doubleValue = value
                let knob = try XCTUnwrap(slider.cell as? NSSliderCell).knobRect(flipped: slider.isFlipped)
                XCTAssertEqual(slider.value(atX: knob.midX), value, accuracy: 0.5, "\(direction) \(value)")
                XCTAssertEqual(slider.x(forValue: value), knob.midX, accuracy: 1, "\(direction) \(value)")
            }
            let low = direction == .leftToRight ? -50.0 : 400
            XCTAssertEqual(slider.value(atX: low), 0)
            XCTAssertEqual(slider.value(atX: direction == .leftToRight ? 400 : -50), 90)
        }
        slider.userInterfaceLayoutDirection = .leftToRight
        XCTAssertTrue(container.hitTest(NSPoint(x: 140, y: 47)) === slider)
        XCTAssertTrue(container.hitTest(NSPoint(x: 140, y: 80)) === container)
        slider.isHidden = true
        XCTAssertTrue(container.hitTest(NSPoint(x: 140, y: 47)) === container)
        slider.isHidden = false

        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let target = TransparencySliderTarget()
        slider.target = target
        slider.action = #selector(TransparencySliderTarget.changed(_:))
        slider.doubleValue = 70
        slider.isEnabled = false
        let pending = Self.event(.leftMouseUp, windowPoint: slider.convert(Self.location(of: 10, in: slider), to: nil), on: slider)
        NSApp.postEvent(pending, atStart: false)
        slider.mouseDown(with: Self.event(.leftMouseDown, windowPoint: pending.locationInWindow, on: slider))
        XCTAssertEqual(slider.doubleValue, 70)
        XCTAssertEqual(target.values, [])
        slider.isEnabled = true
        slider.mouseDown(with: Self.event(.leftMouseDown, windowPoint: slider.convert(Self.location(of: 40, in: slider), to: nil), on: slider))
        XCTAssertEqual(target.values.map { $0.rounded() }, [40, 10])
        XCTAssertNil(NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .now, inMode: .default, dequeue: true))

        // Pressing off-centre on the knob keeps the value until the pointer moves.
        target.values = []
        slider.doubleValue = 45
        let grab = NSPoint(x: slider.x(forValue: 45) + slider.knobThickness / 4, y: slider.bounds.midY)
        let moved = NSPoint(x: grab.x + (slider.bounds.width - slider.knobThickness) / 9, y: grab.y)
        NSApp.postEvent(Self.event(.leftMouseUp, windowPoint: slider.convert(moved, to: nil), on: slider), atStart: false)
        slider.mouseDown(with: Self.event(.leftMouseDown, windowPoint: slider.convert(grab, to: nil), on: slider))
        XCTAssertEqual(target.values.map { $0.rounded() }, [55])
    }

    private static func location(of value: Double, in slider: NSSlider) -> NSPoint {
        let inset = slider.knobThickness / 2
        return NSPoint(x: inset + (slider.bounds.width - inset * 2) * CGFloat(value / slider.maxValue), y: slider.bounds.midY)
    }

    private static func event(_ type: NSEvent.EventType, windowPoint: NSPoint, on view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private static func post(_ type: NSEvent.EventType, at value: Double, on slider: NSSlider) {
        post(type, windowPoint: slider.convert(location(of: value, in: slider), to: nil), on: slider)
    }

    private static func post(_ type: NSEvent.EventType, windowPoint: NSPoint, on view: NSView) {
        NSApp.postEvent(event(type, windowPoint: windowPoint, on: view), atStart: false)
    }
}

@MainActor private final class TransparencyAccessibilityProbe {
    var reduced = false
}

@MainActor private final class TransparencySliderTarget: NSObject {
    var values: [Double] = []
    @objc func changed(_ sender: NSSlider) { values.append(sender.doubleValue) }
}

@MainActor private final class TransparencyMenuTrackingProbe: NSObject {
    let action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func check() { action() }
}
