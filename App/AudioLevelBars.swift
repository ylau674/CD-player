import AppKit
import CDKit
import SwiftUI

/// Both meter bars, drawn by AppKit so a level change redraws only them, never the SwiftUI player view.
struct AudioLevelBars: NSViewRepresentable {
    let isLive: Bool
    let read: @MainActor () -> AudioLevelMeter.Reading
    let tint: Color
    let peakHoldTint: Color

    func makeNSView(context: Context) -> AudioLevelBarsView {
        AudioLevelBarsView(
            read: read,
            lit: NSColor(tint), unlit: NSColor(tint.opacity(0.18)), peakHold: NSColor(peakHoldTint)
        )
    }

    func updateNSView(_ view: AudioLevelBarsView, context: Context) {
        view.update(isLive: isLive)
    }

    static func dismantleNSView(_ view: AudioLevelBarsView, coordinator: ()) {
        view.stop()
    }
}

/// Each segment is its own rounded, coloured layer that Core Animation composites, so a reading only
/// recolours the segments that changed: nothing is drawn or rasterised in the app as the levels move.
final class AudioLevelBarsView: NSView {
    static let rowHeight: CGFloat = 12
    static let rowSpacing: CGFloat = 4
    static let height = 2 * rowHeight + rowSpacing
    /// The same gap as the scale row's cells, so each label stays under its segment.
    static let segmentSpacing: CGFloat = 2
    private static let segmentHeight: CGFloat = 7
    private static let segmentCount = AudioLevelMeter.segmentThresholds.count
    /// Hand-added layers fade every change over 0.25 s by default; the meter's own fall is the only motion.
    private static let noAnimations: [String: any CAAction] = [
        "backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()
    ]

    private let lit: CGColor
    private let unlit: CGColor
    private let peakHold: CGColor
    /// The L row's segments, then the R row's, each from -40 dB up.
    let segmentLayers: [CALayer]
    private var shownStates: [AudioLevelMeter.SegmentState]
    private var driver: AudioLevelMeterDriver?
    private(set) var drawnReadings = 0

    init(read: @escaping @MainActor () -> AudioLevelMeter.Reading, lit: NSColor, unlit: NSColor, peakHold: NSColor) {
        self.lit = lit.cgColor
        self.unlit = unlit.cgColor
        self.peakHold = peakHold.cgColor
        shownStates = Array(repeating: .unlit, count: 2 * Self.segmentCount)
        segmentLayers = shownStates.map { _ in
            let layer = CALayer()
            layer.backgroundColor = unlit.cgColor
            layer.cornerRadius = 1
            layer.actions = Self.noAnimations
            return layer
        }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        driver = AudioLevelMeterDriver(read: read) { [weak self] reading in
            self?.show(reading)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    var isRefreshing: Bool { driver?.isRefreshing ?? false }

    func update(isLive: Bool) { driver?.update(isLive: isLive) }
    func stop() { driver?.stop() }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        segmentLayers.forEach(layer.addSublayer)
        return layer
    }

    /// The segment layers are the whole drawing, so the view's own layer never gets a backing store.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSegments()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutSegments()
    }

    private func layoutSegments() {
        let count = Self.segmentCount
        let segmentWidth = (bounds.width - CGFloat(count - 1) * Self.segmentSpacing) / CGFloat(count)
        for (index, layer) in segmentLayers.enumerated() {
            guard segmentWidth > 0 else {
                layer.frame = .zero
                continue
            }
            let row = index / count
            let y = CGFloat(row) * (Self.rowHeight + Self.rowSpacing) + (Self.rowHeight - Self.segmentHeight) / 2
            let x = CGFloat(index % count) * (segmentWidth + Self.segmentSpacing)
            let rect = backingAlignedRect(
                NSRect(x: x, y: y, width: segmentWidth, height: Self.segmentHeight),
                options: .alignAllEdgesNearest
            )
            layer.frame = convertToLayer(rect)
        }
    }

    private func show(_ reading: AudioLevelMeter.Reading) {
        drawnReadings += 1
        for (row, channel) in [reading.left, reading.right].enumerated() {
            for segment in 0..<Self.segmentCount {
                let index = row * Self.segmentCount + segment
                let state = channel.state(ofSegment: segment)
                guard state != shownStates[index] else { continue }
                shownStates[index] = state
                segmentLayers[index].backgroundColor = switch state {
                case .lit: lit
                case .unlit: unlit
                case .peakHold: peakHold
                }
            }
        }
    }
}
