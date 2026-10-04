import Foundation

/// A live Claude Code session, from the registry Claude Code keeps at
/// `~/.claude/sessions/<pid>.json` for every interactive process.
public struct ClaudeSession: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// Thinking or using tools.
        case busy
        /// Asking the user something (a permission, a question): needs you.
        case waiting
        /// Running a shell command.
        case shell
        case idle
        case unknown
    }

    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    /// The name given with /rename, or the one Claude Code picked.
    public var name: String?
    /// "user" when the name came from /rename; otherwise it's a generated slug.
    public var nameSource: String?
    public var status: Status
    public var updatedAt: Date?
}

public enum ClaudeSessions {
    public static var registry: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
    }

    public static var projects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    /// Interactive sessions whose process is still running.
    public static func live(in directory: URL = registry) -> [ClaudeSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let session = parse(try? Data(contentsOf: file)), kill(session.pid, 0) == 0 else { return nil }
            return session
        }
    }

    static func parse(_ data: Data?) -> ClaudeSession? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = (json["pid"] as? NSNumber)?.int32Value, let id = json["sessionId"] as? String,
            let cwd = json["cwd"] as? String, (json["kind"] as? String ?? "interactive") == "interactive"
        else { return nil }
        let updated = (json["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeSession(
            pid: pid, sessionId: id, cwd: cwd, name: name, nameSource: json["nameSource"] as? String,
            status: ClaudeSession.Status(rawValue: json["status"] as? String ?? "") ?? .unknown, updatedAt: updated)
    }

    /// The session this process runs under: walks up the parent processes to the
    /// `claude` that started it (an `aki wait` or `aki mcp` launched by an agent).
    public static func session(ofAncestorsOf pid: Int32 = getpid(), in directory: URL = registry) -> ClaudeSession? {
        var current = pid
        for _ in 0..<12 {
            let file = directory.appending(path: "\(current).json")
            if let session = parse(try? Data(contentsOf: file)) { return session }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static let titleLock = NSLock()
    nonisolated(unsafe) private static var titles: [String: (title: String, at: Date)] = [:]

    /// The conversation's title as Claude Code wrote it (`/rename`, else its own
    /// summary). Titles are written again as the conversation goes on, so the
    /// file is searched from its end in blocks, never read whole; then remembered.
    public static func title(sessionId: String, cwd: String, projects: URL = projects) -> String? {
        // Remembered for a minute: Claude names a conversation after its first
        // messages, and /rename changes it, so it's read again now and then.
        if let known = titleLock.withLock({ titles[sessionId] }), Date().timeIntervalSince(known.at) < 60 {
            return known.title.isEmpty ? nil : known.title
        }
        let file = transcript(sessionId: sessionId, cwd: cwd, projects: projects)
        let found = searchBackwards(file, keys: ["customTitle", "aiTitle"]) ?? ""
        titleLock.withLock { titles[sessionId] = (found, Date()) }
        return found.isEmpty ? nil : found
    }

    /// The latest value of the first key found, scanning `file` from the end in
    /// 1 MB blocks (up to 32 MB, then the start of the file).
    static func searchBackwards(_ file: URL, keys: [String]) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let block: UInt64 = 1 << 20
        var end = size
        var scanned: UInt64 = 0
        while end > 0 {
            let start = end > block ? end - block : 0
            // Overlap blocks a little so a value split across them is still seen.
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(min(end - start + 4096, size - start))) else { return nil }
            for key in keys {
                if let value = lastValue(of: key, in: data) { return value }
            }
            scanned += end - start
            if scanned >= 32 * block, start > block {
                end = block  // give up on the middle: titles are also written early on
                continue
            }
            end = start
        }
        return nil
    }

    private static func lastValue(of key: String, in data: Data) -> String? {
        let marker = Data("\"\(key)\":\"".utf8)
        guard let hit = data.range(of: marker, options: .backwards) else { return nil }
        let rest = data[hit.upperBound...]
        guard let close = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let value = String(decoding: rest[..<close], as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func transcript(sessionId: String, cwd: String, projects: URL) -> URL {
        let slug = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        return projects.appending(path: slug).appending(path: "\(sessionId).jsonl")
    }

    /// The agent's latest words in this session, for the card: the last assistant
    /// text in the transcript, read from the end of the file only.
    public static func lastAgentMessage(sessionId: String, cwd: String, projects: URL = projects) -> String? {
        let file = transcript(sessionId: sessionId, cwd: cwd, projects: projects)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"type\":\"assistant\""),
                let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            let words = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { return String(words.prefix(220)) }
        }
        return nil
    }
}
