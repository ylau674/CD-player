import AppKit
import CDKit
import Combine
import SwiftUI

struct PanelTransparencyCommands: View {
    static let title = "Background Transparency"
    let transparency: PanelTransparency
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Menu(Self.title) {
            Button("Reset to 70%") {
                transparency.setPercentage(PanelTransparency.defaultPercentage)
            }
            .disabled(reduceTransparency)
        }
    }
}

/// SwiftUI command menus do not host sliders on all supported macOS releases, so the
/// slider is an AppKit item appended to SwiftUI's submenu. SwiftUI empties and refills
/// that submenu the first time the View menu opens, so the item is re-placed after every
/// item change rather than once when tracking begins. It stays after SwiftUI's own items
/// so SwiftUI's index-based updates never land on it.
@MainActor
final class PanelTransparencyMenuController: NSObject {
    let sliderItem: NSMenuItem
    private let separator = NSMenuItem.separator()
    private let transparency: PanelTransparency
    private var isPlacing = false

    init(transparency: PanelTransparency) {
        self.transparency = transparency
        sliderItem = NSMenuItem(title: PanelTransparencyCommands.title, action: nil, keyEquivalent: "")
        super.init()
        let names = [
            NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification,
            NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func menuChanged(_ notification: Notification) {
        guard !isPlacing, let menu = notification.object as? NSMenu else { return }
        if notification.name == NSMenu.didBeginTrackingNotification {
            install(in: menu)
        } else if menu.title == PanelTransparencyCommands.title {
            place(in: menu)
        } else if notification.name == NSMenu.didChangeItemNotification,
                  let index = notification.userInfo?["NSMenuItemIndex"] as? Int,
                  index >= 0, index < menu.numberOfItems,
                  let submenu = menu.item(at: index)?.submenu, submenu.title == PanelTransparencyCommands.title {
            place(in: submenu)
        }
    }

    func install(in menu: NSMenu) {
        if menu.title == PanelTransparencyCommands.title {
            if sliderItem.view == nil {
                sliderItem.view = PanelTransparencyMenuView(transparency: transparency)
            }
            place(in: menu)
        } else {
            for item in menu.items where item !== sliderItem {
                if let submenu = item.submenu { install(in: submenu) }
            }
        }
    }

    private func place(in menu: NSMenu) {
        guard sliderItem.view != nil else { return }
        let count = menu.numberOfItems
        if count >= 2, menu.item(at: count - 2) === separator, menu.item(at: count - 1) === sliderItem { return }
        isPlacing = true
        defer { isPlacing = false }
        for item in [separator, sliderItem] { item.menu?.removeItem(item) }
        menu.addItem(separator)
        menu.addItem(sliderItem)
    }
}

/// Recent macOS releases route NSSlider mouse events to an internal SwiftUI view whose
/// gesture stays pressed after a release outside a menu, so the slider stops responding.
/// Tracking the drag here, as classic NSSliderCell did, always ends at mouse-up.
@MainActor
final class MenuTrackingSlider: NSSlider {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let start = convert(event.locationInWindow, from: nil).x
        let centre = x(forValue: doubleValue)
        // A press on the knob keeps its grab point, so the knob does not jump to centre.
        let offset = abs(start - centre) <= knobThickness / 2 ? start - centre : 0
        track(event, offset: offset)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            track(next, offset: offset)
            if next.type == .leftMouseUp { break }
        }
    }

    func value(atX x: CGFloat) -> Double {
        var fraction = min(max((x - trackInset) / trackWidth, 0), 1)
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        return minValue + Double(fraction) * (maxValue - minValue)
    }

    func x(forValue value: Double) -> CGFloat {
        var fraction = maxValue > minValue ? CGFloat((value - minValue) / (maxValue - minValue)) : 0
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        return trackInset + fraction * trackWidth
    }

    private var trackInset: CGFloat { min(knobThickness / 2, bounds.width / 2) }
    private var trackWidth: CGFloat { max(bounds.width - trackInset * 2, 1) }

    private func track(_ event: NSEvent, offset: CGFloat) {
        let value = value(atX: convert(event.locationInWindow, from: nil).x - offset)
        guard value != doubleValue else { return }
        doubleValue = value
        sendAction(action, to: target)
    }
}

@MainActor
final class PanelTransparencyMenuView: NSView {
    let slider = MenuTrackingSlider(value: 70, minValue: 0, maxValue: 90, target: nil, action: nil)
    let valueLabel = NSTextField(labelWithString: "")
    let overrideLabel = NSTextField(labelWithString: "")
    private let transparency: PanelTransparency
    private let reduceTransparency: @MainActor () -> Bool
    private var subscription: AnyCancellable?

    init(
        transparency: PanelTransparency,
        reduceTransparency: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    ) {
        self.transparency = transparency
        self.reduceTransparency = reduceTransparency
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 92))
        autoresizingMask = [.width]
        valueLabel.frame = NSRect(x: 16, y: 65, width: 248, height: 18)
        valueLabel.font = .menuFont(ofSize: 13)
        slider.frame = NSRect(x: 16, y: 35, width: 248, height: 24)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.setAccessibilityLabel(PanelTransparencyCommands.title)
        slider.toolTip = "0% is solid; 90% is mostly transparent. Text and controls stay solid."
        overrideLabel.frame = NSRect(x: 16, y: 10, width: 248, height: 16)
        overrideLabel.font = .systemFont(ofSize: 11)
        overrideLabel.textColor = .secondaryLabelColor
        for view in [valueLabel, slider, overrideLabel] { addSubview(view) }
        subscription = transparency.$percentage.sink { [weak self] value in
            self?.refresh(percentage: value)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func sliderChanged(_ sender: NSSlider) {
        transparency.setPercentage(sender.doubleValue)
    }

    @objc private func accessibilityChanged(_ notification: Notification) {
        refresh(percentage: transparency.percentage)
    }

    private func refresh(percentage: Double) {
        let reduced = reduceTransparency()
        if slider.doubleValue.rounded() != percentage { slider.doubleValue = percentage }
        slider.isEnabled = !reduced
        valueLabel.stringValue = "\(Int(percentage))% transparent"
        slider.setAccessibilityValueDescription("\(Int(percentage)) percent transparent")
        overrideLabel.stringValue = reduced ? "Reduce transparency is on; background is solid." : "0% solid - 90% transparent"
    }
}
