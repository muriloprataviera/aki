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
        let output = run("/usr/bin/git", ["-C", directory, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = output.isEmpty ? directory : output
        rootLock.withLock { roots[directory] = root }
        return root
    }

    /// Worktree serving a local TCP port, if any process in a folder listens on it.
    public static func forPort(_ port: Int) -> String? {
        guard let pid = listeningPorts()[port], let cwd = cwd(of: pid), cwd != "/" else { return nil }
        return root(of: cwd)
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
    static func listeningPorts() -> [Int: Int32] {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        var ports: [Int: Int32] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let port = Int(line.split(separator: ":").last ?? "") {
                ports[port] = ports[port] ?? pid
            }
        }
        return ports
    }

    static func cwd(of pid: Int32) -> String? {
        let output = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        return output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
