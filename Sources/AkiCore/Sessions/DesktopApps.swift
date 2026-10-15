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

    /// Whether one of the app's own Codex conversations is in the middle of a turn.
    static func codexWorking(app pid: Int32, processes: [AgentSessions.Process]) -> Bool {
        codexLogs(app: pid, processes: processes).contains { CodexSessions.working(log: $0) }
    }

    /// The conversation open in the app, by name: the title of the page it shows (Claude
    /// adds " - Claude" to it), else its window's title when it names one (not just the
    /// app). Else none: the one written to last may not be the one open.
    static func conversationName(_ app: Found) -> String? {
        if let title = pageTitle(app.pid) { return title }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let generic = ["chatgpt", "codex", "claude", ""]
        if let title = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid && ($0[kCGWindowLayer as String] as? Int) == 0
                && !generic.contains((($0[kCGWindowName as String] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased())
        })?[kCGWindowName as String] as? String {
            return title.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    nonisolated(unsafe) private static var asked = Set<Int32>()
    private static let askedLock = NSLock()

    /// The title of the page in the app's front window (Electron apps show it to
    /// Accessibility once asked: asked once per run of the app, since every ask makes
    /// it build that all over again).
    static func pageTitle(_ pid: Int32) -> String? {
        let app = AXUIElementCreateApplication(pid)
        let first = askedLock.withLock { asked.insert(pid).inserted }
        if first {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let window = attribute(app, kAXFocusedWindowAttribute) ?? (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first,
              CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        // The pages sit a few levels down; their insides aren't searched.
        var queue = [window as! AXUIElement], seen = 0
        while !queue.isEmpty, seen < 200 {
            let node = queue.removeFirst()
            seen += 1
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" {
                var title = ((attribute(node, kAXTitleAttribute) as? String) ?? "").trimmingCharacters(in: .whitespaces)
                if title.hasSuffix(" - Claude") { title = String(title.dropLast(" - Claude".count)) }
                if !["", "claude", "chatgpt", "codex", "new chat", "nova conversa"].contains(title.lowercased()) { return title }
                continue
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
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
