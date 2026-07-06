import AppKit
import ApplicationServices
import Darwin

// keyouse — hotkey -> Liquid Glass search panel -> filter by label / pick by number -> act.
// Trigger: ⌘⇧Space. While open, ⌘Tab drives keyouse's own window picker (a CGEventTap steals
// ⌘Tab from the system switcher); hold ⌘ and Tab / ⇧Tab / arrows to move, release ⌘ to choose.

// CGEventTap callback (top-level, C-compatible). Delegates to the controller on the main actor.
private func keyouseEventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                   _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AppController>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let cmd = event.flags.contains(.maskCommand)
    let shift = event.flags.contains(.maskShift)
    let consume = MainActor.assumeIsolated {
        controller.handleTap(type: type, keyCode: keyCode, cmd: cmd, shift: shift)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private enum Mode { case search, windowPicker }

    private var window: OverlayWindow?
    private var highlight: HighlightView?
    private var panelView: PanelView?
    private var panelGlass: NSView?
    private var globalMonitor: Any?
    private var flagsMonitor: Any?
    private var localMonitor: Any?
    // Double-tap ⌘ detection (opt-in trigger).
    private var lastCmdTapTime: TimeInterval = 0
    private var cmdTapInterrupted = false
    private var prevCmdDown = false
    private var mouseMonitor: Any?
    private var modActive = false        // any modifier held -> hide panel so it doesn't obscure
    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var allHits: [Hit] = []
    private var matches: [Hit] = []
    private var selected = 0
    private var hintBuffer = ""
    private var previousApp: NSRunningApplication?
    private var targetWindow: AXUIElement?   // set when a specific window was picked; nil = whole app
    private var rescanWork: DispatchWorkItem?   // debounced rescan after scrolling stops

    private var mode: Mode = .search
    private var windows: [WindowInfo] = []
    private var windowSel = 0
    private var pickerGlass: NSView?
    private var pickerView: WindowPickerView?
    private var cmdWasDown = false
    private enum Filter { case none, controls, forms, links }
    private var filter: Filter = .none    // ⌘ -> controls, ⌃ -> form fields, ⌘L -> links (sticky)
    private var sticky = false            // true when filter is a toggle (⌘L), not a held modifier
    private enum Source { case elements, windows, tabs, all, menu }
    private var source: Source = .elements   // /w -> windows, /t -> tabs, /s -> every pressable, > -> menu commands
    private var sourceHits: [Hit] = []        // cached window/tab hits for the active search mode
    private var menuListGlass: NSView?        // `>` command palette: list surface below the panel
    private var menuListView: CommandListView?
    private var expanded = false          // ⌘S: also collect AXPress-actionable elements (web/Electron)
    private lazy var settings: SettingsWindow = {
        let s = SettingsWindow()
        s.onLanguageChange = { [weak self] in self?.rebuildStatusMenu() }
        return s
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("Accessibility permission required: System Settings > Privacy & Security > Accessibility")
        }
        // Cap every AX call from this process at 0.5s (default 6s) — a slow target app makes the
        // scan return partial results instead of hanging both apps.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let keyCode = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            MainActor.assumeIsolated {
                self?.cmdTapInterrupted = true   // any keypress breaks a clean ⌘ double-tap
                if keyCode == Settings.triggerKeyCode, mods == Settings.triggerModifiers { self?.activate() }
            }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let raw = e.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
            MainActor.assumeIsolated { self?.onFlagsChanged(modsRaw: raw) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.onAppActivated(pid: pid) }
        }
        setupStatusItem()
        print("keyouse ready. Press ⌘⇧Space to open the search panel.")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "keyouse") {
            item.button?.image = img
        } else {
            item.button?.title = "K"
        }
        item.menu = buildStatusMenu()
        statusItem = item
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L.t("Open", "열기"), action: #selector(menuOpen), keyEquivalent: "")
        menu.addItem(withTitle: L.t("Close", "닫기"), action: #selector(menuClose), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("Settings…", "환경설정…"), action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("Quit", "종료"), action: #selector(menuQuit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    func rebuildStatusMenu() { statusItem?.menu = buildStatusMenu() }

    @objc private func menuOpen() { activate() }
    @objc private func menuClose() { dismiss(restoreFocus: false) }
    @objc private func menuSettings() { dismiss(restoreFocus: false); settings.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    // Fire on a clean double-tap of the configured trigger modifier: two modifier-alone presses
    // within the window, uninterrupted by any other key or modifier. Only active when the trigger
    // is a double-tap type. ponytail: monotonic uptime clock; 0.35s matches the OS double-click feel.
    private func onFlagsChanged(modsRaw: UInt) {
        guard Settings.isDoubleTapTrigger else { return }
        let mods = NSEvent.ModifierFlags(rawValue: modsRaw)
        let target = Settings.triggerModifiers
        let targetDown = mods.contains(target)
        if !mods.subtracting(target).isEmpty { cmdTapInterrupted = true }   // combo, not a clean tap
        let rising = targetDown && !prevCmdDown
        prevCmdDown = targetDown
        guard rising, mods == target else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !cmdTapInterrupted, now - lastCmdTapTime < 0.35 {
            lastCmdTapTime = 0
            activate()
        } else {
            lastCmdTapTime = now
        }
        cmdTapInterrupted = false
    }

    private func activate() {
        if window != nil { regrabFocus(); return }
        guard let screen = primaryScreen else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        targetWindow = nil
        expanded = false
        let hits = AX.scan(screen: screen.frame, expanded: expanded)
        guard !hits.isEmpty else { return }
        allHits = hits; matches = hits; selected = 0; hintBuffer = ""; mode = .search; cmdWasDown = false

        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let hv = HighlightView(frame: container.bounds)
        hv.screenHeight = screen.frame.height
        hv.autoresizingMask = [.width, .height]
        container.addSubview(hv)

        let showGuide = Settings.showGuide
        let pv = PanelView(showGuide: showGuide)
        pv.field.delegate = self
        let size = Panel.size(showGuide: showGuide)
        let glass = Panel.makeGlass(pv, size: size)
        glass.frame.origin = NSPoint(x: (screen.frame.width - size.width) / 2,
                                     y: screen.frame.height * 0.4)
        container.addSubview(glass)

        w.contentView = container
        window = w; highlight = hv; panelView = pv; panelGlass = glass

        refilter()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(pv.field)
        enableTap()

        // A mouse click anywhere (all clicks pass through the overlay) means "go use that window".
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            if e.type == .flagsChanged {
                let cmd = e.modifierFlags.contains(.command)
                let ctrl = e.modifierFlags.contains(.control)
                // Only the filter modifiers dim/hide the panel. Shift/Option are text & click
                // modifiers (⇧ types `>` / capitals, ⌥ = right-click) — hiding on them drops the
                // field's first-responder status mid-keystroke, so a Shift char never lands.
                let anyMod = !e.modifierFlags.intersection([.command, .control]).isEmpty
                MainActor.assumeIsolated {
                    self?.setFilter(cmd: cmd, ctrl: ctrl)
                    self?.modActive = anyMod
                    self?.updatePanelVisibility()
                }
                return e
            }
            let keyCode = e.keyCode
            let mods = e.modifierFlags
            let chars = e.charactersIgnoringModifiers
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyDown(keyCode: keyCode, chars: chars, mods: mods) ?? true
            }
            return consumed ? nil : e
        }
    }

    // MARK: - CGEventTap (⌘Tab window switching)

    private func enableTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: keyouseEventTapCallback, userInfo: selfPtr) else {
            print("Failed to create event tap for ⌘Tab — check Input Monitoring / Accessibility permission.")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap; runLoopSource = src
    }

    private func disableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }

    func reenableTap() { if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Returns true to swallow the event (keep it from the system switcher / apps).
    func handleTap(type: CGEventType, keyCode: Int, cmd: Bool, shift: Bool) -> Bool {
        guard window != nil else { return false }
        if type == .flagsChanged {
            if !cmd, cmdWasDown, mode == .windowPicker { confirmWindow() }   // ⌘ released -> choose
            cmdWasDown = cmd
            return false
        }
        guard cmd else { return false }
        switch keyCode {
        case 48:                                   // Tab
            if mode != .windowPicker { showWindowPicker() }
            if mode == .windowPicker { moveWindowSel(shift ? -1 : 1) }
            return true
        case 123, 126:                             // Left / Up
            if mode == .windowPicker { moveWindowSel(-1); return true }
            return false
        case 124, 125:                             // Right / Down
            if mode == .windowPicker { moveWindowSel(1); return true }
            return false
        default:
            return false
        }
    }

    // MARK: - key handling (panel is key window; field gets IME text)

    /// Returns true if consumed (false lets the keystroke reach the search field).
    private func handleKeyDown(keyCode: UInt16, chars: String?, mods: NSEvent.ModifierFlags) -> Bool {
        if mode == .windowPicker { handlePickerKey(keyCode: keyCode, chars: chars); return true }
        if mods.contains(.command), keyCode == 43 { openPreferences(); return true }        // ⌘, settings
        if mods.contains(.command), keyCode == 15 { rescan(); return true }                 // ⌘R rescan
        if mods.contains(.command), keyCode == 1 { expanded.toggle(); rescan(); return true } // ⌘S search mode
        if mods.contains(.command), keyCode == 37 { toggleLinksFilter(); return true }      // ⌘L links
        if mods.contains(.command), keyCode == 35 { enterCommandPalette(); return true }    // ⌘P command palette
        if mods.contains(.command), keyCode == 44 { toggleGuide(); return true }            // ⌘? (⌘⇧/, ⌘/도 허용) guide
        if mods.contains(.command), keyCode == 12 { sendShortcut(keyCode: 12, shift: false); return true }               // ⌘Q quit app
        if mods.contains(.command), keyCode == 13 { sendShortcut(keyCode: 13, shift: mods.contains(.shift)); return true } // ⌘W tab / ⌘⇧W window
        if mods.contains(.control), chars?.lowercased() == "i" { focusFirstInput(); return true } // ⌃I first input
        // Letter navigation (opt-in via the nav-style setting). Search matching is case-insensitive,
        // so ⇧+letter is free to repurpose; plain letters still type into the field.
        //   ⇧K/⇧J hint up/down · ⇧U/⇧D scroll up/down · ⇧H/⇧L history back/forward.
        if Settings.navHJKL, mods.contains(.shift),
           !mods.contains(.command), !mods.contains(.control), !mods.contains(.option) {
            switch keyCode {
            case 40: move(-1); return true                          // ⇧K hint up
            case 38: move(1); return true                           // ⇧J hint down
            case 32: scrollSelected(pageUp: true); return true      // ⇧U scroll up
            case 2:  scrollSelected(pageUp: false); return true     // ⇧D scroll down
            case 4:  navigateHistory(forward: false); return true   // ⇧H back
            case 37: navigateHistory(forward: true); return true    // ⇧L forward
            default: break
            }
        }
        switch keyCode {
        case 53: dismiss(restoreFocus: true); return true
        case 51:                                                                        // Backspace
            if !hintBuffer.isEmpty { hintBuffer = String(hintBuffer.dropLast()); pushHighlights(); return true }
            return false   // no number in progress -> let the field delete search text
        case 36: act(on: selected, kind: clickKind(mods)); return true                  // ⏎ / ⇧⏎ new tab / ⌥⏎ right
        case 125: mods.contains(.shift) ? scrollSelected(pageUp: false) : move(1); return true   // ↓ / ⇧↓ scroll
        case 126: mods.contains(.shift) ? scrollSelected(pageUp: true) : move(-1); return true    // ↑ / ⇧↑ scroll
        case 123: if mods.contains(.shift) { navigateHistory(forward: false); return true }; return false  // ⇧← back
        case 124: if mods.contains(.shift) { navigateHistory(forward: true); return true }; return false   // ⇧→ forward
        default:
            // Detect digits by keyCode so shift/option don't remap them (⇧2 = "@", ⌥ = symbols).
            if let d = Self.digitKeyCodes[keyCode] {
                pushDigit(d, kind: clickKind(mods)); return true    // num click · ⇧num new tab · ⌥num right-click
            }
            return false
        }
    }

    // Number-row keyCodes → digit, independent of shift/option.
    private static let digitKeyCodes: [UInt16: String] =
        [18:"1", 19:"2", 20:"3", 21:"4", 23:"5", 22:"6", 26:"7", 28:"8", 25:"9", 29:"0"]

    private enum ClickKind { case left, right, newTab }
    private func clickKind(_ mods: NSEvent.ModifierFlags) -> ClickKind {
        if mods.contains(.shift) { return .newTab }     // ⇧ = open in new tab (⌘-click)
        if mods.contains(.option) { return .right }     // ⌥ = right click
        return .left
    }

    private func handlePickerKey(keyCode: UInt16, chars: String?) {
        switch keyCode {
        case 53: hideWindowPicker()
        case 36: confirmWindow()
        case 125: moveWindowSel(1)
        case 126: moveWindowSel(-1)
        default:
            if let ch = chars?.first, ch.isNumber, let n = Int(String(ch)), n >= 1, n <= windows.count {
                selectWindow(n - 1)
            }
        }
    }

    // MARK: - search mode

    func controlTextDidChange(_ obj: Notification) { hintBuffer = ""; refilter() }

    private func refilter() {
        let (src, query) = Self.parseSource(panelView?.query ?? "")
        if src != source { source = src; rebuildSource() }
        let pool = source == .elements ? allHits : sourceHits
        var base = query.isEmpty ? pool : pool.filter { $0.label.localizedCaseInsensitiveContains(query) }
        if source == .elements {
            switch filter {
            case .none: break
            case .controls: let v = Settings.cmdVisibleRoles; base = base.filter { v.contains($0.role) }
            case .forms: let v = Settings.ctrlVisibleRoles; base = base.filter { v.contains($0.role) }
            case .links: base = base.filter { $0.role == "AXLink" }
            }
        }
        matches = base
        selected = min(selected, max(0, matches.count - 1))
        pushHighlights()
        panelView?.update(count: matches.count)
    }

    // A leading "/w" or "/t" (exact, or followed by a space) switches the search pool to open
    // windows / current-app tabs; the rest is the filter text. Otherwise it's normal element search.
    private static func parseSource(_ raw: String) -> (Source, String) {
        // Command-palette convention: no space needed (`>new` filters right away).
        if raw.hasPrefix(">") { return (.menu, String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        for (p, s) in [("/w", Source.windows), ("/t", Source.tabs), ("/s", Source.all)] {
            if raw == p { return (s, "") }
            if raw.hasPrefix(p + " ") { return (s, String(raw.dropFirst(p.count + 1)).trimmingCharacters(in: .whitespaces)) }
        }
        return (.elements, raw)
    }

    private func rebuildSource() {
        selected = 0; hintBuffer = ""
        // /w, /t and > show a result list under the panel; > additionally has no overlay to show
        // (closed menu commands have no screen frames).
        let wantsList = source == .windows || source == .tabs || source == .menu
        if wantsList { showResultList() } else { hideResultList() }
        highlight?.isHidden = (source == .menu)
        if source == .menu {
            sourceHits = previousApp.map { AX.menuCommandHits(pid: $0.processIdentifier) } ?? []
            return
        }
        guard let screen = primaryScreen else { sourceHits = []; return }
        switch source {
        case .elements: sourceHits = []
        case .windows: sourceHits = AX.windowHits(screen: screen.frame)
        case .tabs: sourceHits = previousApp.map { AX.tabHits(pid: $0.processIdentifier, screen: screen.frame) } ?? []
        case .all:                                   // every AXPress-able element (forces expanded scan)
            if let win = targetWindow, let pid = previousApp?.processIdentifier {
                sourceHits = AX.scanWindow(win, appPid: pid, screen: screen.frame, expanded: true)
            } else {
                sourceHits = AX.scan(screen: screen.frame, frontApp: previousApp, expanded: true)
            }
        case .menu: break                            // handled above
        }
    }

    // ⌘P: jump straight into the `>` command palette by typing the prefix for you.
    private func enterCommandPalette() {
        guard let field = panelView?.field else { return }
        field.stringValue = ">"
        window?.makeFirstResponder(field)
        // makeFirstResponder's field editor selects-all after this call returns; deselect on the
        // next runloop pass so typing appends after ">" instead of replacing it.
        DispatchQueue.main.async { [weak field] in
            field?.currentEditor()?.selectedRange = NSRange(location: 1, length: 0)
        }
        hintBuffer = ""
        refilter()   // programmatic set doesn't fire controlTextDidChange
    }

    // ⌘?: toggle the shortcut guide. The guide is baked into the panel at build time (its height
    // depends on it), so flip the setting and rebuild the panel glass in place, keeping the query.
    private func toggleGuide() {
        guard let container = window?.contentView, let old = panelGlass, let screen = primaryScreen else { return }
        Settings.showGuide.toggle()
        let text = panelView?.query ?? ""
        let pv = PanelView(showGuide: Settings.showGuide)
        pv.field.delegate = self
        pv.field.stringValue = text
        let size = Panel.size(showGuide: Settings.showGuide)
        let glass = Panel.makeGlass(pv, size: size)
        glass.frame.origin = NSPoint(x: (screen.frame.width - size.width) / 2,
                                     y: screen.frame.height * 0.4)
        container.addSubview(glass)
        old.removeFromSuperview()
        panelView = pv; panelGlass = glass
        window?.makeFirstResponder(pv.field)
        DispatchQueue.main.async { [weak pv] in   // past the field editor's select-all (see ⌘P)
            pv?.field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        refilter()   // re-pins the `>` list under the new panel frame too
    }

    // MARK: - result list (below the panel: `>` command palette, /w windows, /t tabs)

    private func showResultList() {
        guard let container = window?.contentView, panelGlass != nil, menuListGlass == nil else { return }
        let lv = CommandListView(frame: .zero)
        let size = NSSize(width: CommandListView.width, height: CommandListView.height(for: matches.count))
        let glass = Panel.makeGlass(lv, size: size)
        container.addSubview(glass)
        menuListView = lv; menuListGlass = glass
        layoutMenuList()   // rows filled by the pushHighlights() that follows in refilter()
        updatePanelVisibility()   // un-hide the panel if a held modifier (⌘P) had hidden it
    }

    private func hideResultList() {
        guard menuListGlass != nil else { return }
        menuListGlass?.removeFromSuperview()
        menuListGlass = nil; menuListView = nil
    }

    // Size the list to the current match count and pin it just below the search panel.
    private func layoutMenuList() {
        guard let glass = menuListGlass, let panelGlass else { return }
        let h = CommandListView.height(for: matches.count)
        let size = NSSize(width: CommandListView.width, height: h)
        glass.frame = NSRect(x: panelGlass.frame.minX, y: panelGlass.frame.minY - h - 12,
                             width: size.width, height: h)
        menuListView?.frame = NSRect(origin: .zero, size: size)   // track glass bounds regardless of glass type
    }

    // Modifier-held filters: ⌘ -> controls, ⌃ -> form fields; none -> all. Ignored while a sticky
    // toggle (⌘L links) is active so releasing the modifier doesn't clobber it.
    private func setFilter(cmd: Bool, ctrl: Bool) {
        guard !sticky else { return }
        apply(cmd ? .controls : (ctrl ? .forms : .none))
    }

    private func apply(_ new: Filter) {
        guard mode == .search, new != filter else { return }
        filter = new
        hintBuffer = ""
        refilter()
    }

    // ⌘L: toggle a sticky links-only filter (persists after ⌘ is released).
    private func toggleLinksFilter() {
        if sticky, filter == .links {
            sticky = false
            let f = NSEvent.modifierFlags
            apply(f.contains(.command) ? .controls : (f.contains(.control) ? .forms : .none))
        } else {
            sticky = true
            filter = .links; hintBuffer = ""; refilter()
        }
    }

    private func pushHighlights() {
        if menuListGlass != nil {
            menuListView?.rows = matches.map { (path: $0.label, shortcut: $0.shortcut) }
            menuListView?.selected = selected
            layoutMenuList()
            menuListView?.needsDisplay = true
            if source == .menu { return }   // closed menu items have no frames — list only
        }
        highlight?.rects = matches.map(\.frame)
        highlight?.codes = matches.indices.map { String($0 + 1) }
        highlight?.typed = hintBuffer
        highlight?.selected = selected
        highlight?.needsDisplay = true
        updatePanelVisibility()
    }

    // While a modifier is held or a number is being entered, dim/hide the panel so it never
    // covers the element you're aiming at. Behaviour is configurable (opacity; 0 = fully hidden,
    // via isHidden so the view is truly removed, not just transparent). Restore on release/clear.
    private func updatePanelVisibility() {
        guard let glass = panelGlass else { return }
        // The window picker (⌘ held by design) and the `>` command list live under the panel and
        // ARE the UI being used — never hide the panel while either is up.
        let listUp = mode == .windowPicker || menuListGlass != nil
        let active = (modActive || !hintBuffer.isEmpty) && !listUp
        if active {
            let o = Settings.panelActiveOpacity
            if o <= 0.01 { glass.isHidden = true }
            else { glass.isHidden = false; glass.alphaValue = o }
        } else {
            let wasHidden = glass.isHidden
            glass.isHidden = false; glass.alphaValue = 1
            // Hiding the glass drops the search field's first-responder status; restore it on reveal
            // so typing-to-filter keeps working after a modifier press.
            if wasHidden, let f = panelView?.field { window?.makeFirstResponder(f) }
        }
    }

    private func pushDigit(_ d: String, kind: ClickKind) {
        guard !matches.isEmpty else { return }
        let candidate = hintBuffer + d
        let numbers = matches.indices.map { String($0 + 1) }
        let cands = numbers.filter { $0.hasPrefix(candidate) }
        if cands.isEmpty { return }
        hintBuffer = candidate
        if let idx = Int(candidate).map({ $0 - 1 }), matches.indices.contains(idx) { selected = idx }
        if cands.count == 1, cands[0] == candidate, let idx = Int(candidate).map({ $0 - 1 }) {
            act(on: idx, kind: kind)
        } else {
            pushHighlights()
        }
    }

    private func act(on index: Int, kind: ClickKind) {
        guard matches.indices.contains(index) else { return }
        let target = matches[index]
        dismiss(restoreFocus: false)
        if target.role == "AXWindow" {                       // /w mode: raise the window, not click
            AX.raise(target.element)
            NSRunningApplication(processIdentifier: target.pid)?.activate()
        } else {
            NSRunningApplication(processIdentifier: target.pid)?.activate()
            switch kind {
            case .left: AX.press(target)
            case .right: AX.rightClick(target)
            case .newTab: AX.cmdClick(target)
            }
        }
    }

    // ⌘Q / ⌘W / ⌘⇧W: fire the standard shortcut at the selected item's app (else the app we came
    // from). We're frontmost, so deliver the synthesized keys straight to that process.
    private func sendShortcut(keyCode: CGKeyCode, shift: Bool) {
        let pid = (matches.indices.contains(selected) ? matches[selected].pid : nil) ?? previousApp?.processIdentifier
        guard let pid else { return }
        dismiss(restoreFocus: false)
        NSRunningApplication(processIdentifier: pid)?.activate()
        AX.sendKey(keyCode: keyCode, shift: shift, toPid: pid)
    }

    // Move the hint selection. While a digit prefix is entered (e.g. "2" activating 2, 2x, 2xx),
    // move only within that narrowed candidate set so navigation stays inside what's shown.
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let candidates = hintBuffer.isEmpty
            ? Array(matches.indices)
            : matches.indices.filter { String($0 + 1).hasPrefix(hintBuffer) }
        guard !candidates.isEmpty else { return }
        let cur = candidates.firstIndex(of: selected) ?? 0
        selected = candidates[max(0, min(candidates.count - 1, cur + delta))]
        highlight?.selected = selected
        highlight?.needsDisplay = true
        menuListView?.selected = selected   // no-op unless `>` mode; draw() re-centres the scroll window
        menuListView?.needsDisplay = true
    }

    private func scrollSelected(pageUp: Bool) {
        let pid = matches.indices.contains(selected) ? matches[selected].pid : previousApp?.processIdentifier
        guard let pid else { return }
        AX.scroll(pid: pid, down: !pageUp)
        scheduleRescan()
    }

    // Browser/document history back (⌘[) / forward (⌘]) on the selected item's app (else the app we
    // came from). Delivered straight to the process; the page changes, so refresh hints afterwards.
    private func navigateHistory(forward: Bool) {
        let pid = (matches.indices.contains(selected) ? matches[selected].pid : nil) ?? previousApp?.processIdentifier
        guard let pid else { return }
        AX.sendKey(keyCode: forward ? 30 : 33, shift: false, toPid: pid)   // ⌘] / ⌘[
        scheduleRescan()
    }

    // Hide the (now-stale) overlay and rescan once movement has stopped for the configured delay
    // (debounced so rapid repeats coalesce into a single rescan).
    private func scheduleRescan() {
        highlight?.isHidden = true
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rescan() } }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.scrollRescanDelay, execute: work)
    }

    private func openPreferences() {
        dismiss(restoreFocus: false)
        settings.show()
    }

    // ⌘R: re-scan the current target (picked window, else current app) and refresh hints.
    private func rescan() {
        guard window != nil, let screen = primaryScreen else { return }
        if let win = targetWindow, let pid = previousApp?.processIdentifier {
            allHits = AX.scanWindow(win, appPid: pid, screen: screen.frame, expanded: expanded)
        } else {
            allHits = AX.scan(screen: screen.frame, frontApp: previousApp, expanded: expanded)
        }
        selected = 0; hintBuffer = ""
        highlight?.isHidden = false   // re-show hints hidden during scrolling
        refilter()
    }

    // ⌃I: focus the first text input among the scanned elements, then get out of the way.
    private func focusFirstInput() {
        guard let target = allHits.first(where: { $0.role == "AXTextField" || $0.role == "AXTextArea" }) else { return }
        dismiss(restoreFocus: false)
        NSRunningApplication(processIdentifier: target.pid)?.activate()
        AX.focus(target.element)
    }

    // MARK: - window picker

    private func showWindowPicker() {
        guard let container = window?.contentView, let panelGlass else { return }
        windows = Array(AX.windows().prefix(12))
        guard !windows.isEmpty else { return }
        windowSel = 0

        let pv = WindowPickerView(frame: .zero)
        pv.rows = windows.map(\.label)
        let size = NSSize(width: WindowPickerView.width, height: WindowPickerView.height(for: windows.count))
        let glass = Panel.makeGlass(pv, size: size)
        glass.frame.origin = NSPoint(x: panelGlass.frame.minX, y: panelGlass.frame.minY - size.height - 12)
        container.addSubview(glass)

        pickerView = pv; pickerGlass = glass
        highlight?.isHidden = true
        mode = .windowPicker
        updatePanelVisibility()   // double-⌘ means ⌘ is held — un-hide the panel for the picker
    }

    private func hideWindowPicker() {
        pickerGlass?.removeFromSuperview()
        pickerGlass = nil; pickerView = nil
        highlight?.isHidden = false
        mode = .search
        filter = .none; sticky = false; refilter()
    }

    private func moveWindowSel(_ delta: Int) {
        guard !windows.isEmpty else { return }
        windowSel = (windowSel + delta + windows.count) % windows.count   // wrap like the OS switcher
        pickerView?.selected = windowSel
        pickerView?.needsDisplay = true
    }

    private func confirmWindow() { selectWindow(windowSel) }

    private func selectWindow(_ index: Int) {
        guard windows.indices.contains(index), let screen = primaryScreen else { return }
        let entry = windows[index]
        hideWindowPicker()
        previousApp = NSRunningApplication(processIdentifier: entry.pid)
        targetWindow = entry.element
        AX.raise(entry.element)
        previousApp?.activate()
        expanded = false
        allHits = AX.scanWindow(entry.element, appPid: entry.pid, screen: screen.frame, expanded: expanded)
        matches = allHits; selected = 0; hintBuffer = ""
        panelView?.field.stringValue = ""
        refilter()
        regrabFocus()
    }

    // MARK: - focus / teardown

    private func onAppActivated(pid: pid_t) {
        guard window != nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        regrabFocus()
    }

    private func regrabFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let f = panelView?.field { window?.makeFirstResponder(f) }
    }

    private func dismiss(restoreFocus: Bool) {
        guard window != nil else { return }
        rescanWork?.cancel(); rescanWork = nil
        disableTap()
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil; highlight = nil; panelView = nil; panelGlass = nil
        pickerGlass = nil; pickerView = nil; windows = []; mode = .search
        menuListGlass = nil; menuListView = nil; source = .elements; sourceHits = []
        allHits = []; matches = []; selected = 0; hintBuffer = ""; cmdWasDown = false; filter = .none; sticky = false; expanded = false; modActive = false
        source = .elements; sourceHits = []
        if restoreFocus { previousApp?.activate() }
        previousApp = nil; targetWindow = nil
    }
}

