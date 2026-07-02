import AppKit
import ApplicationServices

// shott — hotkey -> Liquid Glass search panel -> filter by label / pick by number -> act.
// Trigger: ⌘⇧Space. Letters/Hangul go through the text field (IME); digits are hint selection.

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private var window: OverlayWindow?
    private var highlight: HighlightView?
    private var panelView: PanelView?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var allHits: [Hit] = []
    private var matches: [Hit] = []
    private var selected = 0
    private var hintBuffer = ""                 // digits typed to pick an element by number
    private var previousApp: NSRunningApplication?

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
        print("shott 준비됨. ⌘⇧Space 로 검색 패널을 여세요.")
    }

    private var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    private func activate() {
        if let w = window {                      // already open -> just refocus
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            if let f = panelView?.field { w.makeFirstResponder(f) }
            return
        }
        guard let screen = primaryScreen else { return }
        previousApp = NSWorkspace.shared.frontmostApplication   // to restore focus on cancel
        let hits = AX.scan(screen: screen.frame)
        guard !hits.isEmpty else { return }
        allHits = hits; matches = hits; selected = 0; hintBuffer = ""

        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = true              // let clicks/scroll pass through to apps beneath
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let hv = HighlightView(frame: container.bounds)
        hv.screenHeight = screen.frame.height
        hv.autoresizingMask = [.width, .height]
        container.addSubview(hv)

        let pv = PanelView(frame: .zero)
        pv.field.delegate = self
        let glass = Panel.makeGlass(pv)
        glass.frame.origin = NSPoint(x: (screen.frame.width - Panel.size.width) / 2,
                                     y: screen.frame.height * 0.38)
        container.addSubview(glass)

        w.contentView = container
        window = w; highlight = hv; panelView = pv

        refilter()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(pv.field)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let keyCode = e.keyCode
            let mods = e.modifierFlags
            let raw = e.charactersIgnoringModifiers
            switch keyCode {
            case 53, 36, 125, 126:
                MainActor.assumeIsolated { self?.handleControl(keyCode: keyCode, mods: mods) }
                return nil
            default:
                // Digits pick an element by its hint number; letters/Hangul flow to the field.
                if let ch = raw?.first, ch.isNumber,
                   !mods.contains(.option), !mods.contains(.control) {
                    let cmd = mods.contains(.command)
                    MainActor.assumeIsolated { self?.pushDigit(String(ch), rightClick: cmd) }
                    return nil
                }
                return e
            }
        }
    }

    // Filter as the field's text (including in-progress IME composition) changes.
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
        if cands.isEmpty { return }                    // invalid digit -> ignore
        hintBuffer = candidate
        if let idx = Int(candidate).map({ $0 - 1 }), matches.indices.contains(idx) { selected = idx }
        if cands.count == 1, cands[0] == candidate, let idx = Int(candidate).map({ $0 - 1 }) {
            act(on: idx, rightClick: rightClick)       // uniquely resolved -> fire
        } else {
            pushHighlights()
        }
    }

    private func handleControl(keyCode: UInt16, mods: NSEvent.ModifierFlags) {
        switch keyCode {
        case 53: dismiss(restoreFocus: true)                                   // Esc
        case 36: act(on: selected, rightClick: mods.contains(.command))        // Return
        case 125: mods.contains(.shift) ? scrollSelected(pageUp: false) : move(1)   // Down / ⇧Down scroll
        case 126: mods.contains(.shift) ? scrollSelected(pageUp: true) : move(-1)   // Up / ⇧Up scroll
        default: break
        }
    }

    private func act(on index: Int, rightClick: Bool) {
        guard matches.indices.contains(index) else { return }
        let target = matches[index]
        dismiss(restoreFocus: false)
        NSRunningApplication(processIdentifier: target.pid)?.activate()   // keep focus on the target app
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

    // Auto-dismiss when the panel loses focus (Spotlight-style).
    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }

    private func dismiss(restoreFocus: Bool) {
        guard window != nil else { return }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil; highlight = nil; panelView = nil
        allHits = []; matches = []; selected = 0; hintBuffer = ""
        if restoreFocus { previousApp?.activate() }
        previousApp = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
