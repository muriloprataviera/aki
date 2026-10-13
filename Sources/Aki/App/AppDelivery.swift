import AkiCore
import AppKit
import ApplicationServices

/// Delivery to an agent's desktop app (Codex's, Claude's): the app comes forward and
/// the marks' pictures and text are pasted into the conversation open in it, then sent.
/// Only into a text box that has the focus: elsewhere nothing is typed (the text stays
/// on the clipboard, to paste by hand).
@MainActor
enum AppDelivery {
    static func deliver(to bundleID: String, marks: [Annotation]) async -> TerminalJump.Delivery {
        guard !marks.isEmpty, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return .failed }
        let text = AnnotationText.forApp(marks)
        let pictures = marks.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
            .compactMap { AnnotationImage.file(for: $0) }
        exposeContents(app.processIdentifier)
        app.activate()
        // In front, its window up (up to two seconds).
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return .failed }
        try? await Task.sleep(for: .milliseconds(350))
        let pasteboard = NSPasteboard.general
        // Its contents may take a moment to show to Accessibility the first time.
        var inText = typingIntoText(app.processIdentifier)
        for _ in 0..<3 where !inText {
            try? await Task.sleep(for: .milliseconds(300))
            inText = typingIntoText(app.processIdentifier)
        }
        guard inText else {
            // Not in its message box: the message waits on the clipboard.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .failed
        }
        let saved = savedItems(pasteboard)
        for picture in pictures {
            let item = NSPasteboardItem()
            if let image = NSImage(contentsOf: picture), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
            item.setString(picture.absoluteString, forType: .fileURL)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            pressPaste()
            try? await Task.sleep(for: .milliseconds(500))
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pressPaste()
        // Pictures upload before the message can go: a moment more for each.
        try? await Task.sleep(for: .milliseconds(600 + 400 * pictures.count))
        press(36)  // Return
        try? await Task.sleep(for: .milliseconds(300))
        // What you had copied comes back.
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        return .sent
    }

    /// Electron apps tell Accessibility what's inside them only once asked to.
    static func exposeContents(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Whether the app's focus is in a text box (its message box).
    static func typingIntoText(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role) { return true }
        // A page's editable block (contenteditable) says so in its own attribute.
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
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
