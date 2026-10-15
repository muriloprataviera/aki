import AkiCore
import AppKit
import ApplicationServices

/// Delivery to an agent's desktop app (Codex's, Claude's): the app comes forward and
/// the marks' pictures and text are pasted into the conversation open in it, then sent.
/// Only into its message box: elsewhere nothing is typed (the text stays on the
/// clipboard, to paste by hand).
@MainActor
enum AppDelivery {
    /// One delivery at a time: two would take the focus and the clipboard from each other.
    private static var queue: Task<TerminalJump.Delivery, Never>?
    private static var lastFinished = Date.distantPast

    /// `session`: the name of one of the app's sessions (its Code tab): it has to be the
    /// one open (picked on the app's list if not), or nothing is sent.
    static func deliver(to bundleID: String, session: String? = nil, marks: [Annotation]) async -> TerminalJump.Delivery {
        let previous = queue
        let task = Task { @MainActor in
            // Right after another one, the app is still redrawing its conversation (its
            // answer starting): a moment for it to settle. Only then.
            _ = await previous?.value
            let since = Date().timeIntervalSince(lastFinished)
            if since < 1.5 { try? await Task.sleep(for: .seconds(1.5 - since)) }
            // A switch-off still pending would come in the middle of this one.
            concealing[bundleID]?.cancel()
            concealing[bundleID] = nil
            delivering.insert(bundleID)
            let result = await run(to: bundleID, session: session, marks: marks)
            delivering.remove(bundleID)
            lastFinished = Date()
            concealLater(bundleID)
            return result
        }
        queue = task
        return await task.value
    }

