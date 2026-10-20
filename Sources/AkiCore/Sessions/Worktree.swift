import Foundation

/// Which worktree an annotation belongs to. A page on localhost belongs to the
/// worktree whose process is listening on that port (port → pid → cwd → git root).
public enum Worktree {
    private static let rootLock = NSLock()
    nonisolated(unsafe) private static var roots: [String: String] = [:]

    /// Git root of `directory`, or the directory itself outside a repo. Remembered:
    /// a folder's repository doesn't change while it's open.
    public static func root(of directory: String) -> String {
        if let known = rootLock.withLock({ roots[directory] }) { return known }
        // Out of time (a folder iCloud is still downloading): the folder itself for now,
        // not kept, so it's asked again later. No repository (an answer, empty): kept.
        guard let answer = Command.output("/usr/bin/git", ["-C", directory, "rev-parse", "--show-toplevel"], anyEnd: true)
        else { return directory }
        let output = String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = output.isEmpty ? directory : output
        rootLock.withLock { roots[directory] = root }
        return root
    }

    /// Worktree serving a local TCP port, if any process in a folder listens on it.
    public static func forPort(_ port: Int) -> String? {
        server(ofPort: port)?.worktree
    }

    /// The process listening on a local port and its worktree, for a page at `host`.
    public static func server(ofPort port: Int, host: String = "localhost") -> (pid: Int32, worktree: String)? {
        guard let pid = listeningPorts(host: host)[port], let cwd = cwd(of: pid), cwd != "/" else { return nil }
        return (pid, root(of: cwd))
    }

    /// Ports served from inside `worktree`.
    public static func ports(servedFrom worktree: String) -> Set<Int> {
        var ports = Set<Int>()
        var cwdByPID: [Int32: String?] = [:]
        for (port, pid) in listeningPorts() {
            let cwd = cwdByPID[pid] ?? cwd(of: pid)
            cwdByPID[pid] = cwd
            if let cwd, cwd == worktree || cwd.hasPrefix(worktree + "/") {
                ports.insert(port)
            }
        }
        return ports
    }

    /// Local port of a URL on localhost / 127.0.0.1, nil for anything else.
    public static func localPort(of url: String) -> Int? {
        guard let components = URLComponents(string: url),
            let host = components.host, ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "::1"].contains(host)
        else { return nil }
        return components.port ?? (components.scheme == "https" ? 443 : 80)
    }

    /// TCP port → pid for every listening socket of the current user.
    static func listeningPorts(host: String = "localhost") -> [Int: Int32] {
        listeningPorts(lsof: run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]), host: host)
    }

    /// Two processes on one port (one on `[::1]:5173`, another on `*:5173`): the one the
    /// browser reaches at `host`. For "localhost" it tries ::1 first, then 127.0.0.1;
    /// "127.0.0.1" never reaches one on ::1 only, nor "[::1]" one on 127.0.0.1.
    public static func listeningPorts(lsof output: String, host: String = "localhost") -> [Int: Int32] {
        let wildcard: (Substring) -> Bool = { $0.hasPrefix("*") || $0.hasPrefix("[::]") }
        func rank(_ address: Substring) -> Int {
            switch host {
            case "127.0.0.1", "0.0.0.0": address.hasPrefix("127.") ? 0 : wildcard(address) ? 1 : 3
            case "::1", "[::1]": address.hasPrefix("[::1]") ? 0 : wildcard(address) ? 1 : 3
            default: address.hasPrefix("[::1]") ? 0 : address.hasPrefix("127.") ? 1 : wildcard(address) ? 2 : 3
            }
        }
        var ports: [Int: (pid: Int32, rank: Int)] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let port = Int(line.split(separator: ":").last ?? "") {
                let address = line.dropFirst()
                if let known = ports[port], known.rank <= rank(address) { continue }
                ports[port] = (pid, rank(address))
            }
        }
        return ports.mapValues(\.pid)
    }

    static func cwd(of pid: Int32) -> String? {
        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        return output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        // (As before, what it printed counts however it ended.)
        Command.output(path, arguments, anyEnd: true).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
