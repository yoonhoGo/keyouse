import AppKit
import ApplicationServices

// Accessibility scanning: find clickable elements of the frontmost app plus the menu bar and
// Dock, keeping a live handle (and owning pid) for each so we can act on it later.

struct Hit {
    let element: AXUIElement
    let pid: pid_t
    let role: String
    let label: String
    let frame: CGRect   // AX/global coords: top-left origin
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
        str(e, kAXTitleAttribute as String)
            ?? str(e, kAXDescriptionAttribute as String)
            ?? str(e, kAXValueAttribute as String)
            ?? role
    }

    static func collect(_ e: AXUIElement, pid: pid_t, screen: CGRect, depth: Int, into hits: inout [Hit]) {
        if depth > 40 { return }   // ponytail: cap depth so a pathological tree can't hang the scan.
        let role = str(e, kAXRoleAttribute as String) ?? ""
        if actionableRoles.contains(role),
           let f = frame(of: e), f.width > 0, f.height > 0,
           screen.intersects(f) {
            hits.append(Hit(element: e, pid: pid, role: role, label: label(of: e, role: role), frame: f))
        }
        if let children = attr(e, kAXChildrenAttribute as String) as? [AXUIElement] {
            for c in children { collect(c, pid: pid, screen: screen, depth: depth + 1, into: &hits) }
        }
    }

    /// Clickable elements across the frontmost app, its menu bar, and the Dock / menu extras.
    static func scan(screen: CGRect) -> [Hit] {
        var roots: [(AXUIElement, pid_t)] = []
        if let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            roots.append((app, pid))
            if let mb = attr(app, kAXMenuBarAttribute as String) { roots.append((mb as! AXUIElement, pid)) }
        }
        let extras = ["com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver"]
        for ra in NSWorkspace.shared.runningApplications
        where ra.bundleIdentifier.map(extras.contains) == true {
            roots.append((AXUIElementCreateApplication(ra.processIdentifier), ra.processIdentifier))
        }
        var hits: [Hit] = []
        for (root, pid) in roots { collect(root, pid: pid, screen: screen, depth: 0, into: &hits) }
        return hits
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
