import Foundation

/// Talks to the running Aki server with the user's token. Used by the CLI and the MCP server.
public struct AkiClient: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case serverDown(port: UInt16)
        case http(status: Int, message: String)

        public var description: String {
            switch self {
            case .serverDown(let port): "Aki isn't running (nothing on 127.0.0.1:\(port)). Open Aki.app or run `aki serve`."
            case .http(let status, let message): "server answered \(status): \(message)"
            }
        }
    }

    public let port: UInt16
    private let token: String

    public init(home: AkiHome = .default, port: UInt16? = nil) throws {
        self.port = port ?? ProcessInfo.processInfo.environment["AKI_PORT"].flatMap(UInt16.init) ?? Aki.defaultPort
        self.token = try home.token()
    }

    public func list(status: String = "pending") async throws -> [Annotation] {
        let data = try await request("GET", "/api/annotations?status=\(status)")
        let reply = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return (reply["annotations"]?.array ?? []).compactMap { $0.object.map(Annotation.init) }
    }

    public func get(_ id: String) async throws -> Annotation? {
        do {
            let data = try await request("GET", "/api/annotations/\(escape(id))")
            let reply = try JSONDecoder().decode([String: JSONValue].self, from: data)
            return reply["annotation"]?.object.map(Annotation.init)
        } catch Failure.http(404, _) {
            return nil
        }
    }

    public func update(_ id: String, _ patch: [String: JSONValue]) async throws {
        _ = try await request("PUT", "/api/annotations/\(escape(id))", body: try JSON.encode(patch))
    }

    /// Pending marks the agent has now read: the sidebar stops offering to send them.
    public func markRead(_ annotations: [Annotation]) async {
        let now = ISO8601DateFormatter().string(from: Date())
        for annotation in annotations where annotation["status"]?.string == "pending" && annotation["read_at"]?.string == nil {
            try? await update(annotation.id, ["read_at": .string(now)])
        }
    }

    public func delete(_ id: String) async throws {
        _ = try await request("DELETE", "/api/annotations/\(escape(id))")
    }

    private func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.serverDown(port: port)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]?.string
            throw Failure.http(status: status, message: message ?? "")
        }
        return data
    }
}

/// The annotations that belong to one worktree: tagged with it, or on a localhost
/// page served from it right now.
public struct WorktreeFilter: Sendable {
    public let worktree: String
    public let ports: Set<Int>
    /// The agent session asking, when known: marks aimed at another session in
    /// the same worktree aren't its business.
    public let sessionId: String?

    public init(worktree: String, sessionId: String? = nil) {
        self.worktree = worktree
        self.ports = Worktree.ports(servedFrom: worktree)
        self.sessionId = sessionId
    }

    public func matches(_ annotation: Annotation) -> Bool {
        if let target = annotation["session_id"]?.string {
            // Aimed at one session: only that session takes it (or, from outside
            // any session, whoever works in its worktree).
            if let sessionId { return target == sessionId }
            return annotation["worktree"]?.string == worktree
        }
        if let tagged = annotation["worktree"]?.string { return tagged == worktree }
        guard let url = annotation["url"]?.string, let port = Worktree.localPort(of: url) else { return false }
        return ports.contains(port)
    }
}
