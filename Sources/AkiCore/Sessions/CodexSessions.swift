import Foundation

/// Codex's own log of each conversation (`~/.codex/sessions/…/rollout-*.jsonl`), which
/// it keeps open while it runs. A turn is open between `task_started` and
/// `task_complete` (or `turn_aborted`): the time Codex is thinking, which barely shows
/// in its CPU (it waits on the model).
public enum CodexSessions {
    /// The logs each Codex process has open: its own conversation (resumed ones too)
    /// and its subagents', each with its own.
    public static func openLogs(of pids: [Int32]) -> [Int32: [URL]] {
        guard !pids.isEmpty else { return [:] }
        // Asked twice a pass (the sessions, then the rings): `lsof` once.
        let key = pids.sorted()
        if let known = logsLock.withLock({ lastLogs }), known.pids == key, Date().timeIntervalSince(known.at) < 2 {
            return known.logs
        }
        let result = lookUpOpenLogs(of: pids)
        logsLock.withLock { lastLogs = (key, result, Date()) }
        return result
    }

    nonisolated(unsafe) private static var lastLogs: (pids: [Int32], logs: [Int32: [URL]], at: Date)?
    private static let logsLock = NSLock()

    private static func lookUpOpenLogs(of pids: [Int32]) -> [Int32: [URL]] {
        var result: [Int32: [URL]] = [:]
        var pid: Int32?
        let list = pids.map(String.init).joined(separator: ",")
        for line in AgentSessions.run("/usr/sbin/lsof", ["-a", "-nP", "-p", list, "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, line.hasSuffix(".jsonl"), line.contains("/rollout-") {
                result[pid, default: []].append(URL(filePath: String(line.dropFirst())))
            }
        }
        return result
    }

    /// Whether the conversation in this log is in the middle of a turn.
    public static func working(log: URL, now: Date = Date()) -> Bool {
        let values = try? log.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modified = values?.contentModificationDate,
              // A turn left open by a Codex that hung: silent for long, not working.
              now.timeIntervalSince(modified) < 900
        else { return false }
        // Read again only when the log changed (asked for every conversation every few seconds).
        let size = values?.fileSize ?? 0
        if let known = turnsLock.withLock({ turns[log.path] }), known.size == size, known.modified == modified {
            return known.open
        }
        // A long turn can push its start far back: read further until a turn event shows.
        var bytes: UInt64 = 262_144
        var open = false
        while true {
            let (text, whole) = tail(of: log, bytes: bytes)
            if let found = turnOpen(text) { open = found; break }
            if whole || bytes >= 16 << 20 { break }
            bytes *= 4
        }
        turnsLock.withLock {
            if turns.count > 300 { turns.removeAll() }
            turns[log.path] = (size, modified, open)
        }
        return open
    }

    nonisolated(unsafe) private static var turns: [String: (size: Int, modified: Date, open: Bool)] = [:]
    private static let turnsLock = NSLock()

    /// Whether the last turn in a stretch of the log is still open (nil: no turn event in it).
    public static func turnOpen(_ text: String) -> Bool? {
        let started = text.range(of: "\"type\":\"task_started\"", options: .backwards)?.lowerBound
        let ended = ["\"type\":\"task_complete\"", "\"type\":\"turn_aborted\""]
            .compactMap { text.range(of: $0, options: .backwards)?.lowerBound }.max()
        switch (started, ended) {
        case (nil, nil): return nil
        case (_?, nil): return true
        case (nil, _?): return false
        case let (s?, e?): return e < s
        }
    }

    /// The last part of a log, and whether that is all of it.
    static func tail(of file: URL, bytes: UInt64) -> (String, Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ("", true) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return (String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self), size <= bytes)
    }

    /// The name Codex gave a conversation ("Revisar NFs no Drive"), from its index
    /// (`session_index.jsonl`, by the id that ends the log's file name).
    public static func threadName(of log: URL, home: URL = UsageLimits.codexHome) -> String? {
        let name = log.deletingPathExtension().lastPathComponent
        // "rollout-<date>-<uuid>": the uuid is the last five dash-separated groups.
        let id = name.split(separator: "-").suffix(5).joined(separator: "-")
        guard id.count == 36 else { return nil }
        return threadNames(home: home)[id]
    }

    /// Of a process's logs, its own conversation's (not a subagent's), written last.
    public static func newest(_ logs: [URL]) -> URL? {
        logs.filter { !isSubagent($0) }.max { a, b in
            let x = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let y = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return x < y
        }
    }

    nonisolated(unsafe) private static var names: (stamp: Date, byID: [String: String])?
    private static let namesLock = NSLock()

    /// Every conversation's name by id (the last line for an id wins: a rename).
    private static func threadNames(home: URL) -> [String: String] {
        let file = home.appending(path: "session_index.jsonl")
        guard let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return [:] }
        if let cached = namesLock.withLock({ names }), cached.stamp == stamp { return cached.byID }
        var byID: [String: String] = [:]
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String,
                      let name = (json["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
                else { continue }
                byID[id] = name
            }
        }
        namesLock.withLock { names = (stamp, byID) }
        return byID
    }

    /// A subagent's log says so on its first line (`"thread_source":"subagent"`).
    static func isSubagent(_ log: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        let first = head.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? head
        return first.contains("\"thread_source\":\"subagent\"")
    }
}
