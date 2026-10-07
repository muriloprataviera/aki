import AppKit
import ApplicationServices

/// What's under the pointer while marking, the way Vibe Annotations outlines DOM
/// elements: a UI element of the app below (button, field, a web page's div —
/// browsers expose their DOM classes to Accessibility), or the window itself
/// when Accessibility isn't allowed.
struct ProbedElement: Equatable {
    /// Global screen rect, top-left origin (CoreGraphics space).
    var frame: CGRect
    /// Short label for the outline: "div.navbar-container", "Button “Save”", "Orca — window".
    var label: String
    var role: String?
    var title: String?
    var domID: String?
    var domClasses: [String] = []
    var appName: String?
    /// The elements containing this one, innermost first (↑ selects them).
    var ancestors: [ProbedElement] = []
    /// Something smaller inside it that ↓ reaches (a line of words in a menu item),
    /// when it isn't shown first.
    var finer: [ProbedElement] = []
    /// A web page's component source ("src/components/Menu.tsx:42"), when the
    /// browser could tell (React dev builds).
    var source: String?
    /// Found by asking a browser page (the arrow keys can walk its elements).
    var fromBrowser = false
    /// A CSS selector that finds just this element on the page (checked there).
    var selector: String?
    /// The start of its HTML, for the agent to recognise it in the code.
    var html: String?
}

