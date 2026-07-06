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

// `>` command-palette list: menu commands as rows (path + right-aligned shortcut). Same look as the
// window picker, but two columns and a scroll window so a long, filtered command list stays usable.
final class CommandListView: NSView {
    var rows: [(path: String, shortcut: String)] = []
    var selected = 0

    static let rowHeight: CGFloat = 30
    static let vPad: CGFloat = 10
    static let width: CGFloat = 600
    static let maxVisible = 12

    static func height(for count: Int) -> CGFloat {
        CGFloat(min(max(count, 1), maxVisible)) * rowHeight + vPad * 2
    }

    override var isFlipped: Bool { true }

    // First visible row, chosen so `selected` stays centred within the window when the list is long.
    private var start: Int {
        guard rows.count > Self.maxVisible else { return 0 }
        return max(0, min(selected - Self.maxVisible / 2, rows.count - Self.maxVisible))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); dirtyRect.fill()
        let pathFont = NSFont.systemFont(ofSize: 14)
        let scFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let start = self.start
        for i in start..<min(start + Self.maxVisible, rows.count) {
            let (path, sc) = rows[i]
            let rowRect = NSRect(x: 8, y: Self.vPad + CGFloat(i - start) * Self.rowHeight,
                                 width: bounds.width - 16, height: Self.rowHeight)
            var color = NSColor.labelColor, scColor = NSColor.secondaryLabelColor
            if i == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6).fill()
                color = .white; scColor = .white
            }
            let text = "\(i + 1). \(path)"
            let attrs: [NSAttributedString.Key: Any] = [.font: pathFont, .foregroundColor: color]
            let sz = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: rowRect.minX + 12, y: rowRect.midY - sz.height / 2),
                                    withAttributes: attrs)
            if !sc.isEmpty {
                let sAttrs: [NSAttributedString.Key: Any] = [.font: scFont, .foregroundColor: scColor]
                let ssz = (sc as NSString).size(withAttributes: sAttrs)
                (sc as NSString).draw(at: NSPoint(x: rowRect.maxX - ssz.width - 12, y: rowRect.midY - ssz.height / 2),
                                      withAttributes: sAttrs)
            }
        }
    }
}
