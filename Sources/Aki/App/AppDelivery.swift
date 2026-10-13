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

    static func deliver(to bundleID: String, marks: [Annotation]) async -> TerminalJump.Delivery {
        let previous = queue
        let task = Task { @MainActor in
            _ = await previous?.value
            return await run(to: bundleID, marks: marks)
        }
        queue = task
        return await task.value
    }

    private static func run(to bundleID: String, marks: [Annotation]) async -> TerminalJump.Delivery {
        guard !marks.isEmpty, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return .failed }
        let text = AnnotationText.forApp(marks)
        let pictures = marks.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
            .compactMap { AnnotationImage.file(for: $0) }
        let pid = app.processIdentifier
        exposeContents(pid)
        app.activate()
        // In front, its window up (up to two seconds).
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .failed }
        try? await Task.sleep(for: .milliseconds(350))
        let pasteboard = NSPasteboard.general
        // Its contents may take a moment to show to Accessibility the first time.
        var box = messageBox(pid)
        for _ in 0..<3 where box == nil {
            try? await Task.sleep(for: .milliseconds(300))
            box = messageBox(pid)
        }
        guard let box else {
            // Not in its message box: the message waits on the clipboard.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .failed
        }
        let saved = savedItems(pasteboard)
        // Still in front, in that same box (not another conversation's): each paste and
        // Enter goes to whatever has the focus, so it's checked before every one.
        func stillThere() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && messageBox(pid).map { CFEqual($0, box) } == true
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
        pasteboard.setString(text, forType: .string)
        pressPaste()
        try? await Task.sleep(for: .milliseconds(600))
        defer { restore() }
        // Sent once the box is empty again. Pictures still uploading hold the send back:
        // Enter again, for up to about fifteen seconds.
        for _ in 0..<30 {
            guard stillThere() else { return .failed }
            press(36)  // Return
            try? await Task.sleep(for: .milliseconds(500))
            // A box that doesn't tell its text: taken as sent at the first Enter.
            if isEmpty(box) ?? true { return .sent }
        }
        // Still there, unsent: it stays in the box for you, and the marks stay waiting.
        return .failed
    }

    /// Electron apps tell Accessibility what's inside them only once asked to.
    static func exposeContents(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
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
        return role as? String == "AXTextArea" ? element : nil
    }

    /// Whether the box has nothing written in it (the message went); nil when it doesn't say.
    private static func isEmpty(_ box: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
