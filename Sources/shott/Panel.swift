import AppKit

// Liquid Glass search panel. The query is a real editable NSTextField so the input method
// (IME) handles Hangul/CJK composition; control keys are intercepted upstream by a monitor.
// Auto Layout with generous insets so nothing lands in the glass corner-radius clip region.

final class PanelView: NSView {
    let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let guideLabel = NSTextField(labelWithString: "")

    static let guideText = "숫자 클릭   ⌃+숫자 우클릭   ⌘ 버튼만   글자 검색   ⇧↑↓ 스크롤   ⌘Tab 창전환   esc"

    override init(frame: NSRect) {
        super.init(frame: frame)

        field.isEditable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 26, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = "요소 검색…"
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        guideLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        guideLabel.textColor = .secondaryLabelColor
        guideLabel.stringValue = Self.guideText

        for l in [field, countLabel, guideLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
        }

        // Insets (20) clear the 22pt corner radius on every edge.
        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            field.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            countLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 8),
            guideLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            guideLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            guideLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Live query text including any in-progress IME composition (marked text).
    var query: String { field.currentEditor()?.string ?? field.stringValue }

    func update(count: Int) { countLabel.stringValue = "\(count)개" }
}

enum Panel {
    static let size = NSSize(width: 560, height: 100)

    /// Wrap any content view in a Liquid Glass surface (macOS 26+), else a frosted fallback.
    @MainActor
    static func makeGlass(_ content: NSView, size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        content.frame = frame
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 22
            glass.contentView = content
            return glass
        }
        let ve = NSVisualEffectView(frame: frame)
        ve.material = .hudWindow
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = 22
        ve.layer?.masksToBounds = true
        ve.addSubview(content)
        return ve
    }
}
