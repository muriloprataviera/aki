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
    /// Asked many times a second (the sidebar's rings): the answer is kept, "none" too
    /// (half a minute: a session started by Claude's own service has no app at all), and
    /// an app that has quit is asked again.
    @MainActor static func owner(of pid: Int32) -> NSRunningApplication? {
        if let cached = owners[pid] {
            if let app = cached.app, !app.isTerminated { return app }
            if cached.app == nil, Date().timeIntervalSince(cached.at) < 30 { return nil }
        }
        if owners.count > 500 { owners.removeAll() }
        let found = lookUpOwner(of: pid)
        owners[pid] = (found, Date())
        return found
    }

    @MainActor private static func lookUpOwner(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            // A helper inside an app's bundle ("Orca.app/…/Orca Helper"): that app, even
            // when the helper outlived its parent (Orca restarted, its tabs kept running).
            if let app = enclosingApp(of: current) { return app }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        return nil
    }

    /// The running app whose bundle holds this process's executable, if any.
    @MainActor private static func enclosingApp(of pid: Int32) -> NSRunningApplication? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = URL(filePath: String(path[..<range.lowerBound]) + ".app").standardizedFileURL
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL == bundle
        }
    }

    @MainActor private static var owners: [Int32: (app: NSRunningApplication?, at: Date)] = [:]

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
