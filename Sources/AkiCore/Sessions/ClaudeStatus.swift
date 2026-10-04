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

    public struct Limit: Sendable, Equatable {
        public var percent: Int
        public var resets: Date?
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
            result[file.deletingPathExtension().lastPathComponent] = ClaudeStatus(
                model: (json["model"] as? [String: Any])?["display_name"] as? String,
                contextPercent: ((json["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.intValue,
                fiveHour: limit("five_hour"), week: limit("seven_day"), updated: updated)
        }
        return result
    }

    /// The account's limits as last reported by any session (they're account-wide).
    public static func latestLimits(in all: [String: ClaudeStatus]) -> ClaudeStatus? {
        all.values.filter { $0.fiveHour != nil || $0.week != nil }.max { $0.updated < $1.updated }
    }
}
