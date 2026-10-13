import Darwin
import Foundation

/// Codex's own log of each conversation (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
/// A turn is open between `task_started` and `task_complete` (or `turn_aborted`): the
/// time Codex is thinking, which barely shows in its CPU (it waits on the model).
public enum CodexSessions {
    /// Whether the Codex process `pid`, in `cwd`, is in the middle of a turn.
    public static func working(pid: Int32, cwd: String, home: URL = UsageLimits.codexHome, now: Date = Date()) -> Bool {
        guard let log = log(cwd: cwd, started: started(pid), home: home, now: now),
              // A turn left open by a Codex that quit or hung: silent for long, not working.
              now.timeIntervalSince(log.modified) < 900
        else { return false }
        return turnOpen(tail(of: log.url))
    }

    /// Whether the last turn in a stretch of the log is still open.
    public static func turnOpen(_ text: String) -> Bool {
        guard let started = text.range(of: "\"type\":\"task_started\"", options: .backwards) else { return false }
        let ended = ["\"type\":\"task_complete\"", "\"type\":\"turn_aborted\""]
            .compactMap { text.range(of: $0, options: .backwards)?.lowerBound }.max()
        return ended.map { $0 < started.lowerBound } ?? true
    }

    /// The newest log written in `cwd` since the process started (looked for in the
    /// day folders from its start to now).
    static func log(cwd: String, started: Date?, home: URL, now: Date) -> (url: URL, modified: Date)? {
        let root = home.appending(path: "sessions")
        let from = (started ?? now).addingTimeInterval(-86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var day = calendar.startOfDay(for: from)
        var best: (url: URL, modified: Date)?
        while day <= now {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appending(path: String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= (started ?? .distantPast).addingTimeInterval(-5),
                      modified > (best?.modified ?? .distantPast),
                      Self.cwd(of: file) == cwd
                else { continue }
                best = (file, modified)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return best
    }

    nonisolated(unsafe) private static var cwds: [String: String] = [:]
    private static let lock = NSLock()

    /// The folder a log was written in, from its first line (kept: it never changes).
    static func cwd(of file: URL) -> String? {
        lock.lock()
        if let known = cwds[file.path] { lock.unlock(); return known }
        lock.unlock()
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192), let text = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self) as String?,
              let key = text.range(of: "\"cwd\":\""),
              let end = text[key.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let found = String(text[key.upperBound..<end]).replacingOccurrences(of: "\\/", with: "/")
        lock.lock()
        cwds[file.path] = found
        lock.unlock()
        return found
    }

    /// The last part of a log (where the latest turn is).
    static func tail(of file: URL, bytes: UInt64 = 262_144) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// When a process started.
    static func started(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}
