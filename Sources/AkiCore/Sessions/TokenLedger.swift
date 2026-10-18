import Foundation

/// Tokens each AI used on this Mac, and what they'd cost at API prices, from the
/// logs Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`) keep.
///
/// Reads only the usage numbers of each request (time, folder, model, token
/// counts), never what was said. Incremental: each log's read position is kept,
/// so a pass only reads what was appended, and the state is saved in
/// `~/.aki/usage-ledger-v2.json` so a relaunch doesn't read the logs again.
/// Approach adapted from Codenotch (MIT, see LICENSE).
public final class TokenLedger: @unchecked Sendable {
    public struct Event: Codable, Sendable, Equatable {
        public var agent: String
        public var ts: Int
        public var project: String
        public var model: String
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        /// How hard it was asked to think (Codex says it; Claude Code doesn't).
        public var effort: String?

        public var tokens: Int { input + output + cacheRead + cacheWrite }
    }

    struct Cursor: Codable {
        var offset: Int
        var inode: Int
        /// Codex names the folder and model in earlier lines than its token counts.
        var cwd: String?
        var model: String?
        var effort: String?
        /// Codex's running total: a token report that doesn't raise it isn't a new request.
        var total: Int?
    }

    struct State: Codable {
        var cursors: [String: Cursor] = [:]
        var events: [String: Event] = [:]
        /// Tokens per AI per day ("2026-10-18") of the requests that left the week, kept
        /// for good (a few bytes a day) for the streak and the busiest day.
        var history: [String: [String: Int]]?
        /// Requests from here on enter `history` as they leave; the ones before were
        /// counted by `backfill` (nil until the first pass of a version that keeps it).
        var historyFrom: Int?
        var backfilled: Bool?
    }

    /// How far back it keeps (the week shown, plus a day).
    static let keep: TimeInterval = 8 * 24 * 3600

    private let lock = NSLock()
    private var state = State()
    private let file: URL
    private let claudeRoot: URL
    private let codexRoot: URL
    private var loaded = false

    public init(home: AkiHome = .default,
                claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
                codexRoot: URL = UsageLimits.codexHome.appending(path: "sessions")) {
        // v2: Codex reports keyed without their file (betas wrote v1, which goes).
        file = home.url.appending(path: "usage-ledger-v2.json")
        try? FileManager.default.removeItem(at: home.url.appending(path: "usage-ledger.json"))
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
    }

