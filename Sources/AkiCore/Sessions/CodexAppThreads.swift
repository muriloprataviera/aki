import Foundation
import SQLite3

/// The Codex app's conversations ("Revisar NFs no Drive"), from the list Codex keeps of
/// its threads (`state_5.sqlite`, opened read-only): only names, times and where each
/// one's log is, never what was said. The app's own ones only (not terminal sessions,
/// headless runs, subagents or voice chats), newest first.
public enum CodexAppThreads {
    nonisolated(unsafe) private static var read: (list: [DesktopApps.Conversation], at: Date) = ([], .distantPast)
    private static let lock = NSLock()

    /// The newest ones (more than are shown: an older one may still have marks waiting).
    /// Looked at every quarter of a minute at most (the sidebar asks every three seconds).
    public static func recent(limit: Int = 50, home: URL = UsageLimits.codexHome) -> [DesktopApps.Conversation] {
        if let known = lock.withLock({ Date().timeIntervalSince(read.at) < 15 ? read.list : nil }) { return known }
        let list = query(limit: limit, home: home)
        lock.withLock { read = (list, Date()) }
        return list
    }

    /// Those threads, by id, wherever they sit in the list (one with marks still waiting).
    public static func threads(ids: Set<String>, home: URL = UsageLimits.codexHome) -> [DesktopApps.Conversation] {
        // In batches of 50 (one query each), so none is left out.
        let all = Array(ids).sorted()
        return stride(from: 0, to: all.count, by: 50).flatMap { start in
            let batch = Array(all[start..<min(start + 50, all.count)])
            return query(limit: batch.count, home: home, ids: batch)
        }
    }

    static func query(limit: Int, home: URL, ids: [String] = []) -> [DesktopApps.Conversation] {
        // The newest of the state files ("state_5.sqlite" now; a later Codex may number it anew).
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        guard let name = files.filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") })
            .max(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // With Codex closed its write-ahead files are gone, and a read-only open can't make
        // them: then the file is read as it is (nothing is writing to it).
        let file = home.appending(path: name)
        var link = URLComponents()
        link.scheme = "file"
        link.path = file.path
        if !FileManager.default.fileExists(atPath: file.path + "-wal") { link.queryItems = [URLQueryItem(name: "immutable", value: "1")] }
        guard let uri = link.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { return [] }
        sqlite3_busy_timeout(db, 200)
        let sql = """
            SELECT id, COALESCE(NULLIF(TRIM(name), ''), ''), title, updated_at, rollout_path FROM threads
            WHERE source = 'vscode' AND archived = 0
              AND COALESCE(thread_source, 'user') NOT IN ('subagent', 'voice_chat')
            \(ids.isEmpty ? "" : "AND id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")")
            ORDER BY updated_at DESC LIMIT ?
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        // Each id bound as text (never written into the query itself).
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), id, -1, transient) }
        sqlite3_bind_int(statement, Int32(ids.count + 1), Int32(limit))
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var list: [DesktopApps.Conversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(0)
            // Its name, else what Codex shows for it: the first line of its first message.
            var title = text(1)
            if title.isEmpty {
                title = text(2).split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            guard !id.isEmpty, !title.isEmpty else { continue }
            let path = text(4)
            list.append(DesktopApps.Conversation(
                id: id, name: title, updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3))),
                log: path.isEmpty ? nil : URL(filePath: path)))
        }
        return list
    }
}
