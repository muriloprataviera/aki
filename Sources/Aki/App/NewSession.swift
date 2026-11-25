import AkiCore
import AppKit

/// A session opened from the marking card ("+ New"), with the marks as its first
/// message: Claude or Codex in a new Orca tab, or a new conversation in their apps.
/// No terminal to open first and then mark.
struct NewSession: Equatable {
    enum Kind: String, CaseIterable {
        case claudeOrca, codexOrca, claudeApp, codexApp

        var agent: AgentSession.Agent { self == .claudeOrca || self == .claudeApp ? .claude : .codex }
        /// Opened in a folder you pick (the Codex app's new conversation takes none).
        var needsFolder: Bool { self != .codexApp }
        var title: String {
            switch self {
            case .claudeOrca: L10n.t("Claude in Orca")
            case .codexOrca: L10n.t("Codex in Orca")
            case .claudeApp: L10n.t("Claude app")
            case .codexApp: L10n.t("Codex app")
            }
        }
    }

    var kind: Kind
    var folder: String?
    /// Its destination while marking. Claude in Orca: the id the session will have
    /// (`claude --session-id`), so its marks are already its own when it shows up.
    var id: String

    init(kind: Kind, folder: String?) {
        self.kind = kind
        self.folder = folder
        let uuid = UUID().uuidString.lowercased()
        id = kind == .claudeOrca ? uuid : NewSession.prefix + uuid
    }

    static let prefix = "new:"
    static let claudeApp = "com.anthropic.claudefordesktop"
    static let codexApp = "com.openai.codex"

    /// The destination it stands for until it's open.
    var terminal: AgentTerminal {
        let place = folder.map(NewSession.shortName) ?? kind.title
        return .opening(id: id, agent: kind.agent, name: "\(L10n.t("New")) · \(place)",
                        worktree: folder ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: What can be opened

    /// The kinds this Mac can open: Orca's with Orca (and not switched off), the apps when installed.
    @MainActor static var available: [Kind] {
        Kind.allCases.filter { kind in
            switch kind {
            case .claudeOrca, .codexOrca:
                FileManager.default.isExecutableFile(atPath: TerminalJump.orcaCLI)
                    && !Preferences.shared.disconnectedApps.contains("com.stablyai.orca")
                    // Its command in the terminal (while not known yet, offered: checked again on opening).
                    && commands.map { $0.contains(kind.agent.rawValue) } ?? true
            case .claudeApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeApp) != nil
            case .codexApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexApp) != nil
            }
        }
    }

    /// Orca's projects, last used first (read in the background when marking starts).
    @MainActor static var projects: [String] = []

    /// Which of `claude` and `codex` a terminal has (nil: not looked yet).
    @MainActor static var commands: Set<String>?

    /// Looked up as the terminal will (interactive login shell, .zshrc too); ten seconds
    /// at most (a .zshrc that asks something would never end).
    @MainActor static func lookUpCommands() async -> Set<String> {
        let found = await Task.detached { () -> Set<String> in
            guard let data = Command.output("/bin/zsh", ["-ilc", "for c in claude codex; do command -v $c >/dev/null && print -r -- AKICMD=$c; done"],
                                            timeout: 10, anyEnd: true),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return Set(text.split(separator: "\n").compactMap { line in
                line.hasPrefix("AKICMD=") ? String(line.dropFirst(7)) : nil
            })
        }.value
        commands = found
        return found
    }