    /// Reads what the logs gained since the last pass. True when something changed.
    @discardableResult
    public func update(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: data) {
                state = saved
            }
        }
        let since = now.addingTimeInterval(-Self.keep)
        var changed = false
        var seen = Set<String>()
        // Codex moves a session it archives out of `sessions`: its tokens still count.
        let archived = codexRoot.deletingLastPathComponent().appending(path: "archived_sessions")
        for (root, agent) in [(claudeRoot, "claude"), (codexRoot, "codex"), (archived, "codex")] {
            for url in Self.logs(in: root, since: since) {
                seen.insert(url.path)
                if read(url, agent: agent) { changed = true }
            }
        }
        // Logs no longer written to and requests past the week go.
        let oldCursors = state.cursors.count
        state.cursors = state.cursors.filter { seen.contains($0.key) }
        let cutoff = Int(since.timeIntervalSince1970)
        let oldEvents = state.events.count
        // Before going, a request adds to its day.
        if state.historyFrom == nil { state.historyFrom = cutoff }
        let from = state.historyFrom ?? cutoff
        var history = state.history ?? [:]
        for event in state.events.values where event.ts < cutoff && event.ts >= from {
            history[event.agent, default: [:]][Self.day(event.ts), default: 0] += event.tokens
        }
        state.history = history
        state.events = state.events.filter { $0.value.ts >= cutoff }
        if state.cursors.count != oldCursors || state.events.count != oldEvents { changed = true }
        if changed { dirty = true }
        // Saved every ten minutes at most (and on quit): rewritten each pass, several
        // MB every half minute added up to gigabytes a day on the disk.
        if dirty, now.timeIntervalSince(lastSaved) > 600 { saveLocked(now) }
        return changed
    }

    private var dirty = false
    private var lastSaved = Date.distantPast

    /// Writes what's unsaved now (Aki quitting).
    public func flush() {
        lock.withLock { if dirty { saveLocked(Date()) } }
    }

    private func saveLocked(_ now: Date) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Only you read it: it names your projects and when you worked.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        dirty = false
        lastSaved = now
    }

    /// Every request of one AI in the window kept.
    public func events(agent: String) -> [Event] {
        lock.withLock { state.events.values.filter { $0.agent == agent } }
    }

    /// Tokens per day ("2026-10-18") of one AI, as far back as its logs go.
    public func daily(agent: String) -> [String: Int] {
        lock.withLock {
            var days = state.history?[agent] ?? [:]
            for event in state.events.values where event.agent == agent { days[Self.day(event.ts), default: 0] += event.tokens }
            return days
        }
    }

    /// Whether the logs before the week were counted already (once, after the first `update`).
    public var needsBackfill: Bool { lock.withLock { loaded && state.backfilled != true && state.historyFrom != nil } }

    /// Counts once, by day, every request older than the week in all the logs (they
    /// can go back months: run in the background). Each log is read on its own, so
    /// memory stays at one log's requests; a request seen in another log (a forked
    /// Codex session) counts once.
    public func backfill() {
        guard let before = lock.withLock({ state.historyFrom }) else { return }
        let archived = codexRoot.deletingLastPathComponent().appending(path: "archived_sessions")
        var days: [String: [String: Int]] = [:]
        var counted = Set<String>()
        for (root, agent) in [(claudeRoot, "claude"), (codexRoot, "codex"), (archived, "codex")] {
            for url in Self.logs(in: root, since: .distantPast) {
                let scratch = TokenLedger(scratchFor: self)
                _ = scratch.read(url, agent: agent)
                for (key, event) in scratch.state.events where event.ts < before && counted.insert(key).inserted {
                    days[agent, default: [:]][Self.day(event.ts), default: 0] += event.tokens
                }
            }
        }
        lock.withLock {
            var history = state.history ?? [:]
            for (agent, byDay) in days {
                for (day, tokens) in byDay { history[agent, default: [:]][day, default: 0] += tokens }
            }
            state.history = history
            state.backfilled = true
            saveLocked(Date())
        }
    }

    /// An empty ledger reading the same folders, for `backfill` (never saved).
    private init(scratchFor ledger: TokenLedger) {
        file = URL(fileURLWithPath: "/dev/null")
        claudeRoot = ledger.claudeRoot
        codexRoot = ledger.codexRoot
        loaded = true
    }

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()
    private static let dayLock = NSLock()

    /// The local day of a time, as "2026-10-18".
    public static func day(_ ts: Int) -> String {
        dayLock.withLock { dayFormat.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
    }

    static func logs(in root: URL, since: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walk where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified >= since { found.append(url) }
        }
        return found
    }

    /// Reads the complete lines appended to one log since its cursor.
    private func read(_ url: URL, agent: String) -> Bool {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let size = (attributes[.size] as? Int) ?? 0
        let inode = (attributes[.systemFileNumber] as? Int) ?? 0
        var cursor = state.cursors[path] ?? Cursor(offset: 0, inode: inode)
        // Replaced or cut short: from the start again.
        if cursor.inode != inode || size < cursor.offset { cursor = Cursor(offset: 0, inode: inode) }
        guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        if agent == "codex", cursor.offset > 0, cursor.cwd == nil { primeCodex(handle, into: &cursor) }
        try? handle.seek(toOffset: UInt64(cursor.offset))
        var changed = false
        var carry = Data()
        // In pieces: a log can be hundreds of MB.
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            var data = carry
            data.append(chunk)
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                carry = data
                continue
            }
            let complete = data[data.startIndex...lastNewline]
            carry = Data(data[data.index(after: lastNewline)...])
            let folder = url.deletingLastPathComponent().lastPathComponent
            // Lines found with memchr: walking Data byte by byte was most of the time.
            var lines: [Range<Int>] = []
            complete.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var start = 0
                while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                    let end = base.distance(to: hit)
                    if end > start { lines.append(start..<end) }
                    start = end + 1
                }
            }
            let origin = complete.startIndex
            for range in lines {
                let line = complete[(origin + range.lowerBound)..<(origin + range.upperBound)]
                let added = agent == "claude" ? claudeLine(line, folder: folder) : codexLine(line, path: path, cursor: &cursor)
                if added { changed = true }
            }
            cursor.offset += complete.count
        }
        // A last line still being written waits for its newline.
        state.cursors[path] = cursor
        return changed
    }

    private static let assistantMark = Data("\"output_tokens\"".utf8)

    /// One Claude Code line: an assistant turn's usage. Streaming writes the same
    /// request several times, so it's kept once (its largest count).
    private func claudeLine(_ line: Data.SubSequence, folder: String) -> Bool {
        guard Self.has(line, Self.assistantMark), let found = Self.quickClaude(line) ?? Self.fullClaude(line) else { return false }
        guard found.model != "<synthetic>", let date = UsageLimits.parseTime(found.stamp) else { return false }
        let event = Event(
            agent: "claude", ts: Int(date.timeIntervalSince1970), project: Self.project(found.cwd), model: found.model,
            input: found.input, output: found.output, cacheRead: found.cacheRead, cacheWrite: found.cacheWrite)
        let key = found.key ?? "s:\(folder):\(found.stamp)"
        if let before = state.events[key], before.output >= event.output { return false }
        state.events[key] = event
        return true
    }

    typealias ClaudeUsage = (key: String?, stamp: String, cwd: String, model: String,
                             input: Int, output: Int, cacheRead: Int, cacheWrite: Int)

    /// The few fields needed, picked straight from the line: the conversation in
    /// between can be megabytes, and parsing all of it was most of the time.
    /// The request's own fields come after its content, so the last match wins;
    /// anything unexpected falls back to the full parse.
    static func quickClaude(_ line: Data.SubSequence) -> ClaudeUsage? {
        line.withUnsafeBytes { raw -> ClaudeUsage? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let type = lastIndex(of: "\"type\":\"", in: bytes),
                string(at: type, in: bytes) == "assistant",
                let usage = lastIndex(of: "\"usage\":{", in: bytes),
                let stampAt = lastIndex(of: "\"timestamp\":\"", in: bytes), let stamp = string(at: stampAt, in: bytes),
                let message = firstIndex(of: "\"message\":{", in: bytes, from: 0),
                let modelAt = firstIndex(of: "\"model\":\"", in: bytes, from: message), modelAt < usage,
                let model = string(at: modelAt, in: bytes),
                let output = number("\"output_tokens\":", in: bytes, from: usage)
            else { return nil }
            // The folder sits after the message in recent versions, before it in older ones.
            let cwd = (lastIndex(of: "\"cwd\":\"", in: bytes).flatMap { $0 > usage ? string(at: $0, in: bytes) : nil }
                ?? firstIndex(of: "\"cwd\":\"", in: bytes, from: 0).flatMap { $0 < message ? string(at: $0, in: bytes) : nil }) ?? ""
            // No request id: the full parse finds the message's own id (a quick search could hit a tool's).
            guard let key = lastIndex(of: "\"requestId\":\"", in: bytes).flatMap({ string(at: $0, in: bytes) }).map({ "r:" + $0 })
            else { return nil }
            return (key, stamp, cwd, model,
                    number("\"input_tokens\":", in: bytes, from: usage) ?? 0, output,
                    number("\"cache_read_input_tokens\":", in: bytes, from: usage) ?? 0,
                    number("\"cache_creation_input_tokens\":", in: bytes, from: usage) ?? 0)
        }
    }

    static func fullClaude(_ line: Data.SubSequence) -> ClaudeUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            json["type"] as? String == "assistant",
            let message = json["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let model = message["model"] as? String,
            let stamp = json["timestamp"] as? String
        else { return nil }
        let key = (json["requestId"] as? String).map { "r:" + $0 } ?? (message["id"] as? String).map { "m:" + $0 }
        return (key, stamp, json["cwd"] as? String ?? "", model,
                int(usage["input_tokens"]), int(usage["output_tokens"]),
                int(usage["cache_read_input_tokens"]), int(usage["cache_creation_input_tokens"]))
    }

    /// Where the text right after `key` starts (first match at or after `from`).
    static func firstIndex(of key: String, in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        let needle = Array(key.utf8)
        guard let base = bytes.baseAddress, from < bytes.count else { return nil }
        guard let hit = memmem(base + from, bytes.count - from, needle, needle.count) else { return nil }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + needle.count
    }

    /// Same, for the last match.
    static func lastIndex(of key: String, in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var found: Int?
        var from = 0
        while let next = firstIndex(of: key, in: bytes, from: from) {
            found = next
            from = next
        }
        return found
    }

    /// A JSON string's text from `start` to its closing quote (none with escapes: those take the full parse).
    static func string(at start: Int, in bytes: UnsafeBufferPointer<UInt8>) -> String? {
        var end = start
        while end < bytes.count, bytes[end] != 0x22 {
            if bytes[end] == 0x5C { return nil }
            end += 1
        }
        guard end < bytes.count else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    }

    /// The whole number after the first `key` at or after `from`.
    static func number(_ key: String, in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard var i = firstIndex(of: key, in: bytes, from: from) else { return nil }
        while i < bytes.count, bytes[i] == 0x20 { i += 1 }
        var value = 0
        var digits = 0
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            value = value * 10 + Int(bytes[i] - 0x30)
            i += 1
            digits += 1
        }
        return digits > 0 ? value : nil
    }

    private static let codexMarks = ["token_count", "turn_context", "session_meta"].map { Data($0.utf8) }

    /// One Codex line: its folder and model (kept on the cursor), or a turn's tokens.
    private func codexLine(_ line: Data.SubSequence, path: String, cursor: inout Cursor, contextOnly: Bool = false) -> Bool {
        guard Self.codexMarks.contains(where: { Self.has(line, $0) }),
            let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let payload = json["payload"] as? [String: Any]
        else { return false }
        let kind = json["type"] as? String
        if kind == "session_meta" || kind == "turn_context" || payload["type"] as? String == "turn_context" {
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { cursor.cwd = cwd }
            // The model sits in different places by version (even deep in the session's header).
            if let model = payload["model"] as? String ?? Self.firstModel(in: line), !model.isEmpty { cursor.model = model }
            if let effort = payload["effort"] as? String, !effort.isEmpty { cursor.effort = effort }
            return false
        }
        guard !contextOnly, payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let last = info["last_token_usage"] as? [String: Any],
            let stamp = json["timestamp"] as? String, let date = UsageLimits.parseTime(stamp)
        else { return false }
        let all = Self.int(last["input_tokens"]), output = Self.int(last["output_tokens"])
        let cached = Self.int(last["cached_input_tokens"])
        guard all + output > 0 else { return false }
        // The same report again (a limits update, no new request): the running total didn't
        // change. It can also drop (the context compacted): that's a new reference, not a repeat.
        if let total = (info["total_token_usage"] as? [String: Any]).map({ Self.int($0["total_tokens"]) }), total > 0 {
            if cursor.total == total { return false }
            cursor.total = total
        }
        // Not by file: a forked or archived session carries the same reports under another path.
        let key = "c:\(stamp):\(all):\(output):\(cached)"
        guard state.events[key] == nil else { return false }
        state.events[key] = Event(
            agent: "codex", ts: Int(date.timeIntervalSince1970), project: Self.project(cursor.cwd ?? ""),
            // No model named: priced as the current Codex family.
            model: cursor.model ?? "gpt-6", input: max(0, all - cached), output: output, cacheRead: cached, cacheWrite: 0,
            effort: cursor.effort)
        return true
    }

    /// Reading a Codex log from the middle: its folder and model come from its start.
    private func primeCodex(_ handle: FileHandle, into cursor: inout Cursor) {
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 256 * 1024) else { return }
        for line in head.split(separator: 0x0A) {
            _ = codexLine(line, path: "", cursor: &cursor, contextOnly: true)
            if cursor.cwd != nil, cursor.model != nil { return }
        }
    }

    private static let modelPattern = try! NSRegularExpression(pattern: #""model":"([^"]+)""#)

    static func firstModel(in line: Data.SubSequence) -> String? {
        let text = String(decoding: line, as: UTF8.self)
        guard let match = modelPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static let projectLock = NSLock()
    nonisolated(unsafe) private static var projects: [String: String] = [:]

    /// The project a folder belongs to (its git root, looked up once per folder).
    static func project(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        if let known = projectLock.withLock({ projects[cwd] }) { return known }
        let root = FileManager.default.fileExists(atPath: cwd) ? Worktree.root(of: cwd) : cwd
        projectLock.withLock { projects[cwd] = root }
        return root
    }

    /// Whether `needle` is in `line` (memmem: Data's own search is far slower on long lines).
    static func has(_ line: Data.SubSequence, _ needle: Data) -> Bool {
        line.withUnsafeBytes { hay in
            needle.withUnsafeBytes { n in
                memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil
            }
        }
    }

    static func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }
}

