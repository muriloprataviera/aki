import Foundation

/// How much of an AI account's limits is used: the 5-hour window and the week.
/// Read from what each agent already leaves on this Mac, never asked of a server.
public struct UsageLimits: Sendable, Equatable {
    public var agent: AgentSession.Agent
    public var fiveHour: ClaudeStatus.Limit?
    public var week: ClaudeStatus.Limit?
    /// When the agent last reported them.
    public var updated: Date

    public init(agent: AgentSession.Agent, fiveHour: ClaudeStatus.Limit?, week: ClaudeStatus.Limit?, updated: Date) {
        self.agent = agent
        self.fiveHour = fiveHour
        self.week = week
        self.updated = updated
    }

    /// A window that already renewed reads 0%: the agent only reports again when it's used.
    public func current(now: Date = Date()) -> UsageLimits {
        func fresh(_ limit: ClaudeStatus.Limit?) -> ClaudeStatus.Limit? {
            guard var limit else { return nil }
            if let resets = limit.resets, resets <= now {
                limit.percent = 0
                limit.resets = nil
            }
            return limit
        }
        return UsageLimits(agent: agent, fiveHour: fresh(fiveHour), week: fresh(week), updated: updated)
    }

    /// Claude: what its status line last said (account-wide, any session).
    public static func claude(from statuses: [String: ClaudeStatus]) -> UsageLimits? {
        guard let latest = ClaudeStatus.latestLimits(in: statuses) else { return nil }
        return UsageLimits(agent: .claude, fiveHour: latest.fiveHour, week: latest.week, updated: latest.updated)
    }

    /// Codex: the last `rate_limits` it wrote to a session log under `~/.codex/sessions`.
    public static func codex(home: URL = codexHome, now: Date = Date()) -> UsageLimits? {
        let sessions = home.appending(path: "sessions")
        let calendar = Calendar(identifier: .gregorian)
        // The logs live in year/month/day folders: today's and the week's before it are plenty.
        var files: [(url: URL, modified: Date)] = []
        for back in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            let folder = sessions.appending(path: String(format: "%04d/%02d/%02d", y, m, d))
            let names = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in names where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, modified))
            }
        }
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(20) {
            if let limits = lastLimits(in: file.url, updated: file.modified) { return limits }
        }
        return nil
    }

    public static var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(filePath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    /// The newest `rate_limits` in one log, read from its end (logs grow large).
    static func lastLimits(in file: URL, updated: Date) -> UsageLimits? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let limits = parseCodex(line: Data(line.utf8), updated: updated) { return limits }
        }
        return nil
    }

    /// One log line: `{"payload": {"type": "token_count", "rate_limits": {"primary": {...}, "secondary": {...}}}}`.
    /// Which window is the week goes by its length, not its name.
    public static func parseCodex(line: Data, updated: Date) -> UsageLimits? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = json["payload"] as? [String: Any],
            let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }
        var fiveHour: ClaudeStatus.Limit?
        var week: ClaudeStatus.Limit?
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let limit = ClaudeStatus.Limit(percent: Int(used.rounded()), resets: resets)
            if minutes >= 24 * 60 { week = limit } else if minutes > 0 { fiveHour = limit }
        }
        guard fiveHour != nil || week != nil else { return nil }
        return UsageLimits(agent: .codex, fiveHour: fiveHour, week: week, updated: updated)
    }
}
