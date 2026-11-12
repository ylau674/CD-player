import AppKit
import CDKit
import SwiftUI

/// Row 2 left of the rate icon: the status, and the name of the selected output with its menu
/// indicator, which open the output menu. The status and the indicator never move. When the name
/// does not fit between them, or is wider than its maximum, only the name scrolls, within that
/// space. Core Animation moves it
/// in the render server, so the app does no work per frame, and nothing moves unless the name
/// overflows and the window is visible.
struct OutputStatusLine: NSViewRepresentable {
    enum Tone: Equatable {
        case normal, warning, error
    }

    struct Content: Equatable {
        var status: String
        var tone: Tone
        var statusAccessibilityLabel: String
        var outputName: String
        var outputHelp: String
        var outputAccessibilityValue: String
        var outputEnabled: Bool
        var choices: [OutputChoice]
        var selectedID: OutputChoice.ID
        /// The widest the name may be shown; a longer name scrolls within this width.
        var maximumNameWidth: Double = .infinity
        /// The normal status, the name and its indicator.
        var tint: NSColor = PlayerPalette.glass.status
        /// The name and its indicator while the output cannot be changed.
        var dimmedTint: NSColor = PlayerPalette.glass.dimmedStatus
    }

    let content: Content
    let select: @MainActor (OutputChoice.ID) -> Void

    func makeNSView(context: Context) -> OutputStatusLineView { OutputStatusLineView() }

    func updateNSView(_ view: OutputStatusLineView, context: Context) {
        view.select = select
        view.update(content, reduceMotion: context.environment.accessibilityReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OutputStatusLineView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.idealWidth
        return CGSize(width: width, height: OutputStatusLineView.lineHeight)
    }
}

final class OutputStatusLineView: NSView, NSViewToolTipOwner {
    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    static let scrollKey = "scroll"

    var select: (@MainActor (OutputChoice.ID) -> Void)?
    private var content: OutputStatusLine.Content?
    private var reduceMotion = false
    private var line: OutputLineLayout?
    let statusLayer = CATextLayer()
    /// The space between the status and the indicator, which clips the scrolling name.
    let nameSpace = CALayer()
    /// Moves the name and the copy that follows it in, so each pass ends where it began.
    let scroller = CALayer()
    let nameLayers = [CATextLayer(), CATextLayer()]
    let indicatorLayer = CATextLayer()
    private let statusElement = NSAccessibilityElement()
    private lazy var selectorElement = OutputSelectorElement(view: self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        for text in textLayers {
            text.isWrapped = false
            text.alignmentMode = .left
        }
        nameSpace.masksToBounds = true
        for name in nameLayers { scroller.addSublayer(name) }
        nameSpace.addSublayer(scroller)
        layer?.addSublayer(statusLayer)
        layer?.addSublayer(nameSpace)
        layer?.addSublayer(indicatorLayer)
        statusElement.setAccessibilityRole(.staticText)
        statusElement.setAccessibilityParent(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var textLayers: [CATextLayer] { [statusLayer, indicatorLayer] + nameLayers }

    var idealWidth: CGFloat {
        guard let content else { return 0 }
        return Self.measure(content.status) + OutputLineLayout.gap +
            min(Self.measure(content.outputName), content.maximumNameWidth) + Self.measure(OutputLineLayout.indicator)
    }

    func update(_ content: OutputStatusLine.Content, reduceMotion: Bool) {
        // SwiftUI updates the view on every clock tick; redraw only what changed.
        guard content != self.content || reduceMotion != self.reduceMotion else { return }
        self.content = content
        self.reduceMotion = reduceMotion
        apply()
    }

    override func layout() {
        super.layout()
        apply()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for text in textLayers { text.contentsScale = scale }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        viewDidChangeBackingProperties()
        apply()
        restartScrolling()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    @objc private func occlusionChanged() { restartScrolling() }

    // MARK: Layout

    private var isVisibleOnScreen: Bool { window?.occlusionState.contains(.visible) == true }

    private static func measure(_ text: String) -> Double {
        Double(ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width))
    }

    private func apply() {
        guard let content else { return }
        let previous = line
        let line = OutputLineLayout(
            status: content.status, name: content.outputName, width: Double(bounds.width),
            maximumNameWidth: content.maximumNameWidth, reduceMotion: reduceMotion, measure: Self.measure
        )
        self.line = line
        // A text layer keeps a colour as resolved now; the view redoes this when its appearance changes.
        let toneColor: NSColor = switch content.tone {
        case .normal: content.tint
        case .warning: .systemOrange
        case .error: .systemRed
        }
        let statusColor = toneColor.resolved(for: layerColorAppearance)
        let nameColor = (content.outputEnabled ? content.tint : content.dimmedTint).resolved(for: layerColorAppearance)
        let y = ((bounds.height - Self.lineHeight) / 2).rounded(.down)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(statusLayer, line.status, statusColor, x: 0, width: line.statusWidth, y: y)
        setFrame(nameSpace, CGRect(x: line.nameX, y: 0, width: line.nameSpaceWidth, height: bounds.height))
        setFrame(scroller, nameSpace.bounds)
        for copy in 0..<2 {
            place(nameLayers[copy], line.name, nameColor, x: copy == 0 ? 0 : line.cycle, width: line.nameWidth, y: y,
                  hidden: copy == 1 && line.mode != .scrolling)
        }
        place(indicatorLayer, OutputLineLayout.indicator, nameColor, x: line.indicatorX, width: line.indicatorWidth,
              y: y)
        updateScrolling(from: previous)
        CATransaction.commit()
        updateAccessibility(line)
    }

    private func place(
        _ layer: CATextLayer, _ text: String, _ color: NSColor, x: Double, width: Double, y: CGFloat,
        hidden: Bool = false
    ) {
        let string = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color])
        // Setting the same string again would still redraw the layer.
        if (layer.string as? NSAttributedString) != string { layer.string = string }
        setFrame(layer, CGRect(x: x, y: y, width: width, height: Self.lineHeight))
        if layer.isHidden != hidden { layer.isHidden = hidden }
    }