    private static func run(to bundleID: String, session: String?, marks: [Annotation]) async -> TerminalJump.Delivery {
        guard !marks.isEmpty, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return .failed }
        let text = AnnotationText.forApp(marks)
        let pictures = marks.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
            .compactMap { AnnotationImage.file(for: $0) }
        let pid = app.processIdentifier
        exposeContents(pid)
        app.unhide()
        app.activate()
        // In front, its window up (up to two seconds).
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try? await Task.sleep(for: .milliseconds(50))
        }
        func front() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        // Its window minimized, closed with the app still open, or not up yet (it just
        // opened): brought back, like clicking it in the Dock (up to four seconds more).
        if !front() || focusedWindow(pid) == nil {
            showWindow(app)
            for _ in 0..<80 where !front() || focusedWindow(pid) == nil { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard front() else { return .failed }
        // A chosen session: the one open, or picked on the app's list; never another one.
        if let session, await !open(session, pid) { return .failed }
        try? await Task.sleep(for: .milliseconds(350))
        let pasteboard = NSPasteboard.general
        // Its contents may take several seconds to show to Accessibility the first time
        // (an app that just opened is still loading its page).
        // The focus elsewhere (a menu button, after a dialog closed): into the window's
        // message box, the lowest one (the conversation's, not a side panel's).
        var candidate = messageBox(pid)
        let patience = Date().addingTimeInterval(12)
        var asked = Date()
        while candidate == nil, Date() < patience {
            // Asked again now and then, in case it came before its window was up: not
            // every time, since each ask makes the app build it all over again.
            if Date().timeIntervalSince(asked) > 4 { exposeContents(pid); asked = Date() }
            if let found = composer(pid) {
                AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(250))
                candidate = messageBox(pid)
                if candidate != nil { break }
            }
            try? await Task.sleep(for: .milliseconds(300))
            candidate = messageBox(pid)
        }
        guard let found = candidate else {
            // Not in its message box: the message waits on the clipboard.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .failed
        }
        let saved = savedItems(pasteboard)
        // Still in front, in that same box (not another conversation's): each paste and
        // Enter goes to whatever has the focus, so it's checked before every one.
        // Aki's first line ("📍 Aki: 2 marks…"): how its message is told apart from
        // anything else written in a box or shown in the conversation.
        let header = String(text.prefix { $0 != "\n" })
        var box = found, pastedText = false
        func stillThere() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let now = messageBox(pid) else { return false }
            if CFEqual(now, box) { return true }
            // The app drew the box anew right after the paste, with Aki's text in it: the
            // same box for what follows (another conversation's box wouldn't hold it).
            if pastedText, value(of: now)?.contains(header) == true { box = now; return true }
            return false
        }
        func restore() {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        for picture in pictures {
            let item = NSPasteboardItem()
            if let image = NSImage(contentsOf: picture), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
            item.setString(picture.absoluteString, forType: .fileURL)
            guard stillThere() else { restore(); return .failed }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            pressPaste()
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard stillThere() else { restore(); return .failed }
        pasteboard.clearContents()
        // Something of yours already written there: Aki's text after a blank line.
        pasteboard.setString(isEmpty(box) == false ? "\n\n" + text : text, forType: .string)
        pressPaste()
        pastedText = true
        try? await Task.sleep(for: .milliseconds(600))
        defer { restore() }
        // Sent once the box is empty again. Pictures still uploading hold the send back:
        // Enter again, for up to about fifteen seconds.
        for _ in 0..<30 {
            // Gone elsewhere with it all in the box: not pasted again.
            guard stillThere() else { return .pasted }
            press(36)  // Return
            try? await Task.sleep(for: .milliseconds(500))
            // A new conversation moves on to its own page once sent: another message
            // box, empty, in the same app.
            // (It may be between pages for a moment: looked for again, up to a second.)
            for _ in 0..<4 where NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                if let now = messageBox(pid) ?? composer(pid) {
                    guard !CFEqual(now, box) else { break }
                    guard isEmpty(now) == true else { return .pasted }
                    // Only once Aki's message (its first line names these very marks) shows
                    // in the conversation: an empty box alone could be another conversation
                    // you went to meanwhile. It may take a moment to show (up to two seconds).
                    for _ in 0..<8 {
                        if shows(header, pid, besides: now) { return .sent }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    return .pasted
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            switch isEmpty(box) {
            case true?: return .sent
            // A box that doesn't tell its text: no proof it went, so not counted as done.
            case nil: return .pasted
            case false?: continue
            }
        }
        // Still unsent after all that: it's all in the box, one Enter away. Not pasted
        // again (it would be there twice), and the marks stay open until it goes.
        return .pasted
    }

    /// Whether the app shows `session` (its page's title), after picking it on the app's
    /// list when another is open. Up to a few seconds for the page to describe itself.
    private static func open(_ session: String, _ pid: pid_t) async -> Bool {
        func same(_ title: String?) -> Bool {
            guard let title else { return false }
            return TerminalJump.normalized(title) == TerminalJump.normalized(session)
        }
        var title = DesktopApps.pageTitle(pid)
        for _ in 0..<30 where title == nil {
            try? await Task.sleep(for: .milliseconds(200))
            title = DesktopApps.pageTitle(pid)
        }
        if same(title) { return true }
        guard let item = listItem(named: session, pid) else { return false }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(200))
            if same(DesktopApps.pageTitle(pid)) { return true }
        }
        return false
    }

    /// Something pressable in the app's window named exactly `name` (a session on its list).
    private static func listItem(named name: String, _ pid: pid_t) -> AXUIElement? {
        guard let window = focusedWindow(pid) else { return nil }
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let wanted = TerminalJump.normalized(name)
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 4000 {
            let node = queue.removeFirst()
            seen += 1
            // A row's name: its title, its description, or the text in it.
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .lazy.compactMap { attribute(node, $0) as? String }.first { !$0.isEmpty } ?? ""
            if !label.isEmpty, TerminalJump.normalized(label) == wanted {
                // The row itself, or the first parent that can be pressed.
                var current: AXUIElement? = node
                for _ in 0..<4 {
                    guard let element = current else { break }
                    var actions: CFArray?
                    if AXUIElementCopyActionNames(element, &actions) == .success,
                       (actions as? [String])?.contains(kAXPressAction) == true { return element }
                    current = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
                }
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
    }

    /// Electron apps tell Accessibility what's inside them only once asked to: Claude's
    /// by the first flag, Codex's only by the second.
    static func exposeContents(_ pid: pid_t) {
        DesktopApps.expose(pid, true)
    }

    /// The apps being delivered to now.
    private static var delivering = Set<String>()

    /// Whether Aki is using that app's description now, or will in a moment: marking
    /// leaves it on (a delivery switches it off itself, a minute after).
    static func holds(_ pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return delivering.contains(id) || concealing[id] != nil
    }

    /// Each app's switch-off to come.
    private static var concealing = [String: Task<Void, Never>]()

    /// Left on, the app keeps rebuilding that description at every word of its answers
    /// and the whole Mac slows down: off again a minute after its last delivery.
    private static func concealLater(_ bundleID: String) {
        concealing[bundleID]?.cancel()
        concealing[bundleID] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            concealing[bundleID] = nil
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                DesktopApps.expose(app.processIdentifier, false)
            }
        }
    }

    /// The app's focused message box: a multi-line text area (a search or a title field
    /// is a one-line text field), nil when the focus is anywhere else.
    static func messageBox(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard role as? String == "AXTextArea" else { return nil }
        // The message box sits in the conversation (at the bottom, or in the middle of a
        // new one); other multi-line fields (a project's instructions, a settings box)
        // open in a dialog of their own.
        guard !inDialog(element) else { return nil }
        // And the conversation's own box, the lowest one: not a past message being
        // edited in place, higher up (pasting there would send that edit again).
        if let lowest = composer(pid), !CFEqual(lowest, element) { return nil }
        return element
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return (window as! AXUIElement)
    }

    /// Its first minimized window back; with none at all, the app asked to reopen one
    /// (like clicking it in the Dock).
    private static func showWindow(_ app: NSRunningApplication) {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
        if let first = (windows as? [AXUIElement])?.first {
            AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        } else if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        app.activate()
    }

    /// The front window's message box when the focus isn't in it: the lowest
    /// multi-line text area outside any dialog.
    private static func composer(_ pid: pid_t) -> AXUIElement? {
        guard let window = focusedWindow(pid) else { return nil }
        var queue = [window], best: (element: AXUIElement, bottom: CGFloat)?, seen = 0
        while !queue.isEmpty, seen < 4000 {
            let node = queue.removeFirst()
            seen += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXTextArea" {
                if !inDialog(node), let bottom = bottom(of: node), bottom > (best?.bottom ?? -.infinity) { best = (node, bottom) }
                continue
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return best?.element
    }

    private static func bottom(of element: AXUIElement) -> CGFloat? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0
        else { return nil }
        return origin.y + extent.height
    }

    /// Inside a sheet or a dialog (a native one, or one the page draws).
    private static func inDialog(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let node = current else { return false }
            var role: CFTypeRef?, subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole)
            if role as? String == "AXWindow" { return subrole as? String != "AXStandardWindow" && subrole != nil }
            if role as? String == "AXSheet" || (subrole as? String)?.contains("Dialog") == true { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        return value as? String
    }

    /// Whether the front window shows `line` outside the message box `box`: a message in
    /// the conversation (its text; any other text area holding it counts too).
    private static func shows(_ line: String, _ pid: pid_t, besides box: AXUIElement) -> Bool {
        guard let window = focusedWindow(pid) else { return false }
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 4000 {
            let node = queue.removeFirst()
            seen += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXTextArea" {
                if !CFEqual(node, box), value(of: node)?.contains(line) == true { return true }
                continue
            }
            if role as? String == "AXStaticText", value(of: node)?.contains(line) == true { return true }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return false
    }

    /// Whether the box has nothing written in it (the message went); nil when it doesn't say.
    private static func isEmpty(_ box: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if written.isEmpty { return true }
        // Some boxes tell their hint ("Ask ChatGPT") as their text while empty.
        for hint in [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute] {
            var label: CFTypeRef?
            if AXUIElementCopyAttributeValue(box, hint as CFString, &label) == .success,
               (label as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == written { return true }
        }
        return false
    }

    private static func savedItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private static func pressPaste() { press(9, command: true) }  // ⌘V

    private static func press(_ key: CGKeyCode, command: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = command ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
    }
}
