import AppKit

// Persisted preferences (UserDefaults) + a small settings window built programmatically.

enum Settings {
    private static var d: UserDefaults { .standard }

    static var triggerKeyCode: UInt16 {
        get { UInt16(d.object(forKey: "triggerKeyCode") as? Int ?? 49) }   // default: Space
        set { d.set(Int(newValue), forKey: "triggerKeyCode") }
    }
    static var triggerModifiers: NSEvent.ModifierFlags {
        get {
            guard let raw = d.object(forKey: "triggerMods") as? Int else { return [.command, .shift] }
            return NSEvent.ModifierFlags(rawValue: UInt(raw))
        }
        set { d.set(Int(newValue.rawValue), forKey: "triggerMods") }
    }
    static var triggerLabel: String {
        get { d.string(forKey: "triggerLabel") ?? "Space" }
        set { d.set(newValue, forKey: "triggerLabel") }
    }
    /// Roles shown while ⌘ is held (compact mode). Default: in-window command controls.
    static var cmdVisibleRoles: Set<String> {
        get {
            if let arr = d.array(forKey: "cmdVisibleRoles") as? [String] { return Set(arr) }
            return ["AXButton", "AXMenuButton", "AXPopUpButton", "AXTab"]
        }
        set { d.set(Array(newValue), forKey: "cmdVisibleRoles") }
    }

    static func triggerDisplay() -> String {
        var s = ""
        let m = triggerModifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + triggerLabel
    }
}

@MainActor
final class SettingsWindow: NSObject {
    private var window: NSWindow?
    private var hotkeyButton: NSButton?
    private var recordMonitor: Any?
    private var recording = false

    // (AX role, display name) — the roles offered as ⌘-mode filter checkboxes.
    private let roles: [(String, String)] = [
        ("AXButton", "버튼"), ("AXMenuButton", "메뉴 버튼"), ("AXPopUpButton", "팝업 버튼"),
        ("AXTab", "탭"), ("AXCheckBox", "체크박스"), ("AXRadioButton", "라디오"),
        ("AXLink", "링크"), ("AXTextField", "텍스트 필드"), ("AXTextArea", "텍스트 영역"),
        ("AXMenuItem", "메뉴 항목"), ("AXMenuBarItem", "메뉴바 항목"), ("AXDockItem", "Dock 아이콘"),
    ]

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(header("패널 단축키"))
        let hk = NSButton(title: Settings.triggerDisplay(), target: self, action: #selector(toggleRecord(_:)))
        hk.bezelStyle = .rounded
        hotkeyButton = hk
        stack.addArrangedSubview(hk)
        stack.addArrangedSubview(caption("버튼을 누른 뒤 원하는 조합을 입력하세요."))

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header("⌘ 누를 때 표시할 요소"))
        let visible = Settings.cmdVisibleRoles
        for (i, r) in roles.enumerated() {
            let cb = NSButton(checkboxWithTitle: r.1, target: self, action: #selector(toggleRole(_:)))
            cb.tag = i
            cb.state = visible.contains(r.0) ? .on : .off
            stack.addArrangedSubview(cb)
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "shott 환경설정"
        w.contentView = content
        w.center()
        w.isReleasedWhenClosed = false
        window = w
    }

    private func header(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = .boldSystemFont(ofSize: 13); return l
    }
    private func caption(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor; return l
    }
    private func spacer() -> NSView {
        let v = NSView(); v.heightAnchor.constraint(equalToConstant: 8).isActive = true; return v
    }

    @objc private func toggleRole(_ sender: NSButton) {
        let role = roles[sender.tag].0
        var s = Settings.cmdVisibleRoles
        if sender.state == .on { s.insert(role) } else { s.remove(role) }
        Settings.cmdVisibleRoles = s
    }

    @objc private func toggleRecord(_ sender: NSButton) {
        if recording { stopRecording(); return }
        recording = true
        sender.title = "키 입력…"
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let keyCode = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let chars = e.charactersIgnoringModifiers
            MainActor.assumeIsolated { self?.capture(keyCode: keyCode, mods: mods, chars: chars) }
            return nil
        }
    }

    private func capture(keyCode: UInt16, mods: NSEvent.ModifierFlags, chars: String?) {
        Settings.triggerKeyCode = keyCode
        Settings.triggerModifiers = mods
        Settings.triggerLabel = keyLabel(keyCode: keyCode, chars: chars)
        stopRecording()
        hotkeyButton?.title = Settings.triggerDisplay()
    }

    private func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m); recordMonitor = nil }
        recording = false
    }

    private func keyLabel(keyCode: UInt16, chars: String?) -> String {
        if keyCode == 49 { return "Space" }
        if let c = chars, let ch = c.first, ch.isLetter || ch.isNumber || "-=[]\\;',./`".contains(ch) {
            return c.uppercased()
        }
        return "Key\(keyCode)"
    }
}