    /// Reads Orca's projects again, plus the folders of the open sessions (for a Mac
    /// without Orca, or one Orca doesn't have).
    @MainActor static func refreshProjects(also folders: [String]) {
        if commands == nil { Task { _ = await lookUpCommands() } }
        Task {
            let orca: [(path: String, used: Double)] = await Task.detached {
                guard FileManager.default.isExecutableFile(atPath: TerminalJump.orcaCLI),
                      let data = Command.output(TerminalJump.orcaCLI, ["worktree", "list", "--json"], timeout: 5),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = (json["result"] as? [String: Any])?["worktrees"] as? [[String: Any]]
                else { return [] }
                return list.compactMap { w in
                    guard let path = w["path"] as? String, w["isArchived"] as? Bool != true else { return nil }
                    return (path, (w["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0)
                }
            }.value
            var seen = Set<String>()
            projects = (orca.sorted { $0.used > $1.used }.map(\.path) + folders)
                .filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
        }
    }

    /// "02_AKI/app": the folder with the one above it ("app" alone says little).
    static func shortName(_ path: String) -> String {
        let parts = URL(filePath: path).pathComponents.filter { $0 != "/" }
        return parts.suffix(2).joined(separator: "/")
    }

    // MARK: Opening

    /// One opening at a time: an app's new conversation is opened and filled before the
    /// next one opens (it would take the first one's place before the paste).
    @MainActor private static var chain: Task<String?, Never>?

    /// Opens it with `marks` (saved for it) as the first message: sent (Orca), or done once
    /// pasted in an app (which can't close them). Returns where later marks go now (the
    /// session it became), nil when it didn't open.
    /// `sessions`: the open sessions, looked at again, to find the new Codex one.
    @MainActor func open(with marks: [Annotation], store: AnnotationStore,
                         sessions: @escaping @MainActor () async -> [AgentTerminal]) async -> String? {
        let previous = Self.chain
        let task = Task { @MainActor in
            _ = await previous?.value
            return await run(with: marks, store: store, sessions: sessions)
        }
        Self.chain = task
        return await task.value
    }

    @MainActor private func run(with marks: [Annotation], store: AnnotationStore,
                                sessions: @MainActor () async -> [AgentTerminal]) async -> String? {
        guard !marks.isEmpty else { return nil }
        let opened: Bool
        let now = { ISO8601DateFormatter().string(from: Date()) }
        switch kind {
        case .claudeOrca, .codexOrca:
            guard let folder else { return nil }
            // Without the command the tab would only say "command not found": the marks stay unsent.
            var commands = Self.commands
            if commands == nil { commands = await Self.lookUpCommands() }
            guard commands?.contains(kind.agent.rawValue) == true else { return nil }
            let root = Worktree.root(of: folder)
            let before = Set(await sessions().filter { $0.agent == .codex && $0.worktree == root }.map(\.id))
            let prompt = Self.prompt(for: marks, name: terminal.name)
            let quotedPrompt = Self.quoted(prompt)
            let command = kind == .claudeOrca
                ? "claude --session-id \(id) \(quotedPrompt)"
                : "codex \(quotedPrompt)"
            let tab = await TerminalJump.openOrcaTerminal(in: folder, title: nil, command: "cd \(Self.quoted(folder)) && \(command)")
            guard tab.opened else { return nil }
            for mark in marks { _ = try? await store.update(mark.id, with: ["delivered_at": .string(now())]) }
            // Codex's session is known by its process ("codex:<pid>"): once it shows up
            // (up to thirty seconds), the marks become its own, so it lists and closes them.
            // Found by the tab Orca made (its process carries the tab's handle); without
            // one, only when it's the single new Codex in the folder (never a guess).
            guard kind == .codexOrca else { return id }
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1.5))
                let fresh = await sessions().filter { $0.agent == .codex && $0.worktree == root && !before.contains($0.id) }
                let mine = tab.handle.map { handle in fresh.filter { $0.orcaHandle == handle } } ?? fresh
                guard mine.count == 1, let new = mine.first else { continue }
                var fields = new.identityFields
                fields.merge(["session_id": .string(new.id), "worktree": .string(new.worktree)]) { _, new in new }
                for mark in marks { _ = try? await store.update(mark.id, with: fields) }
                return new.id
            }
            return id
        case .claudeApp:
            guard let folder, var link = URLComponents(string: "claude://code/new") else { return nil }
            link.queryItems = [URLQueryItem(name: "folder", value: folder)]
            opened = await openInApp(link.url, bundleID: Self.claudeApp, marks: marks)
        case .codexApp:
            opened = await openInApp(URL(string: "codex://threads/new"), bundleID: Self.codexApp, marks: marks)
        }
        guard opened else { return nil }
        // An app can't close them with `aki done`: once sent there, they're done (as for
        // any app conversation).
        for mark in marks {
            _ = try? await store.update(mark.id, with: ["delivered_at": .string(now()), "status": .string("completed")])
        }
        return DesktopApps.prefix + (kind == .claudeApp ? Self.claudeApp : Self.codexApp)
    }

    /// The app's new conversation by its own link, then the marks pasted and sent there.
    @MainActor private func openInApp(_ url: URL?, bundleID: String, marks: [Annotation]) async -> Bool {
        guard let url else { return false }
        return await AppDelivery.deliver(to: bundleID, link: url, marks: marks) == .sent
    }

    /// The same message a session gets when its marks go over: what they are, how to
    /// read them and how to close them.
    @MainActor static func prompt(for marks: [Annotation], name: String) -> String {
        let oldest = marks.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
        var places: [String] = []
        for a in oldest {
            let place: String? = a["url"]?.string.flatMap(URL.init(string:)).flatMap { u in
                u.host().map { $0 + (u.port.map { ":\($0)" } ?? "") }
            } ?? a["app"]?.object?["name"]?.string
            if let place, !places.contains(place) { places.append(place) }
        }
        var terminal = AgentTerminal.opening(id: "", agent: .claude, name: name, worktree: "")
        terminal.pending = marks.count
        terminal.undelivered = marks.count
        terminal.pendingIDs = oldest.map(\.id)
        terminal.pendingComments = oldest.reversed().prefix(3).map {
            $0["comment"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "(no text)"
        }
        terminal.pendingPlaces = places
        return TerminalJump.deliveryPrompt(for: terminal)
    }

    /// For the shell: in single quotes, its own quotes closed and reopened.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
