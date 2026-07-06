import AppKit
import ApplicationServices

// Accessibility scanning: find clickable elements of the frontmost app plus the menu bar and
// Dock, keeping a live handle (and owning pid) for each so we can act on it later.

struct Hit {
    let element: AXUIElement
    let pid: pid_t
    let role: String
    let subrole: String
    let label: String
    let frame: CGRect   // AX/global coords: top-left origin
    var shortcut: String = ""   // "⌘S" for `>` menu-command mode; empty otherwise
}

struct WindowInfo {
    let element: AXUIElement
    let pid: pid_t
    let label: String
}

enum AX {
    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    static func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }

    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // ponytail: start narrow; widen when real apps miss things.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem",
        "AXMenuButton", "AXPopUpButton", "AXTextField", "AXTextArea", "AXTab",
        "AXMenuBarItem", "AXDockItem",   // macOS menu bar + Dock
    ]

    static func frame(of e: AXUIElement) -> CGRect? {
        guard let posVal = attr(e, kAXPositionAttribute as String),
              let sizeVal = attr(e, kAXSizeAttribute as String) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func label(of e: AXUIElement, role: String) -> String {
        if let t = str(e, kAXTitleAttribute as String), !t.isEmpty { return t }
        if let d = str(e, kAXDescriptionAttribute as String), !d.isEmpty { return d }
        if let v = str(e, kAXValueAttribute as String), !v.isEmpty { return v }
        // Composite pressables (Slack channel rows, clickable web divs) carry no label of their own —
        // the visible text lives in descendant static-text nodes. Gather it so search can match.
        let inner = descendantText(e, depth: 0)
        return inner.isEmpty ? role : inner
    }

    // ponytail: shallow (depth ≤ 6) — a row's label sits near the top; only walked for label-less hits.
    private static func descendantText(_ e: AXUIElement, depth: Int) -> String {
        guard depth <= 6, let children = attr(e, kAXChildrenAttribute as String) as? [AXUIElement] else { return "" }
        var parts: [String] = []
        for c in children {
            if let t = (str(c, kAXTitleAttribute as String) ?? str(c, kAXDescriptionAttribute as String)
                        ?? str(c, kAXValueAttribute as String)), !t.isEmpty {
                parts.append(t)
            } else if case let sub = descendantText(c, depth: depth + 1), !sub.isEmpty {
                parts.append(sub)
            }
        }
        return parts.joined(separator: " ")
    }

    // Window chrome (traffic lights, full-screen) — actionable but pure clutter; never a target.
    static let chromeSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]

    static func collect(_ e: AXUIElement, pid: pid_t, screen: CGRect, depth: Int, expanded: Bool, into hits: inout [Hit]) {
        if depth > 40 { return }   // ponytail: cap depth so a pathological tree can't hang the scan.
        let role = str(e, kAXRoleAttribute as String) ?? ""
        let subrole = str(e, kAXSubroleAttribute as String) ?? ""
        let f = frame(of: e)
        // Default scan is the role whitelist. Expanded scan (⌘S) also grabs anything with an AXPress
        // action — web/Electron use non-button roles (Slack channels, table rows, clickable divs) that
        // the whitelist misses. ponytail: actions() is an extra AX round-trip, so only fire it on the
        // role miss and only when expanded; nested pressables may overlap, typing-to-filter absorbs it.
        let pressable = actionableRoles.contains(role)
            || (expanded && !role.isEmpty && actions(e).contains("AXPress"))
        if pressable, !chromeSubroles.contains(subrole),
           let f, f.width > 0, f.height > 0, screen.intersects(f) {
            hits.append(Hit(element: e, pid: pid, role: role, subrole: subrole,
                            label: label(of: e, role: role), frame: f))
        }
        // Prune: a container whose (non-empty) frame is entirely off-screen can't hold visible
        // targets. ponytail: assumes children stay inside the parent frame — true enough for scans;
        // popovers/menus that escape it aren't reachable while our overlay is up anyway.
        if let f, !f.isEmpty, !screen.intersects(f) { return }
        for c in visibleChildren(e, role: role) {
            collect(c, pid: pid, screen: screen, depth: depth + 1, expanded: expanded, into: &hits)
        }
    }

    /// Children to descend into. Tables/outlines/lists expose EVERY row via AXChildren (a 50k-commit
    /// list in a git client = 50k rows × several sync AX round-trips each, freezing the target app's
    /// main thread), so prefer the visible-only attribute when the app provides it.
    private static func visibleChildren(_ e: AXUIElement, role: String) -> [AXUIElement] {
        let preferred = ["AXTable": "AXVisibleRows", "AXOutline": "AXVisibleRows",
                         "AXList": "AXVisibleChildren"][role]
        if let p = preferred, let v = attr(e, p) as? [AXUIElement], !v.isEmpty { return v }
        return attr(e, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    // Always-available targets: the menu bar's neighbours — Dock and menu-bar extras. Native roles,
    // so expanded doesn't apply.
    private static func collectExtras(screen: CGRect, into hits: inout [Hit]) {
        let extras = ["com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver"]
        for ra in NSWorkspace.shared.runningApplications
        where ra.bundleIdentifier.map(extras.contains) == true {
            collect(AXUIElementCreateApplication(ra.processIdentifier), pid: ra.processIdentifier,
                    screen: screen, depth: 0, expanded: false, into: &hits)
        }
    }

    /// Chromium (Chrome/Electron/Edge/Slack…) and Firefox don't build their web-content AX tree
    /// until an assistive tech asks. AXManualAccessibility is Electron-only and inert elsewhere, so
    /// it's set unconditionally. AXEnhancedUserInterface makes AppKit apps build heavier AX trees and
    /// glitches window-move animations (it also sticks after we exit), so it's scoped to browsers
    /// that need it for web content. ponytail: known-browser list; extend when one is missed.
    /// Fire-and-forget — if Chrome's first scan still comes back empty, the tree builds async.
    static let webBrowserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.mozilla.firefox",
    ]

    static func enableWebA11y(_ app: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           webBrowserBundleIDs.contains(bid) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Clickable elements across the target app (default: frontmost), its menu bar, and the
    /// Dock / menu extras.
    static func scan(screen: CGRect, frontApp: NSRunningApplication? = nil, expanded: Bool = false) -> [Hit] {
        var hits: [Hit] = []
        if let front = frontApp ?? NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            enableWebA11y(app, pid: pid)
            collect(app, pid: pid, screen: screen, depth: 0, expanded: expanded, into: &hits)
            if let mb = attr(app, kAXMenuBarAttribute as String) {
                collect(mb as! AXUIElement, pid: pid, screen: screen, depth: 0, expanded: expanded, into: &hits)
            }
        }
        collectExtras(screen: screen, into: &hits)
        return hits
    }

    /// Clickable elements of one specific window, plus its app's menu bar and the Dock / extras.
    static func scanWindow(_ window: AXUIElement, appPid: pid_t, screen: CGRect, expanded: Bool = false) -> [Hit] {
        var hits: [Hit] = []
        let app = AXUIElementCreateApplication(appPid)
        enableWebA11y(app, pid: appPid)
        collect(window, pid: appPid, screen: screen, depth: 0, expanded: expanded, into: &hits)
        if let mb = attr(app, kAXMenuBarAttribute as String) {
            collect(mb as! AXUIElement, pid: appPid, screen: screen, depth: 0, expanded: expanded, into: &hits)
        }
        collectExtras(screen: screen, into: &hits)
        return hits
    }

    /// Open, on-screen windows of regular apps (titles via AX — no screen-recording permission).
    static func windows() -> [WindowInfo] {
        var out: [WindowInfo] = []
        let mypid = ProcessInfo.processInfo.processIdentifier
        for ra in NSWorkspace.shared.runningApplications
        where ra.activationPolicy == .regular && ra.processIdentifier != mypid {
            let axApp = AXUIElementCreateApplication(ra.processIdentifier)
            guard let wins = attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            let appName = ra.localizedName ?? "?"
            for w in wins {
                guard let f = frame(of: w), f.width > 60, f.height > 60 else { continue }
                let title = str(w, kAXTitleAttribute as String) ?? ""
                let label = title.isEmpty ? appName : "\(appName) — \(title)"
                out.append(WindowInfo(element: w, pid: ra.processIdentifier, label: label))
            }
        }
        return out
    }

    /// Open windows as Hits (role "AXWindow") for the `/w` search mode — highlighted + numbered
    /// like elements; acting on one raises it. Only windows intersecting the primary screen.
    static func windowHits(screen: CGRect) -> [Hit] {
        var out: [Hit] = []
        let mypid = ProcessInfo.processInfo.processIdentifier
        for ra in NSWorkspace.shared.runningApplications
        where ra.activationPolicy == .regular && ra.processIdentifier != mypid {
            let axApp = AXUIElementCreateApplication(ra.processIdentifier)
            guard let wins = attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            let appName = ra.localizedName ?? "?"
            for w in wins {
                guard let f = frame(of: w), f.width > 60, f.height > 60, screen.intersects(f) else { continue }
                let title = str(w, kAXTitleAttribute as String) ?? ""
                let label = title.isEmpty ? appName : "\(appName) — \(title)"
                out.append(Hit(element: w, pid: ra.processIdentifier, role: "AXWindow", subrole: "", label: label, frame: f))
            }
        }
        return out
    }

    /// Tabs in the app's focused window (`/t` search mode): AXTab elements, radio buttons under an
    /// AXTabGroup, and anything with subrole AXTabButton (Safari). Acting = AXPress selects it.
    static func tabHits(pid: pid_t, screen: CGRect) -> [Hit] {
        let axApp = AXUIElementCreateApplication(pid)
        enableWebA11y(axApp, pid: pid)
        guard let winObj = attr(axApp, kAXFocusedWindowAttribute as String)
            ?? attr(axApp, kAXMainWindowAttribute as String) else { return [] }
        var out: [Hit] = []
        collectTabs(winObj as! AXUIElement, pid: pid, screen: screen, depth: 0, inTabGroup: false, into: &out)
        return out
    }

    private static func collectTabs(_ e: AXUIElement, pid: pid_t, screen: CGRect, depth: Int, inTabGroup: Bool, into hits: inout [Hit]) {
        if depth > 40 { return }
        let role = str(e, kAXRoleAttribute as String) ?? ""
        let here = inTabGroup || role == "AXTabGroup"
        // Safari's tabs are AXRadioButton with subrole AXTabButton under an AXOpaqueProviderGroup
        // (not an AXTabGroup), so honor that subrole anywhere in the tree.
        let isTab = role == "AXTab" || (here && role == "AXRadioButton")
            || str(e, kAXSubroleAttribute as String) == "AXTabButton"
        let f = frame(of: e)
        if isTab, let f, f.width > 0, f.height > 0, screen.intersects(f) {
            hits.append(Hit(element: e, pid: pid, role: role, subrole: "", label: label(of: e, role: role), frame: f))
        }
        if let f, !f.isEmpty, !screen.intersects(f) { return }   // same off-screen pruning as collect()
        for c in visibleChildren(e, role: role) {
            collectTabs(c, pid: pid, screen: screen, depth: depth + 1, inTabGroup: here, into: &hits)
        }
    }

    /// Every executable menu command of an app (`>` command-palette mode). Walks the full menu-bar
    /// tree — no on-screen frame (menus are closed), so these render as a list, not overlay badges.
    /// Acting = AXPress, which fires a leaf item even while its menu is closed (VoiceOver's mechanism).
    /// ponytail ceiling: apps that build menus lazily on open (some Electron) don't expose children
    /// until shown, so those commands simply won't be listed. Standard AppKit menus are fully present.
    static func menuCommandHits(pid: pid_t) -> [Hit] {
        let app = AXUIElementCreateApplication(pid)
        guard let mbAny = attr(app, kAXMenuBarAttribute as String) else { return [] }
        var out: [Hit] = []
        for barItem in (attr(mbAny as! AXUIElement, kAXChildrenAttribute as String) as? [AXUIElement] ?? []) {
            let title = str(barItem, kAXTitleAttribute as String) ?? ""
            if title == "Apple" { continue }   // ponytail: system-wide Apple menu, not the app's — skip.
            if let submenu = childMenu(of: barItem) {
                walkMenu(submenu, pid: pid, path: title, depth: 0, into: &out)
            }
        }
        return out
    }

    private static func childMenu(of item: AXUIElement) -> AXUIElement? {
        (attr(item, kAXChildrenAttribute as String) as? [AXUIElement])?
            .first { str($0, kAXRoleAttribute as String) == "AXMenu" }
    }

    private static func walkMenu(_ menu: AXUIElement, pid: pid_t, path: String, depth: Int, into out: inout [Hit]) {
        if depth > 12 { return }   // ponytail: real menus never nest this deep.
        for item in (attr(menu, kAXChildrenAttribute as String) as? [AXUIElement] ?? []) {
            let title = str(item, kAXTitleAttribute as String) ?? ""
            if title.isEmpty { continue }                       // separators
            if let sub = childMenu(of: item) {                  // has submenu -> descend
                walkMenu(sub, pid: pid, path: "\(path) › \(title)", depth: depth + 1, into: &out)
                continue
            }
            if (attr(item, kAXEnabledAttribute as String) as? Bool) == false { continue }
            guard actions(item).contains("AXPress") else { continue }
            out.append(Hit(element: item, pid: pid, role: "AXMenuItem", subrole: "",
                           label: "\(path) › \(title)", frame: .zero, shortcut: menuShortcut(item)))
        }
    }

    /// Format a menu item's key equivalent ("⌘S", "⌥⌘I"). Empty when there's none, or when it's a
    /// virtual-key-only shortcut (arrows/F-keys — ponytail: mapping that table isn't worth it).
    private static func menuShortcut(_ item: AXUIElement) -> String {
        guard let ch = str(item, "AXMenuItemCmdChar"), !ch.isEmpty else { return "" }
        let m = (attr(item, "AXMenuItemCmdModifiers") as? Int) ?? 0
        var s = ""
        if m & 4 != 0 { s += "⌃" }              // control
        if m & 2 != 0 { s += "⌥" }              // option
        if m & 1 != 0 { s += "⇧" }              // shift
        if m & 8 == 0 { s += "⌘" }              // command present unless the "no command" bit is set
        return s + ch.uppercased()
    }

    /// Synthesize a ⌘-based shortcut (⌘Q/⌘W/⌘⇧W) and deliver it straight to a process.
    static func sendKey(keyCode: CGKeyCode, shift: Bool, toPid pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = .maskCommand
        if shift { flags.insert(.maskShift) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            e.postToPid(pid)
        }
    }

    /// Bring a window to the front (its element handle stays valid regardless of focus).
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Move keyboard focus into an element (e.g. a text field).
    static func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func center(_ hit: Hit) -> CGPoint {
        CGPoint(x: hit.frame.midX, y: hit.frame.midY)   // CG global coords share AX's top-left origin
    }

    /// Left click: prefer AXPress (precise), fall back to a synthesized click.
    static func press(_ hit: Hit) {
        if actions(hit.element).contains("AXPress"),
           AXUIElementPerformAction(hit.element, "AXPress" as CFString) == .success {
            return
        }
        let p = center(hit)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// ⌘-click via synthesized events — opens links in a new tab in browsers ("open in new tab").
    /// Always synthesized (not AXPress) since the semantic needs the Command modifier held.
    static func cmdClick(_ hit: Hit) {
        let p = center(hit)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Right click via synthesized events (no standard AX action for this).
    static func rightClick(_ hit: Hit) {
        let p = center(hit)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        }
    }

    /// Largest AXScrollArea within an element (Vimac's approach). Skips AXWebArea (web content has
    /// no scroll-area child but scrolls fine via the wheel), and doesn't descend into scroll areas.
    static func largestScrollArea(_ root: AXUIElement) -> AXUIElement? {
        var best: AXUIElement?
        var bestArea: CGFloat = 0
        var stack = [root]
        var count = 0
        while let e = stack.popLast(), count < 5000 {
            count += 1
            let role = str(e, kAXRoleAttribute as String) ?? ""
            if role == "AXScrollArea" {
                if let f = frame(of: e), f.width * f.height > bestArea { bestArea = f.width * f.height; best = e }
                continue
            }
            if role == "AXWebArea" { continue }
            if let children = attr(e, kAXChildrenAttribute as String) as? [AXUIElement] { stack.append(contentsOf: children) }
        }
        return best
    }

    /// Scroll the app's focused window: find its scroll area, warp the cursor to its center, and
    /// post a wheel event to the HID tap — which scrolls whatever is under the cursor (Vimac's way).
    static func scroll(pid: pid_t, down: Bool) {
        let axApp = AXUIElementCreateApplication(pid)
        guard let winObj = attr(axApp, kAXFocusedWindowAttribute as String)
            ?? attr(axApp, kAXMainWindowAttribute as String) else { return }
        let win = winObj as! AXUIElement
        let target = largestScrollArea(win) ?? win
        guard let f = frame(of: target) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
        let amount = Int32(f.height / 3)                 // ~a third of the visible area per press
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: down ? -amount : amount, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}
