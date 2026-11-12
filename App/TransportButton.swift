import AppKit
import SwiftUI

/// What a transport button does while held: its symbol, accessibility action name and repeated action.
struct TransportHold {
    let symbol: String
    let label: String
    let action: @MainActor () -> Void
}

struct TransportButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let tint: NSColor
    var height: CGFloat = 26
    var pointSize: CGFloat = 13
    /// Off when the tint itself shows a state that must stay readable while the button is disabled.
    var dimsWhenDisabled = true
    var hold: TransportHold? = nil
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> TransportNSButton {
        let button = TransportNSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                                       target: context.coordinator, action: #selector(Coordinator.performAction))
        button.isBordered = false
        button.controlSize = .small
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        button.imageScaling = .scaleProportionallyDown
        (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = dimsWhenDisabled
        return button
    }

    func updateNSView(_ button: TransportNSButton, context: Context) {
        context.coordinator.action = action
        button.onHold = hold?.action
        // This runs on every update of the player view, including each clock tick. A new image or
        // attribute makes AppKit re-resolve the symbol and lay the window out again, so only
        // apply what changed.
        let new = Appearance(symbol: symbol, label: label, holdSymbol: hold?.symbol, holdLabel: hold?.label,
                             tint: tint, isEnabled: context.environment.isEnabled)
        let old = context.coordinator.appearance
        guard new != old else { return }
        context.coordinator.appearance = new
        if new.symbol != old?.symbol || new.label != old?.label {
            button.restingImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        if new.holdSymbol != old?.holdSymbol || new.holdLabel != old?.holdLabel {
            button.holdingImage = hold.flatMap {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)
            }
            button.holdLabel = hold?.label
        }
        if new.tint != old?.tint { button.contentTintColor = tint }
        if new.isEnabled != old?.isEnabled { button.isEnabled = new.isEnabled }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TransportNSButton, context: Context) -> CGSize? {
        let intrinsicWidth = nsView.intrinsicContentSize.width
        let width = proposal.width ?? intrinsicWidth
        return CGSize(width: width.isFinite ? width : intrinsicWidth, height: height)
    }

    struct Appearance: Equatable {
        let symbol: String
        let label: String
        let holdSymbol: String?
        let holdLabel: String?
        let tint: NSColor
        let isEnabled: Bool
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        /// What `updateNSView` last applied to the button.
        var appearance: Appearance?
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func performAction() { action() }
    }
}

/// A click performs the button's action. With `onHold` set, a press lasting `holdDelay` instead
/// shows `holdingImage` and repeats `onHold` until release, without performing the click action.
final class TransportNSButton: NSButton {
    static let holdDelay: TimeInterval = 0.5
    // Keep held steps closer together than the model's 300 ms seek debounce.
    static let holdInterval: TimeInterval = 0.25

    var onHold: (@MainActor () -> Void)?
    /// Also offered as an accessibility action, since assistive input cannot hold a button.
    var holdLabel: String? {
        didSet {
            guard holdLabel != oldValue else { return }
            setAccessibilityCustomActions(holdLabel.map {
                [NSAccessibilityCustomAction(name: $0, target: self, selector: #selector(performHoldStep))]
            } ?? [])
        }
    }
    var restingImage: NSImage? { didSet { updateImage() } }
    var holdingImage: NSImage? { didSet { updateImage() } }
    private(set) var isHolding = false { didSet { updateImage() } }
    private var pointerIsInside = false

    // AppKit's symbol-specific insets would enlarge and misalign the clickable bounds.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func mouseDown(with event: NSEvent) {
        guard onHold != nil, isEnabled, let window else {
            super.mouseDown(with: event)
            return
        }
        pointerIsInside = true
        highlight(true)
        let timer = Timer(
            timeInterval: Self.holdInterval, target: self, selector: #selector(holdTimerFired),
            userInfo: nil, repeats: true
        )
        timer.fireDate = Date(timeIntervalSinceNow: Self.holdDelay)
        RunLoop.current.add(timer, forMode: .eventTracking)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            pointerIsInside = isMousePoint(convert(next.locationInWindow, from: nil), in: bounds)
            highlight(pointerIsInside)
            if next.type == .leftMouseUp { break }
        }
        timer.invalidate()
        highlight(false)
        let wasHolding = isHolding
        isHolding = false
        if !wasHolding, pointerIsInside, isEnabled { sendAction(action, to: target) }
    }

    @objc private func holdTimerFired() {
        isHolding = true
        if pointerIsInside { onHold?() }
    }

    @objc private func performHoldStep() -> Bool {
        guard isEnabled, let onHold else { return false }
        onHold()
        return true
    }

    private func updateImage() {
        image = isHolding ? holdingImage ?? restingImage : restingImage
    }
}
