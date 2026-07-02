import AppKit
import ApplicationServices

// shott — hotkey -> Liquid Glass search panel -> filter by label / pick by number -> act.
// Trigger: ⌘⇧Space. While open, ⌘Tab drives shott's own window picker (a CGEventTap steals
// ⌘Tab from the system switcher); hold ⌘ and Tab / ⇧Tab / arrows to move, release ⌘ to choose.

// CGEventTap callback (top-level, C-compatible). Delegates to the controller on the main actor.
private func shottEventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
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
    private var localMonitor: Any?
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
    private lazy var settings = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("접근성 권한을 켠 뒤 다시 실행하세요: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용")
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let keyCode = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            MainActor.assumeIsolated {
                if keyCode == Settings.triggerKeyCode, mods == Settings.triggerModifiers { self?.activate() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.onAppActivated(pid: pid) }
        }
        print("shott 준비됨. ⌘⇧Space 로 검색 패널을 여세요.")
    }

    private var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    private func activate() {
        if window != nil { regrabFocus(); return }
        guard let screen = primaryScreen else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        targetWindow = nil
        let hits = AX.scan(screen: screen.frame)
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

        let pv = PanelView(frame: .zero)
        pv.field.delegate = self
        let glass = Panel.makeGlass(pv, size: Panel.size)
        glass.frame.origin = NSPoint(x: (screen.frame.width - Panel.size.width) / 2,
                                     y: screen.frame.height * 0.4)
        container.addSubview(glass)

        w.contentView = container
        window = w; highlight = hv; panelView = pv; panelGlass = glass

        refilter()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(pv.field)
        enableTap()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            if e.type == .flagsChanged {
                let cmd = e.modifierFlags.contains(.command)
                let ctrl = e.modifierFlags.contains(.control)
                MainActor.assumeIsolated { self?.setFilter(cmd: cmd, ctrl: ctrl) }
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
                                          callback: shottEventTapCallback, userInfo: selfPtr) else {
            print("⌘Tab 창전환용 이벤트 탭 생성 실패 — 입력 모니터링/손쉬운 사용 권한을 확인하세요.")
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
        if mods.contains(.command), keyCode == 37 { toggleLinksFilter(); return true }      // ⌘L links
        if mods.contains(.control), chars?.lowercased() == "i" { focusFirstInput(); return true } // ⌃I first input
        switch keyCode {
        case 53: dismiss(restoreFocus: true); return true
        case 36: act(on: selected, rightClick: mods.contains(.shift)); return true      // ⇧⏎ = right click
        case 125: mods.contains(.shift) ? scrollSelected(pageUp: false) : move(1); return true
        case 126: mods.contains(.shift) ? scrollSelected(pageUp: true) : move(-1); return true
        default:
            if let ch = chars?.first, ch.isNumber, !mods.contains(.option) {
                pushDigit(String(ch), rightClick: mods.contains(.shift)); return true    // ⇧+숫자 = right click
            }
            return false
        }
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
        let query = panelView?.query ?? ""
        var base = query.isEmpty ? allHits : allHits.filter { $0.label.localizedCaseInsensitiveContains(query) }
        switch filter {
        case .none: break
        case .controls: let v = Settings.cmdVisibleRoles; base = base.filter { v.contains($0.role) }
        case .forms: let v = Settings.ctrlVisibleRoles; base = base.filter { v.contains($0.role) }
        case .links: base = base.filter { $0.role == "AXLink" }
        }
        matches = base
        selected = min(selected, max(0, matches.count - 1))
        pushHighlights()
        panelView?.update(count: matches.count)
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
        highlight?.rects = matches.map(\.frame)
        highlight?.codes = matches.indices.map { String($0 + 1) }
        highlight?.typed = hintBuffer
        highlight?.selected = selected
        highlight?.needsDisplay = true
    }

    private func pushDigit(_ d: String, rightClick: Bool) {
        guard !matches.isEmpty else { return }
        let candidate = hintBuffer + d
        let numbers = matches.indices.map { String($0 + 1) }
        let cands = numbers.filter { $0.hasPrefix(candidate) }
        if cands.isEmpty { return }
        hintBuffer = candidate
        if let idx = Int(candidate).map({ $0 - 1 }), matches.indices.contains(idx) { selected = idx }
        if cands.count == 1, cands[0] == candidate, let idx = Int(candidate).map({ $0 - 1 }) {
            act(on: idx, rightClick: rightClick)
        } else {
            pushHighlights()
        }
    }

    private func act(on index: Int, rightClick: Bool) {
        guard matches.indices.contains(index) else { return }
        let target = matches[index]
        dismiss(restoreFocus: false)
        NSRunningApplication(processIdentifier: target.pid)?.activate()
        rightClick ? AX.rightClick(target) : AX.press(target)
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = max(0, min(matches.count - 1, selected + delta))
        highlight?.selected = selected
        highlight?.needsDisplay = true
    }

    private func scrollSelected(pageUp: Bool) {
        let pid = matches.indices.contains(selected) ? matches[selected].pid : previousApp?.processIdentifier
        guard let pid else { return }
        AX.scroll(pid: pid, down: !pageUp)
        // Debounce: rescan only once scrolling has stopped for 1s (handles rapid repeats).
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
            allHits = AX.scanWindow(win, appPid: pid, screen: screen.frame)
        } else {
            allHits = AX.scan(screen: screen.frame, frontApp: previousApp)
        }
        selected = 0; hintBuffer = ""
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
        allHits = AX.scanWindow(entry.element, appPid: entry.pid, screen: screen.frame)
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
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil; highlight = nil; panelView = nil; panelGlass = nil
        pickerGlass = nil; pickerView = nil; windows = []; mode = .search
        allHits = []; matches = []; selected = 0; hintBuffer = ""; cmdWasDown = false; filter = .none; sticky = false
        if restoreFocus { previousApp?.activate() }
        previousApp = nil; targetWindow = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
