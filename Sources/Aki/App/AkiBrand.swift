import AppKit

/// Aki's marks in one place: the app icon (read from the bundle, so an icon the
/// Mac cached from an older build never shows), and the pin drawn as a template
/// for the menu bar.
enum AkiBrand {
    /// The pin icon from this build's own file.
    static let appIcon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage

    /// The pin (speech-bubble with the dot), as a template image: the bar colours it.
    static func pin(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            // The brand path lives in a 16…66 box (aki-pin.svg): scale it into the rect.
            let s = rect.width / 52, ox = -16 * s, oy = -14 * s
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }
            let shape = NSBezierPath()
            shape.appendOval(in: NSRect(x: ox + 18 * s, y: oy + 16 * s, width: 48 * s, height: 48 * s))
            let tail = NSBezierPath()
            tail.move(to: p(29, 58)); tail.line(to: p(18, 65)); tail.line(to: p(24, 52)); tail.close()
            shape.append(tail)
            NSColor.black.setFill()
            shape.fill()
            // The dot, cut out.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: ox + 34 * s, y: oy + 32 * s, width: 16 * s, height: 16 * s)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Whether Aki shows in the Dock and ⌘Tab. As set in Settings (menu bar by
/// default), except while one of its windows (Settings, History) is open: then
/// it's a regular app you can ⌘Tab to, and it steps back when the last one closes.
@MainActor
enum AppWindows {
    static func refresh() {
        let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        let wanted: NSApplication.ActivationPolicy = open ? .regular : Preferences.shared.presence.activationPolicy
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }
}
