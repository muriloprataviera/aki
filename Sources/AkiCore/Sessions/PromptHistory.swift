import Foundation

/// When you last sent something to each conversation (typed, or a mark Aki typed
/// in), from the prompt histories Claude Code and Codex keep. Only their recent end
/// is read, and again only when a file changed.
public enum PromptHistory {
    public static var claude: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/history.jsonl")
    }
    public static var codex: URL { UsageLimits.codexHome.appending(path: "history.jsonl") }

    private struct Read { var size: Int; var modified: Date; var from: Date; var last: [String: Date] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reads: [String: Read] = [:]

    /// Session id (Claude's, or Codex's conversation id) → the last prompt sent to it
    /// since `since`. Older ones aren't looked for.
    public static func lastSent(since: Date, files: [URL] = [claude, codex]) -> [String: Date] {
        var all: [String: Date] = [:]
        for file in files {
            all.merge(lastSent(in: file, since: since)) { max($0, $1) }
        }
        return all
    }

    static func lastSent(in file: URL, since: Date) -> [String: Date] {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate else { return [:] }
        if let known = lock.withLock({ reads[file.path] }), known.size == size, known.modified == modified, known.from <= since {
            return known.last.filter { $0.value >= since }
        }
        let last = read(file, size: size, since: since)
        lock.withLock { reads[file.path] = Read(size: size, modified: modified, from: since, last: last) }
        return last
    }

    /// From the end back, a growing piece at a time, until a prompt older than `since`.
    private static func read(_ file: URL, size: Int, since: Date) -> [String: Date] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        var bytes = 256 * 1024
        while true {
            let start = max(0, size - bytes)
            try? handle.seek(toOffset: UInt64(start))
            let data = (try? handle.read(upToCount: size - start)) ?? Data()
            var last: [String: Date] = [:]
            var reachedOlder = start == 0
            // The first line of a piece may be cut: skipped, unless it's the file's start.
            var lines = data.split(separator: UInt8(ascii: "\n"))
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                guard let (id, at) = entry(Data(line)) else { continue }
                if at < since { reachedOlder = true; break }
                if last[id] == nil { last[id] = at }
            }
            if reachedOlder || bytes >= 16 * 1024 * 1024 { return last }
            bytes *= 4
        }
    }

    /// Claude: `{"timestamp": <ms>, "sessionId": …}`; Codex: `{"ts": <s>, "session_id": …}`.
    static func entry(_ line: Data) -> (String, Date)? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let id = json["sessionId"] as? String, let ms = (json["timestamp"] as? NSNumber)?.doubleValue {
            return (id, Date(timeIntervalSince1970: ms / 1000))
        }
        if let id = json["session_id"] as? String, let s = (json["ts"] as? NSNumber)?.doubleValue {
            return (id, Date(timeIntervalSince1970: s))
        }
        return nil
    }

    private static let switchLock = NSLock()
    nonisolated(unsafe) private static var conversations: [Int32: (id: String, at: Date?)] = [:]

    /// When a process moved to another conversation (`/clear`, `/resume`, Codex's `/new`):
    /// its first prompt there is still to come, and the history names the old one. Nil
    /// for the conversation it had when first seen (Aki just opened knows no switch).
    public static func switched(_ pid: Int32, to conversation: String, now: Date = Date()) -> Date? {
        switchLock.withLock {
            guard let known = conversations[pid] else {
                conversations[pid] = (conversation, nil)
                return nil
            }
            if known.id == conversation { return known.at }
            conversations[pid] = (conversation, now)
            return now
        }
    }

    /// When a process started (a conversation just opened has had no prompt yet).
    public static func started(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_starttime
        guard time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }
}
