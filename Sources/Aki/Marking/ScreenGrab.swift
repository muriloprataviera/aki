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
    /// What appeared or vanished between two pictures of one screen (a menu that
    /// closed, a hover card): each solid patch of change, as fractions of the screen
    /// (top-left origin). Scattered changes don't count: a window going inactive dims
    /// its toolbar's words here and there, a caret blinks, a tooltip is a speck.
    static func changedRegions(_ a: CGImage, _ b: CGImage) -> [CGRect] {
        let width = 240, height = max(1, Int(CGFloat(width) * CGFloat(a.height) / CGFloat(max(a.width, 1))))
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height)
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return ok ? data : nil
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return [] }
        // Changed at all (a white menu over a light grey page differs by ~20), and
        // strongly (its words): a patch needs both.
        var changed = [Bool](repeating: false, count: width * height)
        var strong = [Bool](repeating: false, count: width * height)
        for k in 0..<(width * height) {
            let d = abs(Int(pa[k]) - Int(pb[k]))
            changed[k] = d > 12
            strong[k] = d > 40
        }
        // Patches: changed dots joined across gaps of up to 2 (words of one menu item).
        var seen = [Bool](repeating: false, count: width * height)
        var regions: [CGRect] = []
        for start in 0..<(width * height) where changed[start] && !seen[start] {
            var queue = [start], head = 0, count = 0, strongCount = 0
            var minX = width, minY = height, maxX = -1, maxY = -1
            seen[start] = true
            while head < queue.count {
                let k = queue[head]; head += 1
                let x = k % width, y = k / width
                count += 1
                if strong[k] { strongCount += 1 }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let n = ny * width + nx
                        if changed[n] && !seen[n] { seen[n] = true; queue.append(n) }
                    }
                }
            }
            let w = maxX - minX + 1, h = maxY - minY + 1
            // A menu: big enough and mostly changed inside (its background came or went).
            guard count >= 60, strongCount >= 20, w >= 8, h >= 6, Double(count) >= Double(w * h) * 0.3 else { continue }
            // Row 0 in memory is the picture's top.
            regions.append(CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                                  width: CGFloat(w) / CGFloat(width), height: CGFloat(h) / CGFloat(height)))
        }
        return regions
    }

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

    /// The app of the window under a point (global, top-left origin), with its window's
    /// title and, for a browser, its page: where a mark was made, whichever app was in
    /// front when marking began. Nil over nothing (or only Aki).
    /// `appName`: the app whose element was found there (the probe already settled
    /// which window is really on top; Orca's, shown on every Space, can list first).
    static func at(_ point: CGPoint, appName: String? = nil) -> MarkContext? {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let named = appName.flatMap { name in NSWorkspace.shared.runningApplications.first { $0.localizedName == name } }
        guard let window = windows.first(where: { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  named == nil || pid == named!.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame.contains(point)
        }), let pid = window[kCGWindowOwnerPID as String] as? Int32,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return nil }
        var context = MarkContext(appName: app.localizedName, bundleID: app.bundleIdentifier, pid: pid)
        context.windowTitle = window[kCGWindowName as String] as? String
        context.url = browserURL(bundleID: app.bundleIdentifier, windowTitle: context.windowTitle)
        return context
    }

    /// The front tab's address, asked over Apple Events (macOS asks once to allow it).
    /// With a window's title, that window's tab (not whichever window is in front).
    private static func browserURL(bundleID: String?, windowTitle: String? = nil) -> String? {
        let script: String
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
            "company.thebrowser.Browser":
            if let windowTitle, !windowTitle.isEmpty {
                let title = windowTitle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                script = """
                    tell application id "\(bundleID!)"
                      set found to (every window whose title is "\(title)")
                      if (count of found) > 0 then return URL of active tab of item 1 of found
                      return URL of active tab of front window
                    end tell
                    """
            } else {
                script = "tell application id \"\(bundleID!)\" to get URL of active tab of front window"
            }
        case "com.apple.Safari":
            script = "tell application id \"com.apple.Safari\" to get URL of front document"
        default:
            return nil
        }
        var error: NSDictionary?
        return NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
    }
}
