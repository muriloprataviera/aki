import AppKit

/// The Orca tab you're typing in, so the sidebar's destination follows your clicks there.
/// Orca has no command for it: Aki reads it through Accessibility (the same permission
/// marking uses). The terminal with the keyboard sits in a pane; the pane's tab is the
/// highlighted one right above it. Anything unsure gives nil, and nil changes nothing.
enum OrcaFocus {
    static let bundleID = "com.stablyai.orca"

    /// The title of the focused tab while Orca is in front, else nil.
    @MainActor static func focusedTabTitle() -> String? {
        guard let orca = NSWorkspace.shared.frontmostApplication, orca.bundleIdentifier == bundleID else { return nil }
        let app = AXUIElementCreateApplication(orca.processIdentifier)
        // Orca draws with Chromium: its tree is built only when asked for.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let input = element(app, "AXFocusedUIElement"),
              (string(input, "AXDescription") ?? "") == "Terminal input",
              let pane = ancestor(of: input, withClass: "pane")
        else { return nil }
        let paneFrame = frame(pane)
        // Climb until the tab strip shows up, then keep the highlighted tab over this pane.
        var node = pane
        for _ in 0..<8 {
            guard let parent = element(node, "AXParent") else { return nil }
            node = parent
            var tabs: [AXUIElement] = []
            collectTabs(node, depth: 0, into: &tabs)
            guard !tabs.isEmpty else { continue }
            let over = tabs.filter { tab in
                let f = frame(tab)
                let classes = (copy(tab, "AXDOMClassList") as? [String]) ?? []
                return !classes.contains("text-muted-foreground")
                    && f.minX >= paneFrame.minX - 1 && f.maxX <= paneFrame.maxX + 1
                    && f.maxY <= paneFrame.minY + 1 && f.maxY >= paneFrame.minY - 60
            }
            guard over.count == 1, let title = string(over[0], "AXTitle"),
                  let range = title.range(of: "Close tab ", options: .backwards)
            else { return nil }
            let name = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Tab buttons ("… Close tab NAME"), not their own small close buttons ("Close tab").
    private static func collectTabs(_ e: AXUIElement, depth: Int, into tabs: inout [AXUIElement]) {
        guard depth < 12, tabs.count < 60 else { return }
        if string(e, "AXRole") == "AXButton", let title = string(e, "AXTitle"), title.contains("Close tab ") {
            tabs.append(e)
            return
        }
        for child in (copy(e, "AXChildren") as? [AXUIElement]) ?? [] { collectTabs(child, depth: depth + 1, into: &tabs) }
    }

    private static func ancestor(of e: AXUIElement, withClass name: String) -> AXUIElement? {
        var node = e
        for _ in 0..<10 {
            guard let parent = element(node, "AXParent") else { return nil }
            node = parent
            if ((copy(node, "AXDOMClassList") as? [String]) ?? []).contains(name) { return node }
        }
        return nil
    }

    private static func copy(_ e: AXUIElement, _ key: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
    }

    private static func string(_ e: AXUIElement, _ key: String) -> String? { copy(e, key) as? String }

    private static func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = copy(e, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ e: AXUIElement) -> CGRect {
        var point = CGPoint.zero, size = CGSize.zero
        if let v = copy(e, "AXPosition"), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &point) }
        if let v = copy(e, "AXSize"), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }
}