    private func setFrame(_ layer: CALayer, _ frame: CGRect) {
        if layer.frame != frame { layer.frame = frame }
    }

    // MARK: Scrolling

    private func restartScrolling() {
        scroller.removeAnimation(forKey: Self.scrollKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateScrolling(from: nil)
        CATransaction.commit()
    }

    /// Starts, keeps or stops the pass. Only the name moves, so a status update, which at most
    /// moves the start of the name's space, lets a pass under way carry on.
    private func updateScrolling(from previous: OutputLineLayout?) {
        guard let line, line.mode == .scrolling, isVisibleOnScreen else {
            scroller.removeAnimation(forKey: Self.scrollKey)
            return
        }
        if let previous, line.scrollsLike(previous), scroller.animation(forKey: Self.scrollKey) != nil { return }
        let pass = CAKeyframeAnimation(keyPath: "transform.translation.x")
        pass.values = [0, 0, -line.cycle]
        pass.keyTimes = [0, NSNumber(value: OutputLineLayout.pause / line.duration), 1]
        pass.duration = line.duration
        pass.beginTime = scroller.convertTime(CACurrentMediaTime(), from: nil)
        pass.repeatCount = .infinity
        pass.isRemovedOnCompletion = false
        scroller.add(pass, forKey: Self.scrollKey)
    }

    /// The output selector: the name's space and the indicator. Unlike the name, it never moves.
    var selectorFrame: CGRect {
        guard let line else { return .zero }
        return CGRect(x: line.nameX, y: 0, width: line.selectorWidth, height: bounds.height).intersection(bounds)
    }

    func selectorContains(_ point: NSPoint) -> Bool {
        line != nil && bounds.contains(point) && selectorFrame.insetBy(dx: -3, dy: 0).contains(point)
    }

// MARK: Menu

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if content?.outputEnabled == true, selectorContains(point) {
            showMenu(below: selectorFrame)
        } else {
            // The rest of the line is part of the display, which moves the window.
            window?.performDrag(with: event)
        }
    }

    fileprivate func showMenuFromAccessibility() -> Bool {
        guard content?.outputEnabled == true, line != nil else { return false }
        showMenu(below: selectorFrame)
        return true
    }

    private func showMenu(below selector: CGRect) {
        let menu = makeOutputMenu()
        let x = min(max(selector.minX, 0), bounds.maxX)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: isFlipped ? selector.maxY + 3 : selector.minY - 3), in: self)
    }

    func makeOutputMenu() -> NSMenu {
        let menu = NSMenu(title: "Audio output")
        menu.autoenablesItems = false
        guard let content else { return menu }
        for choice in content.choices {
            // System Default follows macOS, so it sits apart from the outputs the app holds itself.
            if choice.isSystemDefault, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.menuTitle, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.id == content.selectedID ? .on : .off
            item.isEnabled = choice.isEnabled
            item.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let id = item.representedObject as? OutputChoice.ID else { return }
        select?(id)
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let content, let line else { return "" }
        if selectorContains(point) { return content.outputHelp }
        // A status cut short shows in full.
        return line.status != content.status && point.x < line.statusWidth ? content.status : ""
    }

    // MARK: Accessibility

    /// VoiceOver reads the status and the selector as two items, not as the moving name.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [statusElement, selectorElement] }

    private func updateAccessibility(_ line: OutputLineLayout) {
        guard let content else { return }
        statusElement.setAccessibilityValue(content.statusAccessibilityLabel)
        statusElement.setAccessibilityFrameInParentSpace(
            CGRect(x: 0, y: 0, width: min(line.statusWidth, Double(bounds.width)), height: bounds.height)
        )
        selectorElement.setAccessibilityLabel("Audio output")
        selectorElement.setAccessibilityValue(content.outputAccessibilityValue)
        selectorElement.setAccessibilityHelp(content.outputHelp)
        selectorElement.setAccessibilityEnabled(content.outputEnabled)
        selectorElement.setAccessibilityFrameInParentSpace(selectorFrame)
    }
}

/// The output selector as VoiceOver sees it: a pop-up button that opens the output menu.
@MainActor
final class OutputSelectorElement: NSAccessibilityElement {
    private weak var view: OutputStatusLineView?

    init(view: OutputStatusLineView) {
        self.view = view
        super.init()
        setAccessibilityRole(.popUpButton)
        setAccessibilityParent(view)
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        perform(#selector(showMenuFromAccessibility), on: Thread.main, with: nil, waitUntilDone: false)
        return true
    }
    nonisolated override func accessibilityPerformShowMenu() -> Bool {
        perform(#selector(showMenuFromAccessibility), on: Thread.main, with: nil, waitUntilDone: false)
        return true
    }

    @objc private func showMenuFromAccessibility() {
        _ = view?.showMenuFromAccessibility()
    }
}
