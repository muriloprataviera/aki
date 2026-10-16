import CZstd
import Foundation

/// Claude's limits for people who use the Claude app and not Claude Code (no status
/// line to read them from): the app keeps the answer of its own "usage" request in its
/// HTTP cache (Chromium's Simple Cache, the body zstd-compressed). Only that entry is
/// read, never another page's. Approach from Codenotch (MIT, see LICENSE).
public enum ClaudeAppUsage {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Claude/Cache/Cache_Data")

    /// The newest usage answer in the cache, or nil (no app, nothing cached yet).
    public static func read(directory: URL = directory) -> UsageLimits? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return nil }
        // Newest first; small entries only (the answer is a few kB), a few hundred at most.
        let candidates = names.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize, size > headerBytes, size <= 512 * 1024,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }
        // The newest few hundred, newest first (another account's answer would be newer);
        // then the entry found last time, when a busy cache pushed it past them.
        let remembered = lastFoundLock.withLock { lastFound }
        let newest = Array(candidates.prefix(400))
        // None there: the rest of the cache too, at most every ten minutes (only each
        // entry's address is read, but a month's cache holds thousands).
        let deep = lastFoundLock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastDeepScan) > 600 else { return false }
            return true
        }
        let rest = candidates.dropFirst(400).filter { deep || $0.0 == remembered }
        // The deep look counts as done however it ends (found or not).
        if deep { lastFoundLock.withLock { lastDeepScan = Date() } }
        for (url, modified) in newest + rest {
            if let limits = limits(in: url, modified: modified) {
                lastFoundLock.withLock { lastFound = url }
                return limits
            }
        }
        return nil
    }

    nonisolated(unsafe) private static var lastDeepScan = Date.distantPast

    nonisolated(unsafe) private static var lastFound: URL?
    private static let lastFoundLock = NSLock()

    static let headerBytes = 24

    private static func limits(in url: URL, modified: Date) -> UsageLimits? {
        body(of: url, if: isUsage).flatMap { parse($0, updated: modified) }
    }

    /// An entry's answer, when its key (the request's address) passes `wanted`: the key
    /// is read first, and anything else is never read whole.
    private static func body(of url: URL, if wanted: (String) -> Bool) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerBytes + 8 * 1024),
              let key = key(in: [UInt8](head)), wanted(key)
        else { return nil }
        try? handle.seek(toOffset: 0)
        guard let entry = try? handle.read(upToCount: 512 * 1024) else { return nil }
        let bytes = [UInt8](entry)
        let start = headerBytes + key.utf8.count
        guard bytes.count > start + 4, Array(bytes[start..<(start + 4)]) == [0x28, 0xB5, 0x2F, 0xFD] else { return nil }
        return decompress(Array(bytes[start...]))
    }

    nonisolated(unsafe) private static var conversationsRead: (list: [DesktopApps.Conversation], at: Date) = ([], .distantPast)

    /// Your recent chats in the Claude app, newest first, from the list the app keeps of
    /// them (the answer to its own `chat_conversations_v2` request; only their names and
    /// times are read). Looked for every half minute at most.
    public static func conversations(directory: URL = directory) -> [DesktopApps.Conversation] {
        if let recent = lastFoundLock.withLock({ Date().timeIntervalSince(conversationsRead.at) < 30 ? conversationsRead.list : nil }) {
            return recent
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let names = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let candidates = names.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize, size > headerBytes, size <= 512 * 1024,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }
        // The newest few hundred first, then the entry found last time (a busy cache may
        // have pushed it past them).
        let remembered = lastFoundLock.withLock { listFound }
        // None known yet: the whole cache, at most every ten minutes (only each entry's
        // address is read).
        let deep = lastFoundLock.withLock { () -> Bool in
            guard remembered == nil, Date().timeIntervalSince(lastListScan) > 600 else { return false }
            lastListScan = Date()
            return true
        }
        let order = Array(candidates.prefix(600)) + candidates.dropFirst(600).filter { deep || $0.0 == remembered }
        var list: [DesktopApps.Conversation]?
        for (url, _) in order {
            if let body = body(of: url, if: isConversationList), let found = parseConversations(body) {
                list = found
                lastFoundLock.withLock { listFound = url }
                break
            }
        }
        // Not found this time: the last list stays (better than every chat vanishing).
        let result = lastFoundLock.withLock { () -> [DesktopApps.Conversation] in
            let kept = list ?? conversationsRead.list
            for conversation in kept { seen[conversation.id] = conversation }
            conversationsRead = (kept, Date())
            return kept
        }
        return result
    }

    nonisolated(unsafe) private static var listFound: URL?
    nonisolated(unsafe) private static var lastListScan = Date.distantPast

    /// Every chat seen in a list since Aki started, by id: one that has left the app's first
    /// page (with marks waiting for it, or chosen) is still known by its name.
    nonisolated(unsafe) private static var seen: [String: DesktopApps.Conversation] = [:]

    /// Chats seen before, by id (those no longer on the app's first page).
    public static func known(ids: Set<String>) -> [DesktopApps.Conversation] {
        lastFoundLock.withLock { ids.compactMap { seen[$0] } }
    }

    /// The first page of your chats (not only the starred ones, not the archived).
    public static func isConversationList(_ key: String) -> Bool {
        guard key.contains("claude.ai/api/organizations/"), key.contains("/chat_conversations") else { return false }
        let query = key.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
        return !query.contains("offset=") || query.contains("offset=0")
            ? !query.contains("starred=true") && !query.contains("archived=true") && !query.contains("search")
            : false
    }

    /// `{"data": [{"uuid": …, "name": …, "updated_at": …}, …]}` (or the list itself).
    public static func parseConversations(_ body: Data) -> [DesktopApps.Conversation]? {
        let json = try? JSONSerialization.jsonObject(with: body)
        guard let data = (json as? [String: Any])?["data"] as? [[String: Any]] ?? json as? [[String: Any]] else { return nil }
        let list = data.compactMap { item -> DesktopApps.Conversation? in
            guard let id = item["uuid"] as? String, !id.isEmpty, (item["is_temporary"] as? Bool) != true else { return nil }
            let name = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let updated = (item["updated_at"] as? String).flatMap(time) ?? .distantPast
            return DesktopApps.Conversation(id: id, name: name, updated: updated)
        }.sorted { $0.updated > $1.updated }
        return data.isEmpty || !list.isEmpty ? list : nil
    }

    /// `…/api/organizations/<id>/usage` on claude.ai (with or without a query).
    public static func isUsage(_ key: String) -> Bool {
        guard key.contains("claude.ai/api/organizations/") || key.contains("anthropic.com/api/organizations/") else { return false }
        let path = key.split(separator: "?").first ?? ""
        return path.hasSuffix("/usage")
    }

    /// The entry's key: after a 24-byte header (magic, version, key length at 12).
    static func key(in bytes: [UInt8]) -> String? {
        guard bytes.count > headerBytes else { return nil }
        let magic = (0..<8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[$1]) }
        guard magic == 0xFCFB_6D1B_A772_5C30 else { return nil }
        let length = Int((12..<16).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[$1]) })
        guard length > 0, length <= 8 * 1024, headerBytes + length <= bytes.count else { return nil }
        return String(bytes: bytes[headerBytes..<(headerBytes + length)], encoding: .utf8)
    }

    private static func decompress(_ frame: [UInt8]) -> Data? {
        frame.withUnsafeBytes { source -> Data? in
            let size = ZSTD_findFrameCompressedSize(source.baseAddress, source.count)
            guard ZSTD_isError(size) == 0, size > 0, size <= source.count else { return nil }
            var output = [UInt8](repeating: 0, count: 1024 * 1024)
            let written = output.withUnsafeMutableBytes { ZSTD_decompress($0.baseAddress, $0.count, source.baseAddress, size) }
            guard ZSTD_isError(written) == 0, written > 0 else { return nil }
            return Data(output[0..<written])
        }
    }

    /// `{"five_hour": {"utilization": 29.0, "resets_at": "2026-…"}, "seven_day": {…}}`.
    public static func parse(_ body: Data, updated: Date) -> UsageLimits? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func limit(_ name: String) -> ClaudeStatus.Limit? {
            guard let window = json[name] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = (window["resets_at"] as? String).flatMap(time)
            return ClaudeStatus.Limit(percent: Int(used.rounded()), resets: resets)
        }
        let fiveHour = limit("five_hour"), week = limit("seven_day")
        guard fiveHour != nil || week != nil else { return nil }
        return UsageLimits(agent: .claude, fiveHour: fiveHour, week: week, updated: updated)
    }

    private static func time(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
