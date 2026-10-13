import Foundation

/// Codex's own log of each conversation (`~/.codex/sessions/…/rollout-*.jsonl`), which
/// it keeps open while it runs. A turn is open between `task_started` and
/// `task_complete` (or `turn_aborted`): the time Codex is thinking, which barely shows
/// in its CPU (it waits on the model).
public enum CodexSessions {
    /// The log each Codex process has open (its own conversation, resumed ones too).
    public static func openLogs(of pids: [Int32]) -> [Int32: URL] {
        guard !pids.isEmpty else { return [:] }
        var result: [Int32: URL] = [:]
        var pid: Int32?
        let list = pids.map(String.init).joined(separator: ",")
        for line in AgentSessions.run("/usr/sbin/lsof", ["-a", "-nP", "-p", list, "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, line.hasSuffix(".jsonl"), line.contains("/rollout-") {
                result[pid] = URL(filePath: String(line.dropFirst()))
            }
        }
        return result
    }

    /// Whether the conversation in this log is in the middle of a turn.
    public static func working(log: URL, now: Date = Date()) -> Bool {
        guard let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              // A turn left open by a Codex that hung: silent for long, not working.
              now.timeIntervalSince(modified) < 900
        else { return false }
        // A long turn can push its start far back: read further until a turn event shows.
        var bytes: UInt64 = 262_144
        while true {
            let (text, whole) = tail(of: log, bytes: bytes)
            if let open = turnOpen(text) { return open }
            if whole || bytes >= 16 << 20 { return false }
            bytes *= 4
        }
    }

    /// Whether the last turn in a stretch of the log is still open (nil: no turn event in it).
    public static func turnOpen(_ text: String) -> Bool? {
        let started = text.range(of: "\"type\":\"task_started\"", options: .backwards)?.lowerBound
        let ended = ["\"type\":\"task_complete\"", "\"type\":\"turn_aborted\""]
            .compactMap { text.range(of: $0, options: .backwards)?.lowerBound }.max()
        switch (started, ended) {
        case (nil, nil): return nil
        case (_?, nil): return true
        case (nil, _?): return false
        case let (s?, e?): return e < s
        }
    }

    /// The last part of a log, and whether that is all of it.
    static func tail(of file: URL, bytes: UInt64) -> (String, Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ("", true) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return (String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self), size <= bytes)
    }
}
