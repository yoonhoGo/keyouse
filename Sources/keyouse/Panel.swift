import AppKit

// Liquid Glass search panel: query line + match count, and (optionally) a grouped shortcut
// guide beneath. The query is a real editable NSTextField so the IME handles Hangul/CJK.

final class PanelView: NSView {
    let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")

    // Shortcut guide, grouped by purpose. Each group becomes a titled column.
    private static let groups: [(String, [(String, String)])] = [
        ("클릭 · 이동", [
            ("숫자", "클릭"), ("⇧숫자", "우클릭"), ("⏎", "선택 클릭"),
            ("↑↓", "선택 이동"), ("⇧↑↓", "스크롤"),
        ]),
        ("필터", [
            ("⌘", "버튼만"), ("⌃", "입력폼만"), ("⌘L", "링크만"), ("⌃I", "첫 입력"),
        ]),
        ("창 · 기타", [
            ("⌘Tab", "창 전환"), ("⌘R", "새로고침"), ("⌘,", "설정"), ("esc", "취소"),
        ]),
    ]

    init(showGuide: Bool) {
        super.init(frame: .zero)

        field.isEditable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.textColor = .labelColor
        field.placeholderString = "요소 검색…"
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [field, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        let pad: CGFloat = 22
        var cons = [
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            field.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            countLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 8),
        ]

        if showGuide {
            let guide = buildGuide()
            guide.translatesAutoresizingMaskIntoConstraints = false
            addSubview(guide)
            cons += [
                guide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                guide.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
                guide.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            ]
        }
        NSLayoutConstraint.activate(cons)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Live query text including any in-progress IME composition (marked text).
    var query: String { field.currentEditor()?.string ?? field.stringValue }

    func update(count: Int) { countLabel.stringValue = "\(count)개" }

    // MARK: - guide

    private var guideFont: CGFloat { CGFloat(Settings.guideFontSize) }

    private func keyLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: guideFont, weight: .semibold)
        l.textColor = .labelColor
        l.alignment = .right
        return l
    }

    private func descLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: guideFont)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func group(_ title: String, _ items: [(String, String)]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 7

        let h = NSTextField(labelWithString: title)
        h.font = .systemFont(ofSize: max(11, guideFont - 2), weight: .semibold)
        h.textColor = .tertiaryLabelColor
        col.addArrangedSubview(h)

        let grid = NSGridView(views: items.map { [keyLabel($0.0), descLabel($0.1)] })
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        col.addArrangedSubview(grid)
        return col
    }

    private func buildGuide() -> NSStackView {
        let row = NSStackView(views: Self.groups.map { group($0.0, $0.1) })
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 40
        return row
    }
}

enum Panel {
    static let width: CGFloat = 600

    static func size(showGuide: Bool) -> NSSize {
        guard showGuide else { return NSSize(width: width, height: 78) }
        let f = CGFloat(Settings.guideFontSize)
        let rows: CGFloat = 5                      // tallest group
        let h = 22 + 34 + 16 + (f + 4) + rows * (f + 9) + 22   // pad + field + gap + header + rows + pad
        return NSSize(width: width, height: h)
    }

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
