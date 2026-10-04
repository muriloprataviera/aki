import AkiCore
import AppKit

/// A terminal or editor where coding agents run. Aki isn't a terminal: it connects
/// to the ones you already use.
struct TerminalApp: Identifiable, Hashable {
    let id: String  // bundle identifier
    let name: String
    /// What Aki can do with it, for Settings.
    let reach: Reach

    enum Reach {
        /// Opens the exact tab of a session (Orca's CLI).
        case tab
        /// Brings the app forward; it can't be told which tab.
        case app
    }

    static let known: [TerminalApp] = [
        TerminalApp(id: "com.stablyai.orca", name: "Orca", reach: .tab),
        TerminalApp(id: "com.apple.Terminal", name: "Terminal", reach: .app),
        TerminalApp(id: "com.googlecode.iterm2", name: "iTerm2", reach: .app),
        TerminalApp(id: "dev.warp.Warp-Stable", name: "Warp", reach: .app),
        TerminalApp(id: "com.mitchellh.ghostty", name: "Ghostty", reach: .app),
        TerminalApp(id: "com.github.wez.wezterm", name: "WezTerm", reach: .app),
        TerminalApp(id: "net.kovidgoyal.kitty", name: "kitty", reach: .app),
        TerminalApp(id: "org.alacritty", name: "Alacritty", reach: .app),
        TerminalApp(id: "com.microsoft.VSCode", name: "VS Code", reach: .app),
        TerminalApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", reach: .app),
        TerminalApp(id: "com.exafunction.windsurf", name: "Windsurf", reach: .app),
        TerminalApp(id: "dev.zed.Zed", name: "Zed", reach: .app),
    ]

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    var isInstalled: Bool { url != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    var icon: NSImage? { url.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    static var installed: [TerminalApp] { known.filter(\.isInstalled) }

    /// The app a process runs in: the first ancestor that is a regular app.
    @MainActor static func owner(of pid: Int32) -> NSRunningApplication? {
        if let cached = owners[pid] { return cached }
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                owners[pid] = app
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        return nil
    }

    @MainActor private static var owners: [Int32: NSRunningApplication] = [:]

    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

/// Identity shown on a mark: its coding agent and the app hosting that session.
struct SessionIdentity {
    var agent: AgentSession.Agent?
    var appBundleID: String?
    var appName: String?

    @MainActor init(terminal: AgentTerminal) {
        agent = terminal.agent
        let app = TerminalApp.owner(of: terminal.pid)
        appBundleID = app?.bundleIdentifier
        appName = app?.localizedName
    }

    @MainActor init(annotation: Annotation, terminal: AgentTerminal?) {
        agent = terminal?.agent ?? annotation.destinationAgent
        let stored = annotation["terminal_app"]?.object
        let app = terminal.flatMap { TerminalApp.owner(of: $0.pid) }
        appBundleID = app?.bundleIdentifier ?? stored?["bundle_id"]?.string
        appName = app?.localizedName ?? stored?["name"]?.string
    }
}

extension AgentTerminal {
    /// Saved on new and explicitly moved marks; the marked app remains in `app`.
    @MainActor var identityFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["agent": .string(agent.rawValue), "session_name": .string(name), "terminal_app": .null]
        if let app = TerminalApp.owner(of: pid) {
            var host: [String: JSONValue] = [:]
            if let name = app.localizedName { host["name"] = .string(name) }
            if let id = app.bundleIdentifier { host["bundle_id"] = .string(id) }
            fields["terminal_app"] = .object(host)
        }
        return fields
    }
}