// Detach from the terminal: re-launch a copy in its own session and let the parent exit,
// so `keyouse` from a shell returns the prompt immediately while the app keeps running.
if ProcessInfo.processInfo.environment["KEYOUSE_DETACHED"] == nil {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    var env = ProcessInfo.processInfo.environment
    env["KEYOUSE_DETACHED"] = "1"
    child.environment = env
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    child.standardInput = FileHandle.nullDevice
    do { try child.run() } catch { fputs("keyouse launch failed: \(error)\n", stderr) }
    exit(0)
}
setsid()   // new session, no controlling terminal -> survives the shell closing

// Single instance with takeover: the lock holder writes its pid into the file. A new launch that
// can't get the lock SIGTERMs that pid and waits for the lock to free — relaunching always ends
// with the fresh copy running. (fd stays open — the lock releases when the process ends.)
// ponytail: a lock from a pre-pid build can't be taken over; one manual `pkill keyouse` clears it.
let lockFD = open("\(NSTemporaryDirectory())keyouse.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 { exit(1) }
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    var buf = [CChar](repeating: 0, count: 32)
    pread(lockFD, &buf, 31, 0)
    let pid = pid_t(strtol(buf, nil, 10))
    if pid > 0 { kill(pid, SIGTERM) }
    var acquired = false
    for _ in 0..<40 {                    // up to ~2s for the old instance to exit
        if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
        usleep(50_000)
    }
    if !acquired { fputs("keyouse: another instance wouldn't yield the lock\n", stderr); exit(1) }
}
ftruncate(lockFD, 0)
_ = "\(getpid())".withCString { pwrite(lockFD, $0, strlen($0), 0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
