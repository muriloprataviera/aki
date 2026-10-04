import Foundation

/// The annotations API, route-compatible with Vibe Annotations 8864e12c:
///
///     GET    /health                      public, no data
///     GET    /api/annotations             ?status=&url=&worktree=&limit=  (no limit by default)
///     POST   /api/annotations             create, or merge by id
///     POST   /api/annotations/sync        replace everything (extension sync)
///     GET    /api/annotations/:id
///     PUT    /api/annotations/:id         partial merge
///     DELETE /api/annotations/:id
///
/// Differences on purpose: every route but /health needs the token or an allowed
/// extension origin, the Host header must be local (blocks DNS rebinding), CORS is
/// only granted to allowed extension origins, and listing has no default limit
/// (Vibe's default of 50 made its extension drop older annotations).
public struct AkiAPI: Sendable {
    public let store: AnnotationStore
    private let token: String
    private let allowedOrigins: Set<String>
    private let worktreeForPort: @Sendable (Int) -> String?

    /// `allowedOrigins` are full origins such as `chrome-extension://<id>`.
    /// `worktreeForPort` tags annotations on localhost pages with the worktree serving them.
    public init(
        store: AnnotationStore, token: String, allowedOrigins: Set<String> = [],
        worktreeForPort: @escaping @Sendable (Int) -> String? = Worktree.forPort
    ) {
        self.store = store
        self.token = token
        self.allowedOrigins = allowedOrigins
        self.worktreeForPort = worktreeForPort
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard hasLocalHost(request) else { return .error(403, "Host not allowed") }
        let origin = request.headers["origin"]
        let originAllowed = origin.map(allowedOrigins.contains) ?? false

        var response: HTTPResponse
        if request.method == "OPTIONS" {
            response = originAllowed ? HTTPResponse(status: 204) : .error(403, "Origin not allowed")
        } else if request.path == "/health" {
            response = health()
        } else if originAllowed || hasToken(request) {
            response = await route(request)
        } else {
            response = .error(401, "Missing or invalid token")
        }

        if originAllowed, let origin {
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
            response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
            response.headers["Vary"] = "Origin"
        }
        return response
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "api", parts[1] == "annotations" else {
            return .error(404, "Not found")
        }
        do {
            switch (request.method, parts.count) {
            case ("GET", 2): return await list(request.query)
            case ("POST", 2): return try await create(request.body)
            case ("POST", 3) where parts[2] == "sync": return try await sync(request.body)
            case ("GET", 3): return await get(parts[2])
            case ("PUT", 3): return try await update(parts[2], request.body)
            case ("DELETE", 3): return try await delete(parts[2])
            case (_, 2), (_, 3): return .error(405, "Method not allowed")
            default: return .error(404, "Not found")
            }
        } catch let error as BadRequest {
            return .error(400, error.message)
        } catch {
            return .error(500, "Failed to save annotations")
        }
    }

    private func health() -> HTTPResponse {
        .json(
            200,
            [
                "status": "ok", "app": "aki", "version": .string(Aki.version),
                "minExtensionVersion": "1.0.0", "timestamp": .string(JSON.now()),
            ])
    }

    private func list(_ query: [String: String]) async -> HTTPResponse {
        let filter = AnnotationStore.Filter(
            status: query["status"], url: query["url"], worktree: query["worktree"],
            limit: query["limit"].flatMap { Int($0) })
        let (annotations, total) = await store.list(filter)
        return .json(
            200,
            [
                "annotations": .array(annotations.map { .object($0.fields) }),
                "count": .number(Double(annotations.count)), "total": .number(Double(total)),
            ])
    }

    private func create(_ body: Data) async throws -> HTTPResponse {
        var annotation = Annotation(try object(body))
        if annotation["worktree"] == nil, let url = annotation["url"]?.string,
            let port = Worktree.localPort(of: url), let worktree = worktreeForPort(port)
        {
            annotation["worktree"] = .string(worktree)
        }
        annotation = try await store.upsert(annotation)
        return .json(200, ["success": true, "annotation": .object(annotation.fields)])
    }

    private func sync(_ body: Data) async throws -> HTTPResponse {
        guard let items = try object(body)["annotations"]?.array else {
            throw BadRequest("annotations must be an array")
        }
        let annotations = try items.map { item -> Annotation in
            guard let fields = item.object, fields["id"]?.string?.isEmpty == false else {
                throw BadRequest("every annotation needs an id")
            }
            return Annotation(fields)
        }
        let result = try await store.replaceAll(annotations)
        var reply: [String: JSONValue] = ["success": true, "count": .number(Double(result.count))]
        if result.skipped { reply["skipped"] = true }
        return .json(200, .object(reply))
    }

    private func get(_ id: String) async -> HTTPResponse {
        guard let annotation = await store.get(id) else { return .error(404, "Annotation not found") }
        return .json(200, ["success": true, "annotation": .object(annotation.fields)])
    }

    private func update(_ id: String, _ body: Data) async throws -> HTTPResponse {
        guard let annotation = try await store.update(id, with: try object(body)) else {
            return .error(404, "Annotation not found")
        }
        return .json(200, ["success": true, "annotation": .object(annotation.fields)])
    }

    private func delete(_ id: String) async throws -> HTTPResponse {
        guard let removed = try await store.delete(id) else { return .error(404, "Annotation not found") }
        return .json(
            200,
            [
                "success": true, "deleted": true, "message": .string("Annotation \(id) deleted"),
                "deletedAnnotation": .object(removed.fields),
            ])
    }

    private func object(_ body: Data) throws -> [String: JSONValue] {
        guard let fields = (try? JSONDecoder().decode(JSONValue.self, from: body))?.object else {
            throw BadRequest("Body must be a JSON object")
        }
        return fields
    }

    private func hasLocalHost(_ request: HTTPRequest) -> Bool {
        guard let host = request.headers["host"] else { return false }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        return name == "127.0.0.1" || name == "localhost"
    }

    private func hasToken(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(String(header.dropFirst(7)), token)
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private struct BadRequest: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
