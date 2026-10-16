import Foundation
import SQLite3

/// The Codex app's conversations ("Revisar NFs no Drive"), from the list Codex keeps of
/// its threads (`state_5.sqlite`, opened read-only): only names, times and where each
/// one's log is, never what was said. The app's own ones only (not terminal sessions,
/// headless runs, subagents or voice chats), newest first.
public enum CodexAppThreads {
    nonisolated(unsafe) private static var read: (list: [DesktopApps.Conversation], at: Date) = ([], .distantPast)
    private static let lock = NSLock()

    /// Looked at every quarter of a minute at most (the sidebar asks every three seconds).
    public static func recent(limit: Int = DesktopApps.conversationsShown, home: URL = UsageLimits.codexHome) -> [DesktopApps.Conversation] {
        if let known = lock.withLock({ Date().timeIntervalSince(read.at) < 15 ? read.list : nil }) { return known }
        let list = query(limit: limit, home: home)
        lock.withLock { read = (list, Date()) }
        return list
    }

    static func query(limit: Int, home: URL) -> [DesktopApps.Conversation] {
        // The newest of the state files ("state_5.sqlite" now; a later Codex may number it anew).
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        guard let name = files.filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") })
            .max(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        else { return [] }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(home.appending(path: name).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(db, 200)
        let sql = """
            SELECT id, COALESCE(NULLIF(TRIM(name), ''), ''), title, updated_at, rollout_path FROM threads
            WHERE source = 'vscode' AND archived = 0
              AND COALESCE(thread_source, 'user') NOT IN ('subagent', 'voice_chat')
            ORDER BY updated_at DESC LIMIT ?
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))
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
