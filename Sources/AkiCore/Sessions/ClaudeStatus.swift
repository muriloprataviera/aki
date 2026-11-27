import Foundation

/// What Claude Code tells its status line about a session — context used, model,
/// the account's 5-hour and weekly limits — saved by the status line script to
/// `<home>/status/<session>.json` so the sidebar can show it.
public struct ClaudeStatus: Sendable, Equatable {
    public var model: String?
    public var contextPercent: Int?
    public var fiveHour: Limit?
    public var week: Limit?
    public var updated: Date
    /// When Claude last answered in the session (its transcript's last reply): its limits
    /// are as of then. The status file itself is rewritten by idle sessions too.
    public var heard: Date?

    public struct Limit: Sendable, Equatable {
        public var percent: Int
        public var resets: Date?

        public init(percent: Int, resets: Date?) {
            self.percent = percent
            self.resets = resets
        }
    }

    public init(model: String? = nil, contextPercent: Int? = nil, fiveHour: Limit? = nil, week: Limit? = nil, updated: Date,
                heard: Date? = nil) {
        self.heard = heard
        self.model = model
        self.contextPercent = contextPercent
        self.fiveHour = fiveHour
        self.week = week
        self.updated = updated
    }

    /// Every session's status, by session id.
    public static func all(home: AkiHome = .default) -> [String: ClaudeStatus] {
        let folder = home.url.appending(path: "status")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var result: [String: ClaudeStatus] = [:]
        var seen = Set<String>()
        for file in files where file.pathExtension == "json" {
            let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            seen.insert(file.path)
            // Read again only when it changed: hundreds of files, a handful rewritten an hour.
            var entry = parsedLock.withLock { parsed[file.path] }
            if entry?.modified != updated {
                guard let data = try? Data(contentsOf: file),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let limits = json["rate_limits"] as? [String: Any]
                func limit(_ key: String) -> Limit? {
                    guard let l = limits?[key] as? [String: Any], let p = (l["used_percentage"] as? NSNumber)?.intValue else { return nil }
                    return Limit(percent: p, resets: (l["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
                }
                let status = ClaudeStatus(
                    model: (json["model"] as? [String: Any])?["display_name"] as? String,
                    contextPercent: ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.intValue,
                    fiveHour: limit("five_hour"), week: limit("seven_day"), updated: updated)
                entry = (updated, status, json["transcript_path"] as? String)
                parsedLock.withLock { parsed[file.path] = entry }
            }
            guard var status = entry?.status else { continue }
            // Only for those with limits.
            if status.fiveHour != nil || status.week != nil { status.heard = entry?.transcript.flatMap { lastReply(in: $0) } }
            result[file.deletingPathExtension().lastPathComponent] = status
        }
        parsedLock.withLock { parsed = parsed.filter { seen.contains($0.key) } }
        return result
    }

    nonisolated(unsafe) private static var parsed: [String: (modified: Date, status: ClaudeStatus, transcript: String?)] = [:]
    private static let parsedLock = NSLock()

    /// When Claude last answered in a transcript (its last `assistant` line), read off the
    /// file's end once per change. Not the file's own date: renaming a session, or a
    /// message not answered yet, writes to it too, with no new limits.
    public static func lastReply(in path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        if let known = repliesLock.withLock({ replies[path] }), known.modified == modified { return known.reply }
        var reply: Date?
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            // Further back each time (a long tool result can follow the last reply), as far
            // as 64 MB; the start of a cut line is left out (not a whole line).
            for window: UInt64 in [512 * 1024, 4 * 1024 * 1024, 64 * 1024 * 1024] {
                let start = size > window ? size - window : 0
                try? handle.seek(toOffset: start)
                var tail = (try? handle.readToEnd()) ?? Data()
                if start > 0, let first = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: first)...] }
                for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
                    guard line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
                          let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          json["type"] as? String == "assistant", let stamp = json["timestamp"] as? String
                    else { continue }
                    reply = timestamp(stamp)
                    break
                }
                if reply != nil || start == 0 { break }
            }
        }
        // No reply found at all: its numbers count as the oldest (never newer than a real reply).
        reply = reply ?? .distantPast
        repliesLock.withLock { replies[path] = (modified, reply) }
        return reply
    }

    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    nonisolated(unsafe) private static var replies: [String: (modified: Date, reply: Date?)] = [:]
    private static let repliesLock = NSLock()

    /// The account's limits (they're account-wide), from the session that heard from
    /// Claude last: each reports what it saw on its own last request, and an idle one
    /// keeps rewriting that (a share that has grown since, or been reset).
    public static func latestLimits(in all: [String: ClaudeStatus]) -> ClaudeStatus? {
        all.values.filter { $0.fiveHour != nil || $0.week != nil }
            // One with no transcript to read counts as the oldest (its status file is rewritten
            // when idle, so its date says nothing); among those, the last written.
            .max { ($0.heard ?? .distantPast, $0.updated) < ($1.heard ?? .distantPast, $1.updated) }
    }
}
