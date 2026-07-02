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

    private var mode: Mode = .search
    private var windows: [WindowInfo] = []
    private var windowSel = 0
    private var pickerGlass: NSView?
    private var pickerView: WindowPickerView?
    private var cmdWasDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print("접근성 권한을 켠 뒤 다시 실행하세요: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용")
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let keyCode = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .shift])
            MainActor.assumeIsolated {
                if keyCode == 49, mods == [.command, .shift] { self?.activate() }
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

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
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
        switch keyCode {
        case 53: dismiss(restoreFocus: true); return true
        case 36: act(on: selected, rightClick: mods.contains(.command)); return true
        case 125: mods.contains(.shift) ? scrollSelected(pageUp: false) : move(1); return true
        case 126: mods.contains(.shift) ? scrollSelected(pageUp: true) : move(-1); return true
        default:
            if let ch = chars?.first, ch.isNumber, !mods.contains(.option), !mods.contains(.control) {
                pushDigit(String(ch), rightClick: mods.contains(.command)); return true
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
        matches = query.isEmpty
            ? allHits
            : allHits.filter { $0.label.localizedCaseInsensitiveContains(query) }
        selected = min(selected, max(0, matches.count - 1))
        pushHighlights()
        panelView?.update(count: matches.count)
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
        disableTap()
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil; highlight = nil; panelView = nil; panelGlass = nil
        pickerGlass = nil; pickerView = nil; windows = []; mode = .search
        allHits = []; matches = []; selected = 0; hintBuffer = ""; cmdWasDown = false
        if restoreFocus { previousApp?.activate() }
        previousApp = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
