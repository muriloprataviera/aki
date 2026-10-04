import AkiCore
import AppKit

/// Takes you to where a conversation runs: its tab in Orca (by matching the tab's
/// title, which Claude Code sets to the session's name, and its folder), or at
/// least the app that owns its process (Warp, Terminal, iTerm…).
enum TerminalJump {
    static let orcaCLI = "/Applications/Orca.app/Contents/Resources/bin/orca"

    static func log(_ text: String) {
        guard ProcessInfo.processInfo.environment["AKI_DEBUG_TARGETS"] == "1" else { return }
        FileHandle.standardError.write(Data("jump: \(text)\n".utf8))
    }

    /// The app a double-click on this conversation will bring forward.
    @MainActor static func destinationName(for terminal: AgentTerminal) -> String {
        TerminalApp.owner(of: terminal.pid)?.localizedName ?? "Terminal"
    }

    @MainActor static func go(to terminal: AgentTerminal, preferences: Preferences = .shared) {
        let owner = TerminalApp.owner(of: terminal.pid)?.bundleIdentifier
        log("go \(terminal.name) pid=\(terminal.pid) owner=\(owner ?? "nil") disconnected=\(preferences.disconnectedApps)")
        if let owner, preferences.disconnectedApps.contains(owner) { return }
        let useOrca = !preferences.disconnectedApps.contains("com.stablyai.orca")
        Task.detached {
            let handle = useOrca && FileManager.default.isExecutableFile(atPath: orcaCLI) ? orcaTab(for: terminal) : nil
            log("orca handle=\(handle ?? "nil")")
            if let handle {
                _ = run(orcaCLI, ["terminal", "switch", "--terminal", handle, "--json"])
                await MainActor.run { activateApp(bundleID: "com.stablyai.orca", fallbackPID: terminal.pid) }
                return
            }
            await MainActor.run { activateApp(bundleID: nil, fallbackPID: terminal.pid) }
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedTabs: (at: Date, tabs: [[String: Any]])?

    /// Orca's tab list, kept for a little while so a double-click jumps at once.
    static func orcaTabs(maxAge: TimeInterval = 20) -> [[String: Any]]? {
        if let cached = cacheLock.withLock({ cachedTabs }), Date().timeIntervalSince(cached.at) < maxAge {
            return cached.tabs
        }
        guard let data = run(orcaCLI, ["terminal", "list", "--json", "--limit", "200"]),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tabs = (json["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
        else { return nil }
        cacheLock.withLock { cachedTabs = (Date(), tabs) }
        return tabs
    }

    /// Fetches Orca's tabs in the background (when the pointer reaches the rings).
    static func prefetch() {
        guard FileManager.default.isExecutableFile(atPath: orcaCLI) else { return }
        Task.detached(priority: .utility) { _ = orcaTabs(maxAge: 8) }
    }

    /// The Orca terminal whose folder and title match the conversation.
    static func orcaTab(for terminal: AgentTerminal) -> String? {
        guard let tabs = orcaTabs() else { return nil }
        if let handle = terminal.orcaHandle {
            return tabs.first { ($0["handle"] as? String) == handle && ($0["worktreePath"] as? String) == terminal.worktree }?["handle"] as? String
        }
        let wanted = normalized(terminal.name)
        let sameFolder = tabs.filter { ($0["worktreePath"] as? String) == terminal.worktree }
        let match = sameFolder.first { normalized($0["title"] as? String ?? "") == wanted }
            ?? sameFolder.first { normalized($0["title"] as? String ?? "").hasPrefix(wanted) }
            ?? (sameFolder.count == 1 ? sameFolder.first : nil)
        return match?["handle"] as? String
    }

    /// Codex and other agents have no Claude registry name. Their exact tab's
    /// title distinguishes sessions that share a project, including after an IA switch.
    static func namedTerminals(_ terminals: [AgentTerminal]) -> [AgentTerminal] {
        guard terminals.contains(where: { $0.orcaHandle != nil }), let tabs = orcaTabs(maxAge: 3) else { return terminals }
        return terminals.map { terminal in
            guard let handle = terminal.orcaHandle,
                  let tab = tabs.first(where: { ($0["handle"] as? String) == handle && ($0["worktreePath"] as? String) == terminal.worktree }),
                  let title = tab["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return terminal }
            var named = terminal
            named.name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            named.named = true
            return named
        }
    }

    /// What Aki types into the session when its marks go over.
    static var deliveryPrompt: String {
        // The full path works in any conversation, even one opened before the MCP was added.
        let aki = Bundle.main.executablePath ?? "/Applications/Aki.app/Contents/MacOS/Aki"
        return "Tem marca nova do Aki para esta sessão. Leia com `'\(aki)' list` (ou read_annotations do MCP aki), resolva cada uma e, ao terminar cada uma, rode `'\(aki)' done <id>`."
    }

    enum Delivery { case sent, failed }

    /// Types the prompt (plus Enter) into the session's Orca tab. When you already
    /// have something written in its input box, Aki's text goes after a blank line,
    /// apart from yours, and both go together. `.failed` when the tab isn't found
    /// or Orca refuses.
    static func deliver(to terminal: AgentTerminal) async -> Delivery {
        guard FileManager.default.isExecutableFile(atPath: orcaCLI) else { return .failed }
        // Only a conversation that runs in Orca: one in Terminal or iTerm must never
        // be typed into an Orca tab that happens to share its folder.
        let inOrca = await MainActor.run {
            TerminalApp.owner(of: terminal.pid).map { $0.bundleIdentifier == "com.stablyai.orca" || $0.bundleURL?.lastPathComponent == "Orca.app" } ?? false
        }
        guard inOrca else { return .failed }
        return await Task.detached(priority: .userInitiated) {
            guard let handle = orcaTab(for: terminal) ?? { cacheLock.withLock { cachedTabs = nil }; return orcaTab(for: terminal) }()
            else { return .failed }
            let text = hasDraft(handle) ? "\n\n" + deliveryPrompt : deliveryPrompt
            return run(orcaCLI, ["terminal", "send", "--terminal", handle, "--text", text, "--enter", "--json"]) != nil
                ? .sent : .failed
        }.value
    }

    /// Whether the agent's input box (the "❯" / "›" line between the rules, as
    /// Claude Code and Codex draw it) already has text in it.
    static func hasDraft(_ handle: String) -> Bool {
        guard let data = run(orcaCLI, ["terminal", "read", "--terminal", handle, "--screen", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = ((json["result"] as? [String: Any])?["terminal"] as? [String: Any])?["tail"] as? [String]
        else { return false }
        return draft(in: lines) != nil
    }

    /// The text in the input box of a rendered agent screen, nil when it's empty.
    static func draft(in lines: [String]) -> String? {
        let prompts: [Character] = ["❯", "›", ">"]
        // The last prompt line that sits right under a rule.
        guard let start = lines.indices.last(where: { i in
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            return i > 0 && line.first.map(prompts.contains) == true
                && lines[i - 1].trimmingCharacters(in: .whitespaces).hasPrefix("─")
        }) else { return nil }
        var text = String(lines[start].trimmingCharacters(in: .whitespaces).dropFirst())
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("─") { break }
            text += "\n" + line
        }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude Code's grey suggestion when the box is empty.
        if typed.isEmpty || typed.hasPrefix("Try \"") { return nil }
        return typed
    }

    /// Drops the status mark Claude Code puts before the title ("✳ ", "◑ ").
    static func normalized(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Brings Orca (by bundle id) or else the GUI app that owns the process forward.
    @MainActor static func activateApp(bundleID: String?, fallbackPID: Int32) {
        if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.lastPathComponent == "Orca.app" })
        {
            app.activate()
            return
        }
        var pid = fallbackPID
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                app.activate()
                return
            }
            guard let parent = parentPID(of: pid), parent > 1 else { return }
            pid = parent
        }
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
