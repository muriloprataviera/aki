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
    /// When the session last heard from Claude (its transcript's last line): its limits
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
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let limits = json["rate_limits"] as? [String: Any]
            func limit(_ key: String) -> Limit? {
                guard let l = limits?[key] as? [String: Any], let p = (l["used_percentage"] as? NSNumber)?.intValue else { return nil }
                return Limit(percent: p, resets: (l["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }
            let fiveHour = limit("five_hour"), week = limit("seven_day")
            // Only for those with limits (a stat each).
            let heard = fiveHour == nil && week == nil ? nil : (json["transcript_path"] as? String).flatMap {
                try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            result[file.deletingPathExtension().lastPathComponent] = ClaudeStatus(
                model: (json["model"] as? [String: Any])?["display_name"] as? String,
                contextPercent: ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.intValue,
                fiveHour: fiveHour, week: week, updated: updated, heard: heard)
        }
        return result
    }

    /// The account's limits (they're account-wide), from the session that heard from
    /// Claude last: each reports what it saw on its own last request, and an idle one
    /// keeps rewriting that (a share that has grown since, or been reset).
    public static func latestLimits(in all: [String: ClaudeStatus]) -> ClaudeStatus? {
        all.values.filter { $0.fiveHour != nil || $0.week != nil }
            .max { ($0.heard ?? $0.updated, $0.updated) < ($1.heard ?? $1.updated, $1.updated) }
    }
}