enum ElementProbe {
    /// Whether Aki may look inside other apps' windows.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt to allow Accessibility (once).
    static func askForAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The element at a global point (top-left origin), skipping Aki's own windows.
    static func element(at point: CGPoint, preferring front: pid_t? = nil) -> ProbedElement? {
        // The apps you have open come first; the menu bar, status items and floating
        // panels only when no app window is under the pointer. Among the apps, the one
        // you were in when marking began goes first (a window shown on every Space,
        // like Orca's, can list before it).
        let all = windowsBelow(point)
        var apps = all.filter { $0.layer == 0 }
        if let front, let i = apps.firstIndex(where: { $0.pid == front }) { apps.insert(apps.remove(at: i), at: 0) }
        // Floating panels above the apps (a side panel like Codenotch's): theirs is the
        // answer when they hand back a real item, not their whole (mostly see-through) window.
        if isTrusted, !apps.isEmpty {
            for window in all where window.layer > 0 && window.frame.minY > 0 {
                if let element = accessibilityElement(pid: window.pid, at: point, appName: window.appName),
                   !(abs(element.frame.width - window.frame.width) < 4 && abs(element.frame.height - window.frame.height) < 4),
                   element.role != "AXWindow", element.role != "window" {
                    return element
                }
            }
        }
        for window in apps.isEmpty ? all : apps {
            // A browser page: ask the page itself (exact element, classes, source).
            if window.layer == 0, BrowserProbe.isBrowser(window.pid), !onBrowserBar(window, point) {
                // A browser: the page answers (once more if it was slow). Accessibility
                // only sees one big "ScrollArea" there, so it's never used for pages.
                for _ in 0..<2 {
                    switch BrowserProbe.element(
                        at: point, pid: window.pid, windowFrame: window.frame,
                        title: window.title.flatMap { $0.isEmpty ? nil : $0 }, appName: window.appName)
                    {
                    case .element(let element): return element
                    case .background: return nil  // empty space of a big block: no outline
                    case .unavailable: continue
                    case .outside: browserBars[window.pid] = point.y
                    }
                    break
                }
                if browserBars[window.pid] != nil, isTrusted,
                   let element = accessibilityElement(pid: window.pid, at: point, appName: window.appName) {
                    return element
                }
                return nil
            }
            if isTrusted, let element = accessibilityElement(pid: window.pid, at: point, appName: window.appName) {
                // A floating panel answering with itself is usually its transparent
                // part (a big empty overlay): look further down instead.
                let isWholePanel = window.layer != 0
                    && abs(element.frame.width - window.frame.width) < 4 && abs(element.frame.height - window.frame.height) < 4
                if !isWholePanel { return element }
            }
            if window.layer == 0 {
                return ProbedElement(
                    frame: window.frame,
                    label: [window.appName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "),
                    role: "window", title: window.title, appName: window.appName)
            }
        }
        return nil
    }

    /// Per browser, a point the page said was on its bar (tabs, address bar): from
    /// then on, points that high in that window go straight to Accessibility.
    nonisolated(unsafe) private static var browserBars: [pid_t: CGFloat] = [:]

    private static func onBrowserBar(_ window: WindowInfo, _ point: CGPoint) -> Bool {
        guard let bar = browserBars[window.pid] else { return false }
        return point.y <= max(bar, window.frame.minY + 40) && point.y - window.frame.minY < 140
    }

    private struct WindowInfo {
        var pid: pid_t
        var frame: CGRect
        var layer: Int
        var appName: String?
        var title: String?
    }

    /// Windows under the point, front to back, that aren't Aki's or the desktop.
    private static func windowsBelow(_ point: CGPoint) -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < 1000,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01
            else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.contains(point), frame.width > 4, frame.height > 4 else { return nil }
            return WindowInfo(
                pid: pid, frame: frame, layer: layer, appName: info[kCGWindowOwnerName as String] as? String,
                title: info[kCGWindowName as String] as? String)
        }
    }

    private static let enabledLock = NSLock()
    nonisolated(unsafe) private static var enabledPIDs: Set<pid_t> = []

    /// Electron and Chromium apps (Orca, VS Code, Slack…) only build their
    /// accessibility tree when someone asks; ask once per app.
    private static func wakeAccessibility(_ app: AXUIElement, pid: pid_t) {
        guard enabledLock.withLock({ enabledPIDs.insert(pid).inserted }) else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func accessibilityElement(pid: pid_t, at point: CGPoint, appName: String?) -> ProbedElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        wakeAccessibility(app, pid: pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
            var element = hit
        else { return nil }
        // Chrome often answers with a big container (the page, a dialog): go down
        // through the children to the smallest one under the point.
        element = deepest(under: point, from: element)
        // Tiny leaves (a text run inside a label) say little: climb to something sizeable.
        for _ in 0..<4 {
            guard let frame = frame(of: element), frame.width < 24 || frame.height < 14,
                let parent: AXUIElement = value(element, kAXParentAttribute)
            else { break }
            element = parent
        }
        guard var probed = describe(element, appName: appName) else { return nil }
        // The containers around it, each a little bigger, for ↑ / ↓.
        var current = element
        var last = probed.frame
        for _ in 0..<10 {
            guard let parent: AXUIElement = value(current, kAXParentAttribute) else { break }
            current = parent
            guard let outer = describe(parent, appName: appName) else { continue }
            if (outer.role ?? "") == "AXApplication" { break }
            // Skip wrappers the same size as what they hold.
            if abs(outer.frame.width - last.width) < 4 && abs(outer.frame.height - last.height) < 4 { continue }
            probed.ancestors.append(outer)
            last = outer.frame
        }
        return probed
    }

    private static func deepest(under point: CGPoint, from start: AXUIElement) -> AXUIElement {
        var element = start
        for _ in 0..<25 {
            guard let children: [AXUIElement] = value(element, kAXChildrenAttribute), children.count <= 400 else { break }
            let inside = children.compactMap { child -> (AXUIElement, CGRect)? in
                guard let frame = frame(of: child), frame.width > 2, frame.height > 2, frame.contains(point) else { return nil }
                return (child, frame)
            }
            // The topmost one (last drawn) when siblings overlap, e.g. a modal over the page.
            guard let next = inside.last else { break }
            element = next.0
        }
        return element
    }

    private static func describe(_ element: AXUIElement, appName: String?) -> ProbedElement? {
        guard let frame = frame(of: element), frame.width > 2, frame.height > 2 else { return nil }
        let role: String? = value(element, kAXRoleAttribute)
        // A password field's value is never read (the screen shows only dots).
        let secure = (value(element, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole
        let title = (value(element, kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
            ?? (value(element, kAXDescriptionAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
            ?? (secure ? nil : (value(element, kAXValueAttribute) as String?).flatMap { $0.isEmpty || $0.count > 60 ? nil : $0 })
        let domID: String? = value(element, "AXDOMIdentifier")
        let classes: [String] = (value(element, "AXDOMClassList") as [String]?) ?? []
        return ProbedElement(
            frame: frame, label: label(role: role, title: title, domID: domID, classes: classes),
            role: role, title: title, domID: domID.flatMap { $0.isEmpty ? nil : $0 }, domClasses: classes, appName: appName)
    }

    /// "div#main.navbar" for web content, "Button “Save”" for native controls.
    private static func label(role: String?, title: String?, domID: String?, classes: [String]) -> String {
        if let domID, !domID.isEmpty || !classes.isEmpty {
            let tag = webTag(role)
            let id = domID.isEmpty ? "" : "#\(domID)"
            return tag + id + classes.prefix(2).map { ".\($0)" }.joined()
        }
        if !classes.isEmpty { return webTag(role) + classes.prefix(2).map { ".\($0)" }.joined() }
        let kind = (role ?? "AXElement").replacingOccurrences(of: "AX", with: "")
        if let title { return "\(kind) “\(title.prefix(40))”" }
        return kind
    }

    private static func webTag(_ role: String?) -> String {
        switch role {
        case "AXButton": "button"
        case "AXLink": "a"
        case "AXImage": "img"
        case "AXTextField", "AXTextArea": "input"
        case "AXHeading": "h"
        case "AXList": "ul"
        case "AXStaticText": "span"
        default: "div"
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
            let size: AXValue = value(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
