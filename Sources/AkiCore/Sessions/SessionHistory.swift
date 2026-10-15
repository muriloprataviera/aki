import Foundation

/// The conversations of the last days, open or closed, from what the agents save:
/// Claude Code's transcripts (`~/.claude/projects`, the Claude app's Code tab included)
/// and Codex's logs (`~/.codex/sessions`). Read when asked (the History's Sessions tab),
/// never on the sidebar's loop. Only names, folders and times are read, not what was said.
public enum SessionHistory {
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The conversation's own id (what `claude --resume` / `codex resume` takes).
        public var id: String
        public var agent: AgentSession.Agent
        public var title: String?
        public var cwd: String
        public var updated: Date
    }

    /// Each file's entry, kept while the file doesn't change.
    nonisolated(unsafe) private static var cache: [String: (modified: Date, entry: Entry?)] = [:]
    private static let lock = NSLock()

    public static func recent(days: Int = 7, now: Date = Date(),
                              claudeProjects: URL = ClaudeSessions.projects,
                              codexHome: URL = UsageLimits.codexHome) -> [Entry] {
        let since = now.addingTimeInterval(-Double(days) * 24 * 3600)
        var entries: [Entry] = []
        for (file, modified) in files(in: claudeProjects, depth: 2, since: since) {
            if let entry = cached(file, modified, { claude(file, modified) }) { entries.append(entry) }
        }
        for folder in ["sessions", "archived_sessions"] {
            for (file, modified) in files(in: codexHome.appending(path: folder), depth: 5, since: since) {
                if let entry = cached(file, modified, { codex(file, modified, home: codexHome) }) { entries.append(entry) }
            }
        }
        return entries.sorted { $0.updated > $1.updated }
    }

    private static func cached(_ file: URL, _ modified: Date, _ read: () -> Entry?) -> Entry? {
        if let known = lock.withLock({ cache[file.path] }), known.modified == modified { return known.entry }
        let entry = read()
        lock.withLock { cache[file.path] = (modified, entry) }
        return entry
    }

    /// `.jsonl` files changed since `since`, at most `depth` folders down.
    private static func files(in root: URL, depth: Int, since: Date) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in walk {
            if walk.level > depth { walk.skipDescendants(); continue }
            // A conversation's subagents and tool outputs live in folders of their own.
            if url.lastPathComponent == "subagents" || url.lastPathComponent == "memory" { walk.skipDescendants(); continue }
            guard url.pathExtension == "jsonl",
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= since
            else { continue }
            found.append((url, modified))
        }
        return found
    }

    /// The start of a file, as text (where the folder and the kind of run are written).
    private static func head(_ file: URL, bytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }

    static func firstValue(of key: String, in text: String) -> String? {
        guard let start = text.range(of: "\"\(key)\":\"") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// A Claude Code conversation (the folder's own files only: a conversation's
    /// subagents sit one level further down). Runs with `-p` (`sdk-cli`) aren't ones.
    private static func claude(_ file: URL, _ modified: Date) -> Entry? {
        guard file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "projects" else { return nil }
        let text = head(file)
        guard !text.contains("\"entrypoint\":\"sdk-cli\""), let cwd = firstValue(of: "cwd", in: text) else { return nil }
        // A conversation that never got a message isn't one.
        guard text.contains("\"type\":\"user\"") || text.contains("\"type\":\"assistant\"") else { return nil }
        let title = ClaudeSessions.searchBackwards(file, keys: ["customTitle", "aiTitle"])
        return Entry(id: file.deletingPathExtension().lastPathComponent, agent: .claude, title: title, cwd: cwd, updated: modified)
    }

    /// A Codex conversation, not a headless run (`codex exec`, reviews) or a subagent.
    private static func codex(_ file: URL, _ modified: Date, home: URL) -> Entry? {
        let text = head(file, bytes: 16 * 1024)
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        guard first.contains("\"session_meta\""), !first.contains("\"source\":\"exec\""),
              !first.contains("\"thread_source\":\"subagent\""),
              let id = firstValue(of: "id", in: first), let cwd = firstValue(of: "cwd", in: first)
        else { return nil }
        return Entry(id: id, agent: .codex, title: CodexSessions.threadName(of: file, home: home), cwd: cwd, updated: modified)
    }
}
