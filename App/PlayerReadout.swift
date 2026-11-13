import AppKit
import CDKit
import Combine
import SwiftUI

/// The track and time. AppKit draws them and follows the player's clock itself, so a playing disc's
/// once-a-second tick redraws only the line that changed: SwiftUI neither lays out nor renders the panel.
struct PlayerReadout: NSViewRepresentable {
    struct Content: Equatable {
        var track: String
        var time: String
        var accessibilityLabel: String

        @MainActor init(_ player: PlayerModel) {
            track = player.trackText
            time = player.timeText
            accessibilityLabel = player.displayAccessibilityLabel
        }
    }

    /// Observed for everything else the readout shows, such as the disc summary or a drive selection.
    @ObservedObject var player: PlayerModel
    let tint: NSColor

    func makeNSView(context: Context) -> PlayerReadoutView {
        PlayerReadoutView(clock: player.clock, tint: tint) { [player] in Content(player) }
    }

    func updateNSView(_ view: PlayerReadoutView, context: Context) {
        view.refresh()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlayerReadoutView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? nsView.idealWidth
        return CGSize(width: width, height: PlayerReadoutView.height)
    }
}

/// "TRK", the track number after it and the time at the trailing edge, on one baseline, set as SwiftUI sets
/// text, so the readout looks as it did as SwiftUI text.
final class PlayerReadoutView: NSView {
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let digitFont = NSFont(name: "Helvetica-Oblique", size: 38)
        ?? .monospacedDigitSystemFont(ofSize: 38, weight: .medium)
    static let label = "TRK"
    static let spacing: CGFloat = 14
    /// AppKit's own line for Helvetica adds 8 pt of leading, which SwiftUI leaves out.
    static let height = ceil(digitFont.ascender - digitFont.descender)
    /// SwiftUI puts the baseline a whole number of points down.
    private static let baseline = digitFont.ascender.rounded()

    let labelLine = ReadoutLineLayer(font: labelFont, baseline: baseline)
    let trackLine = ReadoutLineLayer(font: digitFont, baseline: baseline)
    let timeLine = ReadoutLineLayer(font: digitFont, baseline: baseline)
    private let tint: NSColor
    private let read: @MainActor () -> PlayerReadout.Content
    private(set) var content: PlayerReadout.Content?
    private var color: CGColor?
    private var clockChange: AnyCancellable?

    init(clock: PlayerClock, tint: NSColor, read: @escaping @MainActor () -> PlayerReadout.Content) {
        self.tint = tint
        self.read = read
        super.init(frame: .zero)
        wantsLayer = true
        for line in lines { layer?.addSublayer(line) }
        clockChange = clock.objectWillChange.sink { [weak self] in
            // Sent before the clock moves, so read it once the change is made.
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    private var lines: [ReadoutLineLayer] { [labelLine, trackLine, timeLine] }

    var idealWidth: CGFloat {
        lines.reduce(2 * Self.spacing) { $0 + pixelCeil($1.textWidth) }
    }

    /// Shows the player's current track and time. Only a line whose text changed redraws.
    func refresh() {
        let content = read()
        guard content != self.content else { return }
        self.content = content
        show()
    }

    /// The lines draw no other way, so the view's own layer never gets a backing store.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        show()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for line in lines where line.contentsScale != scale {
            line.contentsScale = scale
            line.setNeedsDisplay()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        color = nil
        show()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        color = nil
        show()
    }

    private func show() {
        guard let content else { return }
        // SwiftUI's text resolves the tint in this view's appearance too, which on glass is a vibrant one.
        let color = color ?? tint.resolved(for: effectiveAppearance).cgColor
        self.color = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLine.show(Self.label, color: color)
        trackLine.show(content.track, color: color)
        timeLine.show(content.time, color: color)
        place(labelLine, x: 0)
        place(trackLine, x: pixelCeil(labelLine.textWidth) + Self.spacing)
        place(timeLine, x: bounds.width - pixelCeil(timeLine.textWidth))
        CATransaction.commit()
    }

    /// SwiftUI sizes each line up to a whole number of pixels.
    private func pixelCeil(_ width: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return ceil(width * scale) / scale
    }

    private func place(_ line: ReadoutLineLayer, x: CGFloat) {
        let overhang = ReadoutLineLayer.overhang
        let frame = convertToLayer(NSRect(
            x: x - overhang, y: 0, width: pixelCeil(line.textWidth) + 2 * overhang, height: bounds.height
        ))
        if line.frame != frame { line.frame = frame }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { content?.accessibilityLabel }
}

/// One line of text with its baseline a fixed distance below the layer's top, so lines in different fonts
/// share a baseline. It redraws only when its text or colour changes.
final class ReadoutLineLayer: CALayer {
    /// Room each side of the text, for the oblique digits that lean past their advance.
    static let overhang: CGFloat = 8
    private let font: NSFont
    private let baseline: CGFloat
    private(set) var text = ""
    private(set) var textWidth: CGFloat = 0
    private var line: CTLine?
    private var color: CGColor?

    init(font: NSFont, baseline: CGFloat) {
        self.font = font
        self.baseline = baseline
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        let source = layer as? ReadoutLineLayer
        font = source?.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        baseline = source?.baseline ?? 0
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Changes appear at once; nothing here animates.
    override func action(forKey event: String) -> (any CAAction)? { nil }

    func show(_ text: String, color: CGColor) {
        guard line == nil || text != self.text || color != self.color else { return }
        if line == nil || text != self.text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            self.line = line
            textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        self.text = text
        self.color = color
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        guard let line, let color else { return }
        // Core Text draws with y up.
        if contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.textMatrix = .identity
        context.setFillColor(color)
        context.textPosition = CGPoint(x: Self.overhang, y: bounds.height - baseline)
        CTLineDraw(line, context)
    }
}
