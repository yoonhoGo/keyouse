import AppKit

// Persisted preferences (UserDefaults) + a small settings window built programmatically.

// Launch at login via a LaunchAgent plist (works for a bare executable, no app bundle needed).
enum LoginItem {
    private static let label = "com.keyouse.loginitem"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static func setEnabled(_ on: Bool) {
        let fm = FileManager.default
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [exe], "RunAtLoad": true]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}

enum Settings {
    static let keys = ["triggerKeyCode", "triggerMods", "triggerLabel", "showGuide",
                       "guideFontSize", "panelActiveOpacity", "scrollRescanDelay",
                       "cmdVisibleRoles", "ctrlVisibleRoles", "language"]

    /// Sentinel triggerKeyCode meaning "double-tap the trigger modifier" (no real key). 0xFFFF
    /// never matches an actual keyCode, so the keyDown path stays inert for this trigger.
    static let doubleTapKeyCode: UInt16 = 0xFFFF
    static var isDoubleTapTrigger: Bool { triggerKeyCode == doubleTapKeyCode }

    private static var d: UserDefaults { .standard }

    static func reset() { keys.forEach { d.removeObject(forKey: $0) } }

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
    /// Show the shortcut guide grid beneath the search field.
    static var showGuide: Bool {
        get { d.object(forKey: "showGuide") as? Bool ?? true }
        set { d.set(newValue, forKey: "showGuide") }
    }
    /// Guide font size (pt).
    static var guideFontSize: Double {
        get { let v = d.double(forKey: "guideFontSize"); return v > 0 ? v : 14 }
        set { d.set(newValue, forKey: "guideFontSize") }
    }
    /// Panel opacity while a modifier is held / a number is being entered. 0 = fully hidden.
    static var panelActiveOpacity: Double {
        get { d.object(forKey: "panelActiveOpacity") as? Double ?? 0.0 }
        set { d.set(newValue, forKey: "panelActiveOpacity") }
    }
    /// Seconds to wait after scrolling stops before re-scanning hints.
    static var scrollRescanDelay: Double {
        get { let v = d.double(forKey: "scrollRescanDelay"); return v > 0 ? v : 1.0 }
        set { d.set(newValue, forKey: "scrollRescanDelay") }
    }
    /// Roles shown while ⌘ is held. Default: in-window command controls.
    static var cmdVisibleRoles: Set<String> {
        get {
            if let arr = d.array(forKey: "cmdVisibleRoles") as? [String] { return Set(arr) }
            return ["AXButton", "AXMenuButton", "AXPopUpButton", "AXTab"]
        }
        set { d.set(Array(newValue), forKey: "cmdVisibleRoles") }
    }
    /// Roles shown while ⌃ is held. Default: form fields.
    static var ctrlVisibleRoles: Set<String> {
        get {
            if let arr = d.array(forKey: "ctrlVisibleRoles") as? [String] { return Set(arr) }
            return ["AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton"]
        }
        set { d.set(Array(newValue), forKey: "ctrlVisibleRoles") }
    }

