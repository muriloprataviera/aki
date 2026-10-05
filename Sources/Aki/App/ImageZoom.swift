import AppKit

/// A mark's picture in its own window, to look closer: pinch (or ⌘-scroll) to zoom,
/// double-click between fit and 100 %, drag the scrollers to move around. Esc, the
/// close button or a click elsewhere closes it. Over the marking overlay too.
@MainActor
enum ImageZoom {
    private static var window: ZoomWindow?
    private static var resignObserver: Any?

    static var isOpen: Bool { window != nil }
    /// When it last closed: the click that closes it (on the marking overlay) isn't a mark.
    private(set) static var closedAt = Date.distantPast

    static func show(_ image: NSImage) {
        close()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        // As big as the picture, up to most of the screen.
        let room = area.insetBy(dx: area.width * 0.08, dy: area.height * 0.08)
        let size = image.size
        let fit = min(1, room.width / max(size.width, 1), room.height / max(size.height, 1))
        let content = NSSize(width: max(size.width * fit, 320), height: max(size.height * fit, 220))
        let frame = NSRect(x: area.midX - content.width / 2, y: area.midY - content.height / 2,
                           width: content.width, height: content.height)

        let window = ZoomWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        // Above the marking overlay (screen-saver level), which it's opened from.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let scroll = ZoomScrollView(frame: NSRect(origin: .zero, size: content))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .black
        scroll.drawsBackground = true
        scroll.allowsMagnification = true
        scroll.minMagnification = min(fit, 0.1)
        scroll.maxMagnification = 8
        scroll.fitMagnification = fit
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        scroll.documentView = imageView
        scroll.magnification = fit
        window.contentView = scroll

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        // A click anywhere else puts it away.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { close() }
        }
    }

    static func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if window != nil { closedAt = Date() }
        window?.orderOut(nil)
        window = nil
    }
}

private final class ZoomWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { ImageZoom.close() }
    override func performClose(_ sender: Any?) { ImageZoom.close() }
}

/// Double-click: fit ↔ 100 % at the point clicked. ⌘-scroll zooms, like a pinch.
private final class ZoomScrollView: NSScrollView {
    var fitMagnification: CGFloat = 1

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        let target: CGFloat = abs(magnification - fitMagnification) < 0.01 ? max(1, fitMagnification * 2) : fitMagnification
        animator().setMagnification(target, centeredAt: point)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: point)
    }
}
