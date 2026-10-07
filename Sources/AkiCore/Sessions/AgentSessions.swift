import Foundation

/// A worktree with coding agents open in it, as shown in the sidebar.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public enum Agent: String, CaseIterable, Sendable { case claude, codex, gemini, grok, opencode, cursor }

    public var id: String { worktree }
    public var worktree: String
    public var branch: String?
    public var agents: [Agent]
    /// An `aki wait` is running here: the agent picks up new marks by itself.
    public var listening: Bool
    /// An agent here is using CPU right now.
    public var working: Bool
    public var pending: Int
    /// Comments of the latest pending marks, newest first (up to 3).
    public var pendingComments: [String] = []

    public var name: String { URL(filePath: worktree).lastPathComponent }
}

/// Finds running agents (`claude`, `codex`) and groups them by worktree.
public enum AgentSessions {
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var cpu: Double
        public var command: String
    }

    public enum Kind: Equatable, Sendable { case agent(AgentSession.Agent), wait }

    /// Interactive agent sessions and `aki wait` listeners; headless runs
    /// (`claude -p`, `codex exec`, `codex review`) don't count.
    public static func classify(_ command: String) -> Kind? {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        var program = URL(filePath: first).lastPathComponent
        var rest = Array(words.dropFirst())
        // CLIs written in JavaScript run as `node …/bin/<name>`.
        if program == "node" || program == "bun", let script = rest.first {
            program = URL(filePath: script).lastPathComponent
            rest = Array(rest.dropFirst())
            // Codex's node wrapper starts its own binary, which is the one counted.
            if program == "codex" { return nil }
        }
        let flags = Set(rest)
        // The subcommand: the first word that isn't an option or an option's value
        // (`codex -c model=x review` is a review, not a session).
        let takesValue: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
                                       "-a", "--ask-for-approval", "-C", "--cd", "-i", "--image", "--enable", "--disable"]
        var sub: String?
        var skip = false
        for word in rest {
            if skip { skip = false; continue }
            if word.hasPrefix("-") { skip = takesValue.contains(word); continue }
            sub = word
            break
        }
        switch program {
        case "claude":
            return flags.isDisjoint(with: ["-p", "--print", "mcp", "config", "update"]) ? .agent(.claude) : nil
        case "codex":
            guard let sub else { return .agent(.codex) }
            // Headless runs and the ChatGPT app's own helpers (app-server, sandbox) aren't sessions.
            return ["exec", "review", "mcp", "mcp-server", "login", "apply", "app-server", "sandbox", "debug", "completion"]
                .contains(sub) ? nil : .agent(.codex)
        case "gemini":
            return flags.isDisjoint(with: ["-p", "--prompt", "mcp"]) ? .agent(.gemini) : nil
        case "grok":
            return flags.isDisjoint(with: ["-p", "--prompt"]) ? .agent(.grok) : nil
        case "opencode":
            return sub == nil || sub == "tui" ? .agent(.opencode) : nil
        case "cursor-agent":
            return flags.isDisjoint(with: ["-p", "--print"]) ? .agent(.cursor) : nil
        case "aki", "Aki":
            return sub == "wait" ? .wait : nil
        default:
            return nil
        }
    }

    /// One `ps` and one `lsof` for everything, so it's cheap to call every few seconds.
    public static func scan(pending: [Annotation] = []) -> [AgentSession] {
        let processes = runningProcesses().compactMap { p in classify(p.command).map { (p, $0) } }
        guard !processes.isEmpty else { return [] }
        let cwds = workingDirectories(of: processes.map(\.0.pid))

        var sessions: [String: AgentSession] = [:]
        var roots: [String: String] = [:]
        for (process, kind) in processes {
            guard let cwd = cwds[process.pid], cwd != "/" else { continue }
            let root = roots[cwd] ?? Worktree.root(of: cwd)
            roots[cwd] = root
            var session = sessions[root] ?? AgentSession(
                worktree: root, branch: nil, agents: [], listening: false, working: false, pending: 0)
            switch kind {
            case .agent(let agent):
                session.agents.append(agent)
                session.working = session.working || process.cpu >= 8
            case .wait:
                session.listening = true
            }
            sessions[root] = session
        }

        let portOwners = Dictionary(
            Worktree.listeningPorts().compactMap { port, pid in cwds[pid].map { (port, $0) } },
            uniquingKeysWith: { first, _ in first })
        return sessions.values
            .filter { !$0.agents.isEmpty }
            .map { session in
                var session = session
                session.branch = branch(of: session.worktree)
                let mine = pending.filter { annotation in
                    if let tagged = annotation["worktree"]?.string { return tagged == session.worktree }
                    guard let url = annotation["url"]?.string, let port = Worktree.localPort(of: url),
                        let owner = portOwners[port]
                    else { return false }
                    return owner == session.worktree || owner.hasPrefix(session.worktree + "/")
                }
                session.pending = mine.count
                session.pendingComments = mine
                    .sorted { ($0["created_at"]?.string ?? "") > ($1["created_at"]?.string ?? "") }
                    .prefix(3)
                    .map { $0["comment"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "(no text)" }
                return session
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The non-Claude agent this process runs under ("codex:<pid>", the id the
    /// sidebar gives it), found by walking up the parent processes.
    public static func agentID(ofAncestorsOf pid: Int32 = getpid()) -> String? {
        let commands = Dictionary(runningProcesses().map { ($0.pid, $0.command) }, uniquingKeysWith: { a, _ in a })
        var current = pid
        for _ in 0..<12 {
            if let command = commands[current], case .agent(let agent)? = classify(command), agent != .claude {
                return "\(agent.rawValue):\(current)"
            }
            guard let parent = ClaudeSessions.parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func runningProcesses() -> [Process] {
        run("/bin/ps", ["-axo", "pid=,pcpu=,command="]).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { return nil }
            return Process(pid: pid, cpu: cpu, command: String(parts[2]))
        }
    }

    static func workingDirectories(of pids: [Int32]) -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", list]).split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    static func branch(of worktree: String) -> String? {
        let name = run("/usr/bin/git", ["-C", worktree, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Read only Orca's terminal identity from this process's environment. The
    /// argv section is skipped: a prompt mentioning a handle is not an identity.
    public static func terminalHandle(inProcessArguments data: Data) -> String? {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc < 65536 else { return nil }
        let bytes = Array(data)
        var index = MemoryLayout<Int32>.size
        func skipString() -> Bool {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index < bytes.count else { return false }
            index += 1
            return true
        }
        guard skipString() else { return nil } // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        for _ in 0..<argc { guard skipString() else { return nil } }
        while index < bytes.count, bytes[index] != 0 {
            let start = index
            guard skipString() else { return nil }
            let entry = String(decoding: bytes[start..<(index - 1)], as: UTF8.self)
            if entry.hasPrefix("ORCA_TERMINAL_HANDLE=") {
                let handle = String(entry.dropFirst("ORCA_TERMINAL_HANDLE=".count))
                return handle.isEmpty ? nil : handle
            }
        }
        return nil
    }

    private static func terminalHandle(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size <= 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return terminalHandle(inProcessArguments: Data(bytes.prefix(size)))
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Foundation.Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// One agent conversation you can send marks to: a Claude Code session (several
/// can share a worktree) or a Codex process.
public struct AgentTerminal: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable { case waiting, working, shell, listening, idle }

    /// The Claude session id, or `codex:<pid>`.
    public var id: String
    public var agent: AgentSession.Agent
    public var pid: Int32
    /// The session's name ("PHOTO EDITOR"), or the folder when it has none.
    public var name: String
    public var named: Bool
    public var worktree: String
    public var branch: String?
    public var state: State
    public var lastMessage: String?
    public var pending: Int
    public var pendingComments: [String]
    /// Every pending mark's id, oldest first.
    public var pendingIDs: [String] = []
    public var updatedAt: Date?
    /// Crops of the marks still waiting, newest first (up to 4): the ring's queue.
    public var pendingImages: [String] = []
    /// Pending marks not yet typed into the terminal nor read by the agent.
    public var undelivered: Int = 0
    /// Exact Orca tab identity injected when the process starts (never guessed by folder).
    public var orcaHandle: String? = nil
}

extension AgentSessions {
    /// Every agent conversation open right now, busiest first within each folder.
    public static func terminals(pending: [Annotation] = []) -> [AgentTerminal] {
        let processes = runningProcesses().compactMap { p in classify(p.command).map { (p, $0) } }
        // Which sessions have an `aki wait` listening for them.
        let listening = Set(processes.compactMap { process, kind -> String? in
            kind == .wait ? ClaudeSessions.session(ofAncestorsOf: process.pid)?.sessionId : nil
        })
        var roots: [String: String] = [:]
        func root(_ cwd: String) -> String {
            if let known = roots[cwd] { return known }
            let found = Worktree.root(of: cwd)
            roots[cwd] = found
            return found
        }
        var branches: [String: String?] = [:]
        func branchOf(_ worktree: String) -> String? {
            if let known = branches[worktree] { return known }
            let found = branch(of: worktree)
            branches[worktree] = found
            return found
        }
        func marks(for id: String, worktree: String) -> [Annotation] {
            pending.filter { a in
                if let target = a["session_id"]?.string { return target == id }
                return a["worktree"]?.string == worktree
            }
        }
        func images(_ list: [Annotation]) -> [String] {
            list.sorted { ($0["created_at"]?.string ?? "") > ($1["created_at"]?.string ?? "") }
                .compactMap { $0["image_path"]?.string }.prefix(4).map { $0 }
        }
        func unsent(_ list: [Annotation]) -> Int {
            list.filter { $0["delivered_at"]?.string == nil && $0["read_at"]?.string == nil }.count
        }
        func newest(_ list: [Annotation]) -> [Annotation] {
            Array(list.sorted { ($0["created_at"]?.string ?? "") > ($1["created_at"]?.string ?? "") }.prefix(3))
        }
        func comments(_ list: [Annotation]) -> [String] {
            newest(list).map { $0["comment"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "(no text)" }
        }
        // Every pending mark's id, oldest first (the message to the agent names them all).
        func ids(_ list: [Annotation]) -> [String] {
            list.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }.map(\.id)
        }

        var result: [AgentTerminal] = []
        for session in ClaudeSessions.live() {
            let worktree = root(session.cwd)
            let mine = marks(for: session.sessionId, worktree: worktree)
            let state: AgentTerminal.State = switch session.status {
            case .waiting: .waiting
            case .busy: .working
            case .shell: .shell
            default: listening.contains(session.sessionId) ? .listening : .idle
            }
            let given = session.nameSource == "user" ? session.name : nil
            let title = given ?? ClaudeSessions.title(sessionId: session.sessionId, cwd: session.cwd)
            result.append(AgentTerminal(
                id: session.sessionId, agent: .claude, pid: session.pid,
                name: title ?? URL(filePath: worktree).lastPathComponent, named: title != nil,
                worktree: worktree, branch: branchOf(worktree), state: state,
                lastMessage: ClaudeSessions.lastAgentMessage(sessionId: session.sessionId, cwd: session.cwd),
                pending: mine.count, pendingComments: comments(mine), pendingIDs: ids(mine), updatedAt: session.updatedAt,
                pendingImages: images(mine), undelivered: unsent(mine), orcaHandle: terminalHandle(of: session.pid)))
        }
        // Other agents keep no registry: one entry per process, named after its folder.
        let others = processes.compactMap { process, kind -> (Process, AgentSession.Agent)? in
            if case .agent(let agent) = kind, agent != .claude { return (process, agent) }
            return nil
        }
        let cwds = workingDirectories(of: others.map(\.0.pid))
        for (process, agent) in others {
            guard let cwd = cwds[process.pid], cwd != "/" else { continue }
            let worktree = root(cwd)
            let id = "\(agent.rawValue):\(process.pid)"
            let mine = marks(for: id, worktree: worktree)
            result.append(AgentTerminal(
                id: id, agent: agent, pid: process.pid, name: URL(filePath: worktree).lastPathComponent, named: false,
                worktree: worktree, branch: branchOf(worktree), state: process.cpu >= 8 ? .working : .idle,
                lastMessage: nil, pending: mine.count, pendingComments: comments(mine), pendingIDs: ids(mine), updatedAt: nil,
                pendingImages: images(mine), undelivered: unsent(mine), orcaHandle: terminalHandle(of: process.pid)))
        }
        return result.sorted { a, b in
            if a.worktree != b.worktree { return a.worktree.localizedStandardCompare(b.worktree) == .orderedAscending }
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }
    }
}

