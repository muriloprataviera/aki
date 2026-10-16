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
    /// one open (picked on the app's list if not), or nothing is sent. `conversation`: one
    /// of the app's conversations (its id and name), opened first by the app's own link.
    /// `again`: sent before but not confirmed: when Aki's message is still in the box,
    /// only sent from there (not pasted twice); when it isn't, pasted anew.
    static func deliver(to bundleID: String, session: String? = nil, conversation: (id: String, name: String)? = nil,
                        marks: [Annotation], again: Bool = false) async -> TerminalJump.Delivery {
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
            let result = await run(to: bundleID, session: session, conversation: conversation, marks: marks, again: again)
            delivering.remove(bundleID)
            lastFinished = Date()
            concealLater(bundleID)
            return result
        }
        queue = task
        return await task.value
    }

    private static func run(to bundleID: String, session: String?, conversation: (id: String, name: String)?,
                            marks: [Annotation], again: Bool) async -> TerminalJump.Delivery {
        // Without Accessibility its message box can't be found: said at once, not after a wait.
        guard AXIsProcessTrusted(), !marks.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return .failed }
        var text = AnnotationText.forApp(marks)
        var pictures = marks.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
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
        // A chosen conversation: opened by its link; the page it shows then is the one
        // everything goes into (checked before every paste and Enter, like a session).
        var page: String?
        if let conversation {
            guard let shown = await open(conversation: conversation, bundleID: bundleID, pid) else { return .failed }
            page = shown
        }
        func onPage() -> Bool {
            guard conversation != nil, let page else { return true }
            return DesktopApps.pageTitle(pid).map { showing($0, page) } ?? false
        }
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
        // The chosen session still the one open, now that its box was found.
        if let session, !(DesktopApps.pageTitle(pid).map { showing($0, session) } ?? false) { return .failed }
        guard onPage() else { return .failed }
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
        var header = String(text.prefix { $0 != "\n" })
        // Sent before but not confirmed (maybe in several goes): mark by mark, by the
        // codes on Aki's first lines. Those shown in the conversation went already;
        // those still in the box go with Enter; only the rest is pasted.
        var waiting = false
        if again {
            let code = { (mark: Annotation) in MarkFolder.code(mark.id) }
            let sent = codes(in: conversationLines(pid, besides: found))
            let boxed = codes(in: value(of: found) ?? "")
            // Only Aki's own marks, each with a code of its own here, are told apart by it
            // (another's "note_1" and "task_1" would both be "#1"): any other is sent again.
            let shared = Dictionary(grouping: marks, by: code).filter { $0.value.count > 1 }.keys
            let left = marks.filter {
                !($0.id.hasPrefix("aki_") && !shared.contains(code($0)) && sent.contains(code($0)))
            }
            if left.isEmpty { return .sent }
            let toPaste = left.filter { !($0.id.hasPrefix("aki_") && !shared.contains(code($0)) && boxed.contains(code($0))) }
            if toPaste.isEmpty {
                waiting = true
                // Its own first line, as it sits in the box.
                header = (value(of: found) ?? "").split(separator: "\n").map(String.init)
                    .first { $0.hasPrefix("📍 Aki:") && $0.contains("#" + code(left[0])) } ?? header
            } else {
                text = AnnotationText.forApp(toPaste)
                header = String(text.prefix { $0 != "\n" })
                pictures = toPaste.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
                    .compactMap { AnnotationImage.file(for: $0) }
            }
        }
        var box = found, pastedText = waiting
        func stillThere() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let now = messageBox(pid) else { return false }
            // Still the chosen session (you may have opened another meanwhile).
            if let session, !(DesktopApps.pageTitle(pid).map { showing($0, session) } ?? false) { return false }
            guard onPage() else { return false }
            if CFEqual(now, box) { return true }
            // The app drew the box anew right after the paste, with Aki's text in it: the
            // same box for what follows (another conversation's box wouldn't hold it).
            if pastedText, value(of: now)?.contains(header) == true { box = now; return true }
            return false
        }
        // What Aki last put there: anything you copied since stays yours.
        var ours = pasteboard.changeCount
        func restore() {
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        for picture in pictures where !waiting {
            let item = NSPasteboardItem()
            if let image = NSImage(contentsOf: picture), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
            item.setString(picture.absoluteString, forType: .fileURL)
            guard stillThere() else { restore(); return .failed }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            ours = pasteboard.changeCount
            pressPaste()
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard stillThere() else { restore(); return .failed }
        if !waiting {
            pasteboard.clearContents()
            // Something of yours already written there: Aki's text after a blank line.
            pasteboard.setString(isEmpty(box) == false ? "\n\n" + text : text, forType: .string)
            ours = pasteboard.changeCount
            pressPaste()
            pastedText = true
            try? await Task.sleep(for: .milliseconds(600))
        }
        defer { restore() }
        // Sent once the box is empty again. Pictures still uploading hold the send back:
        // Enter again, for up to about fifteen seconds.
        for _ in 0..<30 {
            // Gone elsewhere with it all in the box: not pasted again.
            guard stillThere() else { return .pasted }
            let before = value(of: box)
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
                    // you went to meanwhile. It may take a moment to show (up to five seconds:
                    // a new conversation of Codex's draws its first message slowly).
                    for _ in 0..<20 {
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
            // Return only made a new line in it (an app that sends with ⌘Return): no more
            // Returns piling blank lines into it; it waits there for you to send.
            case false?:
                if let before, let after = value(of: box), after.count > before.count,
                   after.trimmingCharacters(in: .whitespacesAndNewlines) == before.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return .pasted
                }
                continue
            }
        }
        // Still unsent after all that: it's all in the box, one Enter away. Not pasted
        // again (it would be there twice), and the marks stay open until it goes.
        return .pasted
    }

    /// Brings the app forward on that session (picked on its list), nothing pasted: a
    /// send already in its box goes on from there.
    static func reveal(_ session: String, in bundleID: String) async {
        // In the same line as the deliveries: switching sessions mid-paste would break one.
        let previous = queue
        let task = Task { @MainActor () -> TerminalJump.Delivery in
            _ = await previous?.value
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .failed }
            concealing[bundleID]?.cancel()
            concealing[bundleID] = nil
            exposeContents(app.processIdentifier)
            app.unhide()
            app.activate()
            try? await Task.sleep(for: .milliseconds(300))
            let shown = await open(session, app.processIdentifier)
            concealLater(bundleID)
            return shown ? .sent : .failed
        }
        queue = task
        _ = await task.value
    }

    /// Opens one of the app's conversations by its own link and waits for its page (by
    /// its title, up to six seconds). Another title or none (the link went nowhere, still
    /// loading, or you opened another one meanwhile): nothing is sent.
    /// Returns the title it shows ("" when it tells none), nil when not opened.
    private static func open(conversation: (id: String, name: String), bundleID: String, _ pid: pid_t) async -> String?? {
        guard let link = DesktopApps.link(to: conversation.id, in: bundleID), NSWorkspace.shared.open(link) else { return nil }
        try? await Task.sleep(for: .milliseconds(600))
        var title = DesktopApps.pageTitle(pid)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !(title.map { titled($0, conversation.name) } ?? false) {
            try? await Task.sleep(for: .milliseconds(200))
            title = DesktopApps.pageTitle(pid)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        // Its page not confirmed (no title, or another one): nothing is sent.
        guard let title, titled(title, conversation.name) else { return nil }
        return .some(title)
    }

    /// The page names that conversation: exactly, or with the app's own name beside it
    /// ("Revisar NFs no Drive - Codex"). Any other title is another conversation.
    private static func titled(_ title: String, _ name: String) -> Bool {
        if showing(title, name) { return true }
        let page = title.trimmingCharacters(in: .whitespacesAndNewlines), wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [" - ", " – ", " — ", " · ", " | "].contains { separator in
            // The conversation's name exactly (only the app's own name in any case).
            ["Codex", "ChatGPT", "Claude"].contains { app in
                [wanted + separator + app, app + separator + wanted].contains(page)
            }
        }
    }

    /// Brings the app forward on one of its conversations (by its link), nothing pasted.
    static func reveal(conversation id: String, in bundleID: String) async {
        let previous = queue
        let task = Task { @MainActor () -> TerminalJump.Delivery in
            _ = await previous?.value
            guard let link = DesktopApps.link(to: id, in: bundleID) else { return .failed }
            return NSWorkspace.shared.open(link) ? .sent : .failed
        }
        queue = task
        _ = await task.value
    }

    /// The same name, exactly (only the spaces around it aside): "🐛 Login" isn't "🚀 Login".
    private static func showing(_ title: String, _ session: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) == session.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the app shows `session` (its page's title), after picking it on the app's
    /// list when another is open. Up to a few seconds for the page to describe itself.
    private static func open(_ session: String, _ pid: pid_t) async -> Bool {
        func same(_ title: String?) -> Bool { title.map { showing($0, session) } ?? false }
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

        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 4000 {
            let node = queue.removeFirst()
            seen += 1
            // A row's name: its title, its description, or the text in it.
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .lazy.compactMap { attribute(node, $0) as? String }.first { !$0.isEmpty } ?? ""
            if !label.isEmpty, showing(label, name) {
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
    /// The codes on Aki's first lines in `text` ("📍 Aki: 2 marcas na tela (#a1b2, #c3d4).").
    static func codes(in text: String) -> Set<String> {
        var found = Set<String>()
        for line in text.split(separator: "\n") where line.hasPrefix("📍 Aki:") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            for code in line[line.index(after: open)..<close].split(separator: ",") {
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { found.insert(String(trimmed.dropFirst())) }
            }
        }
        return found
    }

    /// Every text shown in the app's window that holds one of Aki's first lines, but the box's.
    private static func conversationLines(_ pid: pid_t, besides box: AXUIElement) -> String {
        guard let window = focusedWindow(pid) else { return "" }
        var queue = [window], seen = 0, lines: [String] = []
        while !queue.isEmpty, seen < 4000 {
            let node = queue.removeFirst()
            seen += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXTextArea" || role as? String == "AXStaticText" {
                if !CFEqual(node, box), let text = value(of: node), text.contains("📍 Aki:") { lines.append(text) }
                if role as? String == "AXTextArea" { continue }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return lines.joined(separator: "\n")
    }

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
