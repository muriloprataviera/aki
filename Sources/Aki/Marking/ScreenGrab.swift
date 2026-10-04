import AppKit
import ScreenCaptureKit

/// The screen as it was when marking started, plus what was in front of it.
struct ScreenGrab {
    let screen: NSScreen
    /// The whole display, in pixels.
    let image: CGImage

    /// Pixels per point on this display.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

    /// The part of the display inside `rect` (points, top-left origin within the screen).
    func crop(_ rect: CGRect) -> CGImage? {
        let pixels = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty else { return nil }
        return image.cropping(to: pixels)
    }

    /// Every display. Leaves out the given windows (marking's own overlays), or
    /// all of Aki's when none are given. Nil when Screen Recording isn't allowed.
    static func captureAll(excluding windowNumbers: Set<CGWindowID>? = nil) async -> [ScreenGrab]? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return nil
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        let ours = content.windows.filter {
            if let windowNumbers { return windowNumbers.contains($0.windowID) }
            return $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }
        var grabs: [ScreenGrab] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                let display = content.displays.first(where: { $0.displayID == number })
            else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: ours)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                grabs.append(ScreenGrab(screen: screen, image: image))
            }
        }
        return grabs
    }
}

/// What the user was looking at when marking started: the app in front, its
/// window's title, and the page address when it's a browser.
struct MarkContext {
    var appName: String?
    var bundleID: String?
    /// The app in front when marking began: its windows win under the pointer.
    var pid: pid_t?
    var windowTitle: String?
    var url: String?

    static func current() -> MarkContext {
        let app = NSWorkspace.shared.frontmostApplication
        var context = MarkContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier, pid: app?.processIdentifier)
        if let pid = app?.processIdentifier {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            context.windowTitle = windows.first {
                ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            }?[kCGWindowName as String] as? String
        }
        context.url = browserURL(bundleID: app?.bundleIdentifier)
        return context
    }

    /// The front tab's address, asked over Apple Events (macOS asks once to allow it).
    private static func browserURL(bundleID: String?) -> String? {
        let script: String
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
            "company.thebrowser.Browser":
            script = "tell application id \"\(bundleID!)\" to get URL of active tab of front window"
        case "com.apple.Safari":
            script = "tell application id \"com.apple.Safari\" to get URL of front document"
        default:
            return nil
        }
        var error: NSDictionary?
        return NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
    }
}
