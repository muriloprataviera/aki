import Foundation

/// How much of an AI account's limits is used: the 5-hour window, the week and,
/// on plans that have one, the month.
/// Read from what each agent already leaves on this Mac, never asked of a server.
public struct UsageLimits: Sendable, Equatable {
    public var agent: AgentSession.Agent
    public var fiveHour: ClaudeStatus.Limit?
    public var week: ClaudeStatus.Limit?
    public var month: ClaudeStatus.Limit?
    /// When the agent last reported them.
    public var updated: Date

    public init(agent: AgentSession.Agent, fiveHour: ClaudeStatus.Limit?, week: ClaudeStatus.Limit?, month: ClaudeStatus.Limit? = nil, updated: Date) {
        self.agent = agent
        self.fiveHour = fiveHour
        self.week = week
        self.month = month
        self.updated = updated
    }

    /// A window that already renewed reads 0%: the agent only reports again when it's used.
    /// Its next renewal is the old one plus whole windows, so "this week" keeps its start.
    public func current(now: Date = Date()) -> UsageLimits {
        func fresh(_ limit: ClaudeStatus.Limit?, length: TimeInterval) -> ClaudeStatus.Limit? {
            guard var limit else { return nil }
            if var resets = limit.resets, resets <= now {
                limit.percent = 0
                while resets <= now { resets.addTimeInterval(length) }
                limit.resets = resets
            }
            return limit
        }
        return UsageLimits(agent: agent, fiveHour: fresh(fiveHour, length: 5 * 3600),
                           week: fresh(week, length: 7 * 24 * 3600), month: fresh(month, length: 30 * 24 * 3600),
                           updated: updated)
    }

    /// Claude: what its status line last said (account-wide, any session).
    public static func claude(from statuses: [String: ClaudeStatus]) -> UsageLimits? {
        guard let latest = ClaudeStatus.latestLimits(in: statuses) else { return nil }
        return UsageLimits(agent: .claude, fiveHour: latest.fiveHour, week: latest.week, updated: latest.updated)
    }

    /// Codex: the newest `rate_limits` it wrote to a session log under `~/.codex/sessions`.
    /// Any log touched in the last week counts (a resumed session keeps writing to the
    /// folder of the day it began); among them, the report with the latest time wins.
    public static func codex(home: URL = codexHome, now: Date = Date()) -> UsageLimits? {
        let since = now.addingTimeInterval(-8 * 24 * 3600)
        var files: [(url: URL, modified: Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        // Archived sessions too: the latest report may sit in one Codex just archived.
        for folder in ["sessions", "archived_sessions"] {
            guard let walk = FileManager.default.enumerator(at: home.appending(path: folder), includingPropertiesForKeys: keys)
            else { continue }
            for case let url as URL in walk where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified >= since { files.append((url, modified)) }
            }
        }
        var best: UsageLimits?
        // A cap so a Mac whose logs never carry limits (an API key) reads little each minute.
        for file in files.sorted(by: { $0.modified > $1.modified }).prefix(40) {
            // Logs older than the best report can't hold a newer one.
            if let best, file.modified < best.updated { break }
            if let limits = lastLimits(in: file.url, updated: file.modified), limits.updated > (best?.updated ?? .distantPast) {
                best = limits
            }
        }
        return best
    }

    /// "2026-10-10T20:57:25.894Z" read by hand (fast: logs have many of them);
    /// anything else goes to the system's ISO 8601 reader.
    static func parseTime(_ text: String) -> Date? {
        let b = Array(text.utf8)
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= b.count else { return nil }
            var value = 0
            for i in from..<(from + count) {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                value = value * 10 + Int(b[i] - 0x30)
            }
            return value
        }
        if b.count >= 20, b.last == 0x5A, b[4] == 0x2D, b[10] == 0x54,
            let y = digits(0, 4), let mo = digits(5, 2), let d = digits(8, 2),
            let h = digits(11, 2), let mi = digits(14, 2), let s = digits(17, 2)
        {
            var parts = tm(tm_sec: Int32(s), tm_min: Int32(mi), tm_hour: Int32(h), tm_mday: Int32(d), tm_mon: Int32(mo - 1),
                           tm_year: Int32(y - 1900), tm_wday: 0, tm_yday: 0, tm_isdst: 0, tm_gmtoff: 0, tm_zone: nil)
            var fraction = 0.0
            if b[19] == 0x2E, let ms = digits(20, min(3, b.count - 21)) { fraction = Double(ms) / pow(10, Double(min(3, b.count - 21))) }
            return Date(timeIntervalSince1970: TimeInterval(timegm(&parts)) + fraction)
        }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

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
        // From the end, a bigger piece each time (a tool output can follow the last report).
        var chunk: UInt64 = 512 * 1024
        while true {
            try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
            guard var data = try? handle.readToEnd() else { return nil }
            // Started mid-file: the first line is cut (maybe mid-character), so it goes.
            if size > chunk, let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                if let limits = parseCodex(line: Data(line.utf8), updated: updated) { return limits }
            }
            guard size > chunk, chunk < 32 << 20 else { return nil }
            chunk *= 4
        }
    }

    /// One log line: `{"payload": {"type": "token_count", "rate_limits": {"primary": {...}, "secondary": {...}}}}`.
    /// Which window is which goes by its length, not its name.
    public static func parseCodex(line: Data, updated: Date) -> UsageLimits? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = json["payload"] as? [String: Any],
            let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }
        var fiveHour: ClaudeStatus.Limit?
        var week: ClaudeStatus.Limit?
        var month: ClaudeStatus.Limit?
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let limit = ClaudeStatus.Limit(percent: Int(used.rounded()), resets: resets)
            if minutes >= 28 * 24 * 60 { month = limit } else if minutes >= 24 * 60 { week = limit } else if minutes > 0 { fiveHour = limit }
        }
        guard fiveHour != nil || week != nil || month != nil else { return nil }
        // When the report was made (the log's own clock), not when the file last changed.
        let stamp = (json["timestamp"] as? String).flatMap(parseTime) ?? updated
        return UsageLimits(agent: .codex, fiveHour: fiveHour, week: week, month: month, updated: stamp)
    }
}
