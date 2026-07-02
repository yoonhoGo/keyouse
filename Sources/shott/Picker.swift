import AppKit

// Window picker list shown beneath the search panel (double-⌘). Rows are drawn directly;
// the selected row gets an accent background. Navigate with ↑↓ / digits, ⏎ to choose.

final class WindowPickerView: NSView {
    var rows: [String] = []
    var selected = 0

    static let rowHeight: CGFloat = 28
    static let vPad: CGFloat = 10
    static let width: CGFloat = 560

    static func height(for count: Int) -> CGFloat { CGFloat(max(count, 1)) * rowHeight + vPad * 2 }

    override var isFlipped: Bool { true }   // top-down rows

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        let font = NSFont.systemFont(ofSize: 13)
        for (i, row) in rows.enumerated() {
            let rowRect = NSRect(x: 8, y: Self.vPad + CGFloat(i) * Self.rowHeight,
                                 width: bounds.width - 16, height: Self.rowHeight)
            var color = NSColor.secondaryLabelColor
            if i == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6).fill()
                color = .white
            }
            let text = "\(i + 1). \(row)"
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let sz = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: rowRect.minX + 12, y: rowRect.midY - sz.height / 2),
                                    withAttributes: attrs)
        }
    }
}