    static func triggerDisplay() -> String {
        if isDoubleTapTrigger { return triggerLabel }   // e.g. "⌘⌘"
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
    private var delayLabel: NSTextField?
    private var fontLabel: NSTextField?
    private var opacityLabel: NSTextField?
    private var recordMonitor: Any?
    private var recordFlagsMonitor: Any?
    private var recording = false
    // Double-tap detection while recording a hotkey.
    private var recPrevMods: NSEvent.ModifierFlags = []
    private var recLastMod: NSEvent.ModifierFlags = []
    private var recLastTapTime: TimeInterval = 0
    var onLanguageChange: (() -> Void)?

    // (AX role, display name) — the roles offered as filter checkboxes.
    private var roles: [(String, String)] {
        [
            ("AXButton", L.t("Button", "버튼")), ("AXMenuButton", L.t("Menu button", "메뉴 버튼")),
            ("AXPopUpButton", L.t("Pop-up button", "팝업 버튼")), ("AXTab", L.t("Tab", "탭")),
            ("AXCheckBox", L.t("Checkbox", "체크박스")), ("AXRadioButton", L.t("Radio", "라디오")),
            ("AXLink", L.t("Link", "링크")), ("AXTextField", L.t("Text field", "텍스트 필드")),
            ("AXTextArea", L.t("Text area", "텍스트 영역")), ("AXMenuItem", L.t("Menu item", "메뉴 항목")),
            ("AXMenuBarItem", L.t("Menu bar item", "메뉴바 항목")), ("AXDockItem", L.t("Dock item", "Dock 아이콘")),
        ]
    }

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

        stack.addArrangedSubview(header(L.t("Language", "언어")))
        let langPopup = NSPopUpButton()
        langPopup.addItems(withTitles: ["English", "한국어"])
        langPopup.selectItem(at: L.lang == .ko ? 1 : 0)
        langPopup.target = self; langPopup.action = #selector(languageChanged(_:))
        stack.addArrangedSubview(langPopup)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header(L.t("Panel shortcut", "패널 단축키")))
        let hk = NSButton(title: Settings.triggerDisplay(), target: self, action: #selector(toggleRecord(_:)))
        hk.bezelStyle = .rounded
        hotkeyButton = hk
        stack.addArrangedSubview(hk)
        stack.addArrangedSubview(caption(L.t("Click the button, then press a combo — or double-tap a modifier (⌘⌘).",
                                             "버튼을 누른 뒤 조합을 입력하거나, 모디파이어를 두 번 누르세요 (⌘⌘).")))

        stack.addArrangedSubview(spacer())
        let loginCB = NSButton(checkboxWithTitle: L.t("Start at login", "로그인 시 시작"), target: self, action: #selector(toggleLogin(_:)))
        loginCB.state = LoginItem.isEnabled ? .on : .off
        stack.addArrangedSubview(loginCB)

        let guideCB = NSButton(checkboxWithTitle: L.t("Show shortcut guide", "단축키 가이드 표시"), target: self, action: #selector(toggleGuide(_:)))
        guideCB.state = Settings.showGuide ? .on : .off
        stack.addArrangedSubview(guideCB)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header(L.t("Guide font size", "가이드 글자 크기")))
        let fontSlider = NSSlider(value: Settings.guideFontSize, minValue: 10, maxValue: 20,
                                  target: self, action: #selector(fontChanged(_:)))
        fontSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let fl = caption(String(format: "%.0fpt", Settings.guideFontSize)); fontLabel = fl
        let fontRow = NSStackView(views: [fontSlider, fl]); fontRow.spacing = 8
        stack.addArrangedSubview(fontRow)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header(L.t("Panel opacity while typing", "입력 중 패널 불투명도")))
        let opSlider = NSSlider(value: Settings.panelActiveOpacity, minValue: 0.0, maxValue: 1.0,
                                target: self, action: #selector(opacityChanged(_:)))
        opSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let ol = caption(opacityText(Settings.panelActiveOpacity)); opacityLabel = ol
        let opRow = NSStackView(views: [opSlider, ol]); opRow.spacing = 8
        stack.addArrangedSubview(opRow)
        stack.addArrangedSubview(caption(L.t("Opacity while a modifier is held / entering a number (0 = hidden).",
                                             "modifier를 누르거나 번호 입력 시 패널 투명도 (0 = 숨김).")))

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header(L.t("Rescan delay after scrolling", "스크롤 후 재스캔 딜레이")))
        let slider = NSSlider(value: Settings.scrollRescanDelay, minValue: 0.2, maxValue: 3.0,
                              target: self, action: #selector(delayChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let dl = caption(delayText(Settings.scrollRescanDelay))
        delayLabel = dl
        let row = NSStackView(views: [slider, dl])
        row.orientation = .horizontal; row.spacing = 8
        stack.addArrangedSubview(row)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(header(L.t("Roles to show when held", "눌렀을 때 표시할 요소")))
        let cols = NSStackView(views: [
            roleColumn(L.t("⌘ (buttons)", "⌘ (버튼)"), Settings.cmdVisibleRoles, #selector(toggleCmdRole(_:))),
            roleColumn(L.t("⌃ (forms)", "⌃ (입력폼)"), Settings.ctrlVisibleRoles, #selector(toggleCtrlRole(_:))),
        ])
        cols.orientation = .horizontal; cols.alignment = .top; cols.spacing = 24
        stack.addArrangedSubview(cols)

        stack.addArrangedSubview(spacer())
        let reset = NSButton(title: L.t("Reset to defaults", "기본값으로 리셋"), target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L.t("keyouse Settings", "keyouse 환경설정")
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

    @objc private func toggleLogin(_ s: NSButton) { LoginItem.setEnabled(s.state == .on) }

    @objc private func toggleGuide(_ s: NSButton) { Settings.showGuide = (s.state == .on) }

    @objc private func languageChanged(_ s: NSPopUpButton) {
        L.lang = s.indexOfSelectedItem == 1 ? .ko : .en
        onLanguageChange?()                            // refresh the status-bar menu
        window?.orderOut(nil); window = nil; show()    // rebuild settings UI in the new language
    }

    @objc private func resetDefaults() {
        let a = NSAlert()
        a.messageText = L.t("Reset to default settings?", "기본 설정으로 되돌릴까요?")
        a.informativeText = L.t("Shortcut, filters, guide, language and start-at-login will all be reset.",
                                "단축키·필터·가이드·언어·로그인 시작 설정이 모두 초기화됩니다.")
        a.addButton(withTitle: L.t("Reset", "리셋"))
        a.addButton(withTitle: L.t("Cancel", "취소"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Settings.reset()
        LoginItem.setEnabled(false)
        onLanguageChange?()
        window?.orderOut(nil); window = nil; show()   // rebuild UI with defaults
    }

    private func opacityText(_ v: Double) -> String { v <= 0.01 ? L.t("Hidden", "숨김") : String(format: "%.0f%%", v * 100) }
    private func delayText(_ v: Double) -> String { String(format: L.t("%.1fs", "%.1f초"), v) }

    @objc private func fontChanged(_ s: NSSlider) {
        let v = s.doubleValue.rounded()
        Settings.guideFontSize = v
        fontLabel?.stringValue = String(format: "%.0fpt", v)
    }

    @objc private func opacityChanged(_ s: NSSlider) {
        let v = (s.doubleValue * 20).rounded() / 20   // 0.05 steps
        Settings.panelActiveOpacity = v
        opacityLabel?.stringValue = opacityText(v)
    }

    @objc private func delayChanged(_ sender: NSSlider) {
        let v = (sender.doubleValue * 10).rounded() / 10   // 0.1s steps
        Settings.scrollRescanDelay = v
        delayLabel?.stringValue = delayText(v)
    }

    private func roleColumn(_ title: String, _ selected: Set<String>, _ action: Selector) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 4
        col.addArrangedSubview(header(title))
        for (i, r) in roles.enumerated() {
            let cb = NSButton(checkboxWithTitle: r.1, target: self, action: action)
            cb.tag = i
            cb.state = selected.contains(r.0) ? .on : .off
            col.addArrangedSubview(cb)
        }
        return col
    }

    @objc private func toggleCmdRole(_ s: NSButton) {
        var cur = Settings.cmdVisibleRoles
        if s.state == .on { cur.insert(roles[s.tag].0) } else { cur.remove(roles[s.tag].0) }
        Settings.cmdVisibleRoles = cur
    }

    @objc private func toggleCtrlRole(_ s: NSButton) {
        var cur = Settings.ctrlVisibleRoles
        if s.state == .on { cur.insert(roles[s.tag].0) } else { cur.remove(roles[s.tag].0) }
        Settings.ctrlVisibleRoles = cur
    }

    @objc private func toggleRecord(_ sender: NSButton) {
        if recording { stopRecording(); return }
        recording = true
        recPrevMods = []; recLastMod = []; recLastTapTime = 0
        sender.title = L.t("Press a key…", "키 입력…")
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let keyCode = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            let chars = e.charactersIgnoringModifiers
            MainActor.assumeIsolated { self?.capture(keyCode: keyCode, mods: mods, chars: chars) }
            return nil
        }
        recordFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let raw = e.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
            MainActor.assumeIsolated { self?.recordFlags(modsRaw: raw) }
            return nil
        }
    }

    private static let modKeys: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]

    private func modSymbol(_ m: NSEvent.ModifierFlags) -> String {
        if m == .command { return "⌘" }; if m == .option { return "⌥" }
        if m == .control { return "⌃" }; if m == .shift { return "⇧" }; return "?"
    }

    // A single modifier tapped twice (from released) within the window → set a double-tap trigger.
    private func recordFlags(modsRaw: UInt) {
        let mods = NSEvent.ModifierFlags(rawValue: modsRaw)
        let count = Self.modKeys.filter { mods.contains($0) }.count
        let rising = count == 1 && recPrevMods.isEmpty   // one modifier pressed from nothing
        recPrevMods = mods
        guard rising else {
            if count > 1 { recLastMod = [] }             // a combo is forming → drop the candidate
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if mods == recLastMod, now - recLastTapTime < 0.35 {
            Settings.triggerKeyCode = Settings.doubleTapKeyCode
            Settings.triggerModifiers = mods
            Settings.triggerLabel = modSymbol(mods) + modSymbol(mods)
            stopRecording()
            hotkeyButton?.title = Settings.triggerDisplay()
        } else {
            recLastMod = mods; recLastTapTime = now
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
        if let m = recordFlagsMonitor { NSEvent.removeMonitor(m); recordFlagsMonitor = nil }
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
