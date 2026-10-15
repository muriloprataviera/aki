import ApplicationServices
import CoreGraphics
import Foundation

/// The desktop apps of the agents (Codex's and Claude's own apps): no terminal, so Aki
/// pastes into the conversation open in them. One destination per app.
public enum DesktopApps {
    /// The apps Aki delivers to, by bundle id.
    public static let known: [String: AgentSession.Agent] = [
        "com.openai.codex": .codex,
        "com.anthropic.claudefordesktop": .claude,
    ]

    /// Ids of these destinations: "app:<bundle id>".
    public static let prefix = "app:"

    public static func bundleID(of terminalID: String) -> String? {
        terminalID.hasPrefix(prefix) ? String(terminalID.dropFirst(prefix.count)) : nil
    }

    /// An app's bundle (".../ChatGPT.app") from its main process's command line, when that
    /// is the app's own executable (not one of its helpers).
    static func bundle(of command: String) -> String? {
        guard let range = command.range(of: ".app/Contents/MacOS/") else { return nil }
        let path = String(command[..<range.lowerBound]) + ".app"
        // Helpers live deeper (".../Frameworks/X Helper.app/..."): only the outer app.
        guard !path.dropLast(4).contains(".app/") else { return nil }
        return path
    }

    struct Found { let pid: Int32; let bundleID: String; let path: String; let name: String }

    /// The known apps running now, from the process list.
    static func running(in processes: [AgentSessions.Process]) -> [Found] {
        var found: [String: Found] = [:]
        for process in processes {
            guard let path = bundle(of: process.command), found.values.allSatisfy({ $0.path != path }),
                  let info = Bundle(path: path)?.infoDictionary,
                  let id = info["CFBundleIdentifier"] as? String, known[id] != nil
            else { continue }
            // The app's main process: the one whose executable is the bundle's own.
            let executable = info["CFBundleExecutable"] as? String ?? ""
            guard process.command.hasPrefix(path + "/Contents/MacOS/" + executable) else { continue }
            if found[id] == nil {
                found[id] = Found(pid: process.pid, bundleID: id, path: path, name: known[id] == .codex ? "Codex app" : "Claude app")
            }
        }
        return Array(found.values).sorted { $0.bundleID < $1.bundleID }
    }

    /// The logs of the app's own Codex conversations (its `codex app-server`, a
    /// process under the app, keeps them open).
    static func codexLogs(app pid: Int32, processes: [AgentSessions.Process]) -> [URL] {
        let servers = processes.filter { $0.command.contains("codex") && $0.command.contains("app-server") }
            .filter { descends($0.pid, from: pid) }.map(\.pid)
        guard !servers.isEmpty else { return [] }
        return Array(CodexSessions.openLogs(of: servers).values.joined())
    }

    /// The logs the Codex app has open now (its conversations), for the History.
    public static func openCodexLogs(app pid: Int32) -> [URL] {
        codexLogs(app: pid, processes: AgentSessions.runningProcesses())
    }

    /// Whether one of the app's own Codex conversations is in the middle of a turn.
    static func codexWorking(app pid: Int32, processes: [AgentSessions.Process]) -> Bool {
        codexLogs(app: pid, processes: processes).contains { CodexSessions.working(log: $0) }
    }

    /// The conversation open in the app, by name: the title of the page it shows (Claude
    /// adds " - Claude" to it), else its window's title when it names one (not just the
    /// app). Else none: the one written to last may not be the one open.
    static func conversationName(_ app: Found) -> String? {
        // Looked at every 15 s at most (it was every pass, inside the app's window).
        let now = Date()
        if let recent = titlesLock.withLock({ () -> String?? in
            guard let last = looked[app.pid], now.timeIntervalSince(last.at) < 15 else { return nil }
            return .some(last.name)
        }) { return recent }
        let name = currentName(app) ?? titlesLock.withLock { titles[app.pid] }
        titlesLock.withLock { looked[app.pid] = (now, name) }
        return name
    }

    private static func currentName(_ app: Found) -> String? {
        if let title = pageTitle(app.pid) {
            titlesLock.withLock { titles[app.pid] = title }
            return title
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let generic = ["chatgpt", "codex", "claude", ""]
        if let title = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid && ($0[kCGWindowLayer as String] as? Int) == 0
                && !generic.contains((($0[kCGWindowName as String] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased())
        })?[kCGWindowName as String] as? String {
            return title.trimmingCharacters(in: .whitespaces)
        }
        // Neither shows now (its page is described only around a delivery): the last seen.
        return nil
    }

    nonisolated(unsafe) private static var looked = [Int32: (at: Date, name: String?)]()

    /// The conversation names last seen in each app (its page shows them only while
    /// Aki is delivering to it, see `expose`).
    nonisolated(unsafe) private static var titles = [Int32: String]()
    private static let titlesLock = NSLock()

    /// Asks an Electron app to describe its page to Accessibility (Claude's by the first
    /// flag, Codex's by the second), or to stop. Only while delivering: described, the app
    /// rebuilds that at every word of an answer and slows the whole Mac down.
    public static func expose(_ pid: Int32, _ on: Bool) {
        let app = AXUIElementCreateApplication(pid)
        let value = on ? kCFBooleanTrue : kCFBooleanFalse
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, value!)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, value!)
    }

    /// Versions up to 0.8.0-beta.4 left the apps described for good: undone once, when Aki starts.
    public static func concealAll() {
        guard AXIsProcessTrusted() else { return }
        for app in running(in: AgentSessions.runningProcesses()) { expose(app.pid, false) }
    }

    /// The title of the page in the app's front window, when it shows (around a
    /// delivery). Never asks the app to show it.
    public static func pageTitle(_ pid: Int32) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let window = attribute(app, kAXFocusedWindowAttribute) ?? (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first,
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        // The page sits a few levels down; its insides aren't searched.
        var queue = [window as! AXUIElement], seen = 0
        while !queue.isEmpty, seen < 60 {
            let node = queue.removeFirst()
            seen += 1
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" {
                var title = ((attribute(node, kAXTitleAttribute) as? String) ?? "").trimmingCharacters(in: .whitespaces)
                if title.hasSuffix(" - Claude") { title = String(title.dropLast(" - Claude".count)) }
                return ["", "claude", "chatgpt", "codex", "new chat", "nova conversa"].contains(title.lowercased()) ? nil : title
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
    }

    /// The app is answering: its processes (the page's renderer above all) busy, from the
    /// same process list. Cheap: the app is never asked anything.
    static func answering(_ app: Found, processes: [AgentSessions.Process]) -> Bool {
        let inside = app.path + "/Contents/"
        let cpu = processes.filter { $0.command.hasPrefix(inside) }.reduce(0) { $0 + $1.cpu }
        return cpu >= 12
    }

    private static func descends(_ pid: Int32, from ancestor: Int32) -> Bool {
        var current = pid
        for _ in 0..<12 {
            guard let parent = ClaudeSessions.parentPID(of: current), parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}
