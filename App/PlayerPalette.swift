import AppKit

/// The player's colours on its clear Liquid Glass panel: system colours that follow Light and Dark Mode.
/// The palette is built once: the views skip updates whose colours are equal, and two dynamic colours are
/// equal only when they are the same instance.
struct PlayerPalette {
    /// The drive row, track and time, transport symbols, rate icon and lit meter segments.
    let display: NSColor
    /// The rate icon while the output is not at the source's rate.
    let dimmedDisplay: NSColor
    /// The status and output name in row 2.
    let status: NSColor
    /// The output name while it cannot be changed.
    let dimmedStatus: NSColor
    /// The power button and the meters' peak hold.
    let power: NSColor
    let unlitSegment: NSColor
    let outline: NSColor
    let disabledOutline: NSColor
    /// The glass's tint before the transparency setting applies, and the solid panel with Reduce transparency.
    let panel: NSColor

    static let glass = PlayerPalette(
        display: .labelColor, dimmedDisplay: NSColor.labelColor.scalingAlpha(by: 0.35),
        status: .secondaryLabelColor, dimmedStatus: NSColor.secondaryLabelColor.scalingAlpha(by: 0.45),
        power: .systemRed,
        unlitSegment: NSColor.labelColor.scalingAlpha(by: 0.18),
        outline: NSColor.labelColor.scalingAlpha(by: 0.45), disabledOutline: NSColor.labelColor.scalingAlpha(by: 0.15),
        panel: .windowBackgroundColor
    )
}

extension NSView {
    /// Where to resolve the colours a layer draws. On Liquid Glass, SwiftUI gives the AppKit views it hosts a
    /// vibrant appearance, whose colours rely on AppKit's vibrancy blending. A layer draws them flat, which
    /// would turn the status an opaque mid grey in both modes; the window's appearance has the plain colours.
    var layerColorAppearance: NSAppearance { window?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance }
}

extension NSColor {
    /// This colour with its opacity scaled, still resolved for the appearance it is drawn in.
    /// `withAlphaComponent(_:)` would fix a system colour to the current appearance and replace its opacity.
    func scalingAlpha(by fraction: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let resolved = self.resolved(for: appearance)
            return resolved.withAlphaComponent(resolved.alphaComponent * fraction)
        }
    }

    /// The fixed sRGB colour this one draws as in `appearance`.
    func resolved(for appearance: NSAppearance) -> NSColor {
        var resolved = self
        appearance.performAsCurrentDrawingAppearance { resolved = self.usingColorSpace(.sRGB) ?? self }
        return resolved
    }
}
