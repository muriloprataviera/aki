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

    /// Whether one of the app's own Codex conversations is in the middle of a turn
    /// (its `codex app-server`, a process under the app, keeps their logs open).
    static func codexWorking(app pid: Int32, processes: [AgentSessions.Process]) -> Bool {
        let servers = processes.filter { $0.command.contains("codex") && $0.command.contains("app-server") }
            .filter { descends($0.pid, from: pid) }.map(\.pid)
        guard !servers.isEmpty else { return false }
        let logs = CodexSessions.openLogs(of: servers)
        return logs.values.joined().contains { CodexSessions.working(log: $0) }
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
