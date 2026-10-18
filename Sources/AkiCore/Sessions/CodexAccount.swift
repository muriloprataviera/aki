import Foundation

/// What OpenAI knows about your Codex account and the logs on this Mac don't: the
/// limit resets you have saved, your all-time numbers, what you call most.
///
/// The one place Aki asks a server about usage, and only when you turn it on: it
/// uses the sign-in Codex keeps on this Mac (`~/.codex/auth.json`), sends it only
/// to chatgpt.com, the same way Codex itself does, and never stores or changes it.
/// These addresses aren't published by OpenAI and may change: then this just
/// shows nothing, and the rest of the card goes on from the logs.
public struct CodexAccount: Sendable, Equatable {
    public struct Week: Sendable, Equatable {
        public var start: Date
        public var tokens: Int
    }
    public struct Invocation: Sendable, Equatable {
        public var name: String
        public var count: Int
    }

    /// Limit resets saved, and how many of them can be used now (only with a limit reached).
    public var resetsSaved: Int?
    public var resetsUsable: Int?
    public var lifetimeTokens: Int?
    public var threads: Int?
    public var busiestDay: Int?
    public var streak: Int?
    public var longestStreak: Int?
    /// The longest a single request ran, in seconds.
    public var longestTurn: TimeInterval?
    public var effort: String?
    public var effortShare: Double?
    public var invocations: [Invocation] = []
    public var weeks: [Week] = []
    public var plan: String?
    /// The profile answered (all-time numbers); `/usage` alone gives only the resets.
    public var hasStats = false
    public var updated = Date()

    public init() {}

    public enum Failure: Error, Equatable {
        /// No Codex sign-in on this Mac (not installed, or signed in with an API key).
        case notSignedIn
        /// The sign-in is too old: opening Codex renews it.
        case expired
        case unavailable
    }

    /// Asks both addresses; whatever answers is kept. `wanted` is asked before each
    /// request: turned off meanwhile, nothing more is sent.
    public static func fetch(home: URL = UsageLimits.codexHome,
                             wanted: @Sendable () async -> Bool = { true }) async -> Result<CodexAccount, Failure> {
        guard let credential = credential(home: home) else { return .failure(.notSignedIn) }
        var account = CodexAccount()
        var answered = false
        for path in ["usage", "profiles/me"] {
            guard await wanted(), !Task.isCancelled else { return .failure(.unavailable) }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/" + path)!, timeoutInterval: 15)
            request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
            request.setValue(credential.account, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                let status = (response as? HTTPURLResponse)?.statusCode
            else { continue }
            // 401: the sign-in itself is refused. A 403 on one address may only mean no access
            // to it: the other's answer still counts.
            if status == 401 { return .failure(.expired) }
            guard status == 200 else { continue }
            if path == "usage" { answered = account.addUsage(data) || answered } else { answered = account.addProfile(data) || answered }
        }
        return answered ? .success(account) : .failure(.unavailable)
    }

    static func credential(home: URL) -> (token: String, account: String)? {
        guard let data = try? Data(contentsOf: home.appending(path: "auth.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty,
            let account = tokens["account_id"] as? String, !account.isEmpty
        else { return nil }
        return (token, account)
    }

    /// `/wham/usage`: the plan and the saved limit resets.
    @discardableResult
    public mutating func addUsage(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        plan = json["plan_type"] as? String
        if let resets = json["rate_limit_reset_credits"] as? [String: Any] {
            resetsSaved = (resets["available_count"] as? NSNumber)?.intValue
            resetsUsable = (resets["applicable_available_count"] as? NSNumber)?.intValue
        }
        return true
    }

    /// `/wham/profiles/me`: all-time numbers, what you call most, tokens week by week.
    @discardableResult
    public mutating func addProfile(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stats = json["stats"] as? [String: Any]
        else { return false }
        func int(_ key: String) -> Int? { (stats[key] as? NSNumber)?.intValue }
        hasStats = true
        lifetimeTokens = int("lifetime_tokens")
        threads = int("total_threads")
        busiestDay = int("peak_daily_tokens")
        streak = int("current_streak_days")
        longestStreak = int("longest_streak_days")
        longestTurn = (stats["longest_running_turn_sec"] as? NSNumber)?.doubleValue
        effort = stats["most_used_reasoning_effort"] as? String
        effortShare = (stats["most_used_reasoning_effort_percentage"] as? NSNumber)?.doubleValue
        invocations = (stats["top_invocations"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["skill_name"] as? String ?? item["plugin_name"] as? String,
                let count = (item["usage_count"] as? NSNumber)?.intValue
            else { return nil }
            return Invocation(name: name, count: count)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        weeks = (stats["weekly_usage_buckets"] as? [[String: Any]] ?? []).compactMap { item in
            guard let start = (item["start_date"] as? String).flatMap(format.date(from:)),
                let tokens = (item["tokens"] as? NSNumber)?.intValue
            else { return nil }
            return Week(start: start, tokens: tokens)
        }.sorted { $0.start < $1.start }
        return true
    }
}
