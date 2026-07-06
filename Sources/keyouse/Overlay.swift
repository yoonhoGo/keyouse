import AppKit

// Fullscreen, transparent, key-capable window. Draws highlight boxes over matching elements
// (selected one emphasized) plus a number hint badge on each, and hosts the glass panel.

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class HighlightView: NSView {
    var rects: [CGRect] = []     // AX/global coords (top-left origin)
    var codes: [String] = []     // hint number per rect
    var typed: String = ""       // in-progress hint digits; dims non-matching badges
    var selected: Int = 0
    var axScreen: CGRect = .zero   // this view's screen in AX/global coords (top-left origin)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        for (i, r) in rects.enumerated() {
            let code = i < codes.count ? codes[i] : ""
            let dimmed = !typed.isEmpty && !code.hasPrefix(typed)
            let alpha: CGFloat = dimmed ? 0.25 : 1

            // AX global (top-left origin) -> this screen's local Cocoa coords (bottom-left origin).
            let box = NSRect(x: r.minX - axScreen.minX, y: axScreen.maxY - r.maxY, width: r.width, height: r.height)
                .insetBy(dx: -2, dy: -2)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            if i == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.28 * alpha).setFill(); path.fill()
                NSColor.controlAccentColor.withAlphaComponent(alpha).setStroke(); path.lineWidth = 2.5
            } else {
                NSColor.systemYellow.withAlphaComponent(0.10 * alpha).setFill(); path.fill()
                NSColor.systemYellow.withAlphaComponent(0.9 * alpha).setStroke(); path.lineWidth = 1
            }
            path.stroke()
            if !code.isEmpty { drawBadge(code, at: box, font: font, selected: i == selected, alpha: alpha) }
        }
    }

    private func drawBadge(_ code: String, at box: NSRect, font: NSFont, selected: Bool, alpha: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha),
        ]
        let sz = (code as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 3
        let badge = NSRect(x: box.minX, y: box.maxY - sz.height - pad * 2,
                           width: sz.width + pad * 2, height: sz.height + pad * 2)
        (selected ? NSColor.controlAccentColor : NSColor.systemYellow).withAlphaComponent(alpha).set()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        (code as NSString).draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad), withAttributes: attrs)
    }
}
