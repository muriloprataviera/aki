import Foundation

/// Uses one of the limit resets OpenAI gives a Codex account, the way Codex's own
/// `/usage` → "Redeem reset" does: through Codex itself (`codex app-server`, its
/// `account/rateLimitResetCredit/consume`), so its sign-in never passes through Aki.
/// Only when you click and confirm; nothing here runs on its own.
public enum CodexResets {
    public enum Outcome: Sendable, Equatable {
        /// Done: the limits as Codex reports them right after (nil if it didn't say).
        case reset(UsageLimits?)
        /// OpenAI says the usage doesn't need one now (the limit isn't reached).
        case notNeeded
        /// None left to use.
        case noneLeft
        /// Codex isn't on this Mac, or didn't answer.
        case failed
    }

    /// Where Codex is (Aki has no shell's path): Homebrew, npm, the Codex and ChatGPT apps.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex", home + "/.npm-global/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex", "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: found) }
        return fromShell()
    }

    /// Where your Terminal finds `codex` (nvm, asdf, another prefix): asked of a login
    /// shell, once, with a time limit.
    private static func fromShell() -> URL? {
        if let known = shellLock.withLock({ shellFound }) { return known }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read as it comes; at 5 s the shell is killed (an interactive zsh ignores a plain
        // stop) and nothing more is waited for, whatever keeps the pipe open.
        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.signal()
            } else {
                collected.append(chunk)
            }
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            output.fileHandleForReading.readabilityHandler = nil
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        let data = collected.data
        // The last line that is a path (a shell's greeting may come first).
        let path = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).last { $0.hasPrefix("/") }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        shellLock.withLock { shellFound = url }
        return url
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
        var data: Data { lock.withLock { bytes } }
    }

    nonisolated(unsafe) private static var shellFound: URL?
    private static let shellLock = NSLock()

    /// Uses the available reset that expires first.
    public static func useOne() async -> Outcome {
        // Off the main thread: finding it may ask a login shell.
        await Task.detached {
            guard let executable else { return .failed }
            return run(executable)
        }.value
    }

    private static func run(_ executable: URL) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        // Homebrew's `codex` is a Node script: `node` must be on the path.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failed }
        // Never left waiting: Codex stops after 30 s whatever happens.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning { process.terminate() }
        }
        var reader = Lines(handle: output.fileHandleForReading)
        func send(_ message: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        /// The answer to request `id` (notifications in between are skipped).
        func answer(_ id: Int) -> [String: Any]? {
            while let line = reader.next() {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (json["id"] as? NSNumber)?.intValue == id
                else { continue }
                return json
            }
            return nil
        }
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "aki", "version": Aki.version]]])
        guard answer(1)?["result"] != nil else { return .failed }
        send(["method": "initialized"])
        send(["id": 2, "method": "account/rateLimits/read"])
        guard let read = answer(2)?["result"] as? [String: Any] else { return .failed }
        guard let credit = soonest(in: read) else { return .noneLeft }
        send(["id": 3, "method": "account/rateLimitResetCredit/consume",
              "params": ["creditId": credit, "idempotencyKey": "aki-" + UUID().uuidString]])
        guard let consumed = answer(3)?["result"] as? [String: Any] else { return .failed }
        switch consumed["outcome"] as? String {
        case "reset":
            // The limits now, for the ring (the logs only say so on Codex's next message).
            send(["id": 4, "method": "account/rateLimits/read"])
            return .reset((answer(4)?["result"] as? [String: Any]).flatMap(limits))
        case "nothingToReset": return .notNeeded
        case "noCredit", "alreadyRedeemed": return .noneLeft
        default: return .failed
        }
    }

    /// The available reset that expires first, from `account/rateLimits/read`.
    static func soonest(in read: [String: Any]) -> String? {
        let credits = (read["rateLimitResetCredits"] as? [String: Any])?["credits"] as? [[String: Any]] ?? []
        return credits.filter { $0["status"] as? String == "available" }
            .min { (($0["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity) < (($1["expiresAt"] as? NSNumber)?.doubleValue ?? .infinity) }?["id"] as? String
    }

    /// Codex's limits from `account/rateLimits/read` (the windows by their length, as in its logs).
    static func limits(_ read: [String: Any]) -> UsageLimits? {
        guard let rate = read["rateLimits"] as? [String: Any] else { return nil }
        var result = UsageLimits(agent: .codex, fiveHour: nil, week: nil, updated: Date())
        for key in ["primary", "secondary"] {
            guard let window = rate[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let limit = ClaudeStatus.Limit(percent: Int(used.rounded()),
                                           resets: (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            switch (window["windowDurationMins"] as? NSNumber)?.intValue ?? 0 {
            case 300: result.fiveHour = limit
            case 10080: result.week = limit
            case 43200: result.month = limit
            default: continue
            }
        }
        return result.week == nil && result.fiveHour == nil && result.month == nil ? nil : result
    }

    /// Lines off a pipe, as they come.
    private struct Lines {
        let handle: FileHandle
        var buffer = Data()

        init(handle: FileHandle) { self.handle = handle }

        mutating func next() -> Data? {
            while true {
                if let end = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<end]
                    buffer.removeSubrange(buffer.startIndex...end)
                    return Data(line)
                }
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }  // closed (or stopped at the deadline)
                buffer.append(chunk)
            }
        }
    }
}