// MARK: - Prices and sums

/// What a request would cost at API prices (USD per million tokens). Plans are a
/// flat fee, so this is "how much this would be", an estimate. Prices as
/// Codenotch ships them by default.
public enum TokenPrices {
    struct Price { let input, output, cacheRead, cacheWrite: Double }

    static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-opus-4", Price(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        // The first Opus 4 versions (4, 4.1) cost three times as much.
        ("claude-opus-4-1", Price(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-opus-4-2025", Price(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-sonnet", Price(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
        ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-haiku", Price(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)),
        ("gpt-6", Price(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("gpt-5", Price(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)),
    ]

    public static func cost(_ event: TokenLedger.Event) -> Double? {
        guard let price = table.filter({ event.model.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count })?.price
        else { return nil }
        let m = 1_000_000.0
        return Double(event.input) / m * price.input + Double(event.output) / m * price.output
            + Double(event.cacheRead) / m * price.cacheRead + Double(event.cacheWrite) / m * price.cacheWrite
    }
}

/// One AI's spending, as the sidebar shows it: today, each of the last 7 days,
/// this limit week, and the projects that used most of it.
public struct TokenSpend: Sendable, Equatable {
    public struct Total: Sendable, Equatable {
        public var tokens = 0
        public var cost = 0.0
    }
    public struct Day: Sendable, Equatable {
        public var start: Date
        public var total: Total
    }
    public struct Project: Sendable, Equatable {
        public var path: String
        public var total: Total
        public var share: Double
    }
    /// A model, or an effort, and its part of the week's tokens.
    public struct Share: Sendable, Equatable {
        public var name: String
        public var total: Total
        public var share: Double
    }

    public var today = Total()
    public var days: [Day] = []
    public var week = Total()
    public var projects: [Project] = []
    public var models: [Share] = []
    public var efforts: [Share] = []
    /// Days in a row with some use, up to today (or yesterday, today still empty), and the longest run.
    public var streak = 0
    public var longestStreak = 0
    /// The day with the most tokens, as far back as the logs go.
    public var busiest: Day?
    /// Tokens week by week (weeks starting on the calendar's first day), the last 16, oldest first.
    public var weeks: [Day] = []

    /// `weekStart`: when the limit week began (its renewal minus 7 days); nil = the last 7 days.
    /// `daily`: tokens per day ("2026-10-18") over all the logs, for the streak and the busiest day.
    public static func of(_ events: [TokenLedger.Event], weekStart: Date?, daily: [String: Int] = [:], now: Date = Date(),
                          calendar: Calendar = .current) -> TokenSpend {
        var spend = TokenSpend()
        let todayStart = calendar.startOfDay(for: now)
        spend.days = (0..<7).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: todayStart).map { Day(start: $0, total: Total()) }
        }
        let weekFrom = Int((weekStart ?? now.addingTimeInterval(-7 * 24 * 3600)).timeIntervalSince1970)
        var byProject: [String: Total] = [:]
        var byModel: [String: Total] = [:]
        var byEffort: [String: Total] = [:]
        for event in events {
            let cost = TokenPrices.cost(event) ?? 0
            let date = Date(timeIntervalSince1970: TimeInterval(event.ts))
            if date >= todayStart {
                spend.today.tokens += event.tokens
                spend.today.cost += cost
            }
            if let i = spend.days.lastIndex(where: { $0.start <= date }), date >= spend.days[0].start {
                spend.days[i].total.tokens += event.tokens
                spend.days[i].total.cost += cost
            }
            if event.ts >= weekFrom {
                spend.week.tokens += event.tokens
                spend.week.cost += cost
                byProject[event.project, default: Total()].tokens += event.tokens
                byProject[event.project, default: Total()].cost += cost
                byModel[event.model, default: Total()].tokens += event.tokens
                byModel[event.model, default: Total()].cost += cost
                if let effort = event.effort {
                    byEffort[effort, default: Total()].tokens += event.tokens
                    byEffort[effort, default: Total()].cost += cost
                }
            }
        }
        let weekTokens = max(spend.week.tokens, 1)
        spend.projects = byProject.map { Project(path: $0.key, total: $0.value, share: Double($0.value.tokens) / Double(weekTokens)) }
            .sorted { $0.total.tokens > $1.total.tokens }
        func shares(_ sums: [String: Total]) -> [Share] {
            let all = max(sums.values.map(\.tokens).reduce(0, +), 1)
            return sums.map { Share(name: $0.key, total: $0.value, share: Double($0.value.tokens) / Double(all)) }
                .sorted { $0.total.tokens > $1.total.tokens }
        }
        spend.models = shares(byModel)
        spend.efforts = shares(byEffort)
        spend.addHistory(daily, now: now, calendar: calendar)
        return spend
    }

    /// The streak and the busiest day, from the tokens per day.
    mutating func addHistory(_ daily: [String: Int], now: Date, calendar: Calendar) {
        let used = daily.filter { $0.value > 0 }
        guard !used.isEmpty else { return }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        func key(_ date: Date) -> String { format.string(from: date) }
        // Today not started yet doesn't break it.
        var day = calendar.startOfDay(for: now)
        if used[key(day)] == nil, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        while used[key(day)] != nil, let before = calendar.date(byAdding: .day, value: -1, to: day) {
            streak += 1
            day = before
        }
        // The longest run: over the days in order.
        let dates = used.keys.compactMap { format.date(from: $0) }.sorted()
        var run = 0
        var previous: Date?
        for date in dates {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            longestStreak = max(longestStreak, run)
            previous = date
        }
        longestStreak = max(longestStreak, streak)
        if let top = used.max(by: { $0.value < $1.value }), let start = format.date(from: top.key) {
            busiest = Day(start: start, total: Total(tokens: top.value, cost: 0))
        }
        var byWeek: [Date: Int] = [:]
        for (key, tokens) in used {
            guard let date = format.date(from: key), let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
            byWeek[week, default: 0] += tokens
        }
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            weeks = (0..<16).reversed().compactMap { back in
                calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek).map { Day(start: $0, total: Total(tokens: byWeek[$0] ?? 0, cost: 0)) }
            }
            // From the first week with any use.
            if let first = weeks.firstIndex(where: { $0.total.tokens > 0 }) { weeks.removeFirst(first) }
        }
    }

    /// "Opus 4.1" for "claude-opus-4-1-20250805", "Sonnet 4.5" for "claude-sonnet-4-5"; others as named.
    public static func modelName(_ model: String) -> String {
        guard model.hasPrefix("claude-") else { return model }
        var parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // A date at the end (8 digits) goes.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    /// "1.2M", "830K", "950".
    public static func short(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000_000...: return String(format: "%.1fB", Double(tokens) / 1e9)
        case 10_000_000...: return "\(tokens / 1_000_000)M"
        case 1_000_000...: return String(format: "%.1fM", Double(tokens) / 1e6)
        case 1_000...: return "\(tokens / 1_000)K"
        default: return "\(tokens)"
        }
    }

    /// "$4", "$38", "$0.40".
    public static func money(_ cost: Double) -> String {
        cost >= 10 ? "$\(Int(cost.rounded()))" : String(format: "$%.2f", cost)
    }
}
