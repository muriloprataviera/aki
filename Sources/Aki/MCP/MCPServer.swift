import AkiCore
import Foundation

/// MCP over stdio (newline-delimited JSON-RPC). The agent starts `aki mcp` inside its
/// own folder, so the server knows which worktree the agent is working in.
struct MCPServer {
    let client: AkiClient
    let worktree: String
    /// The agent session that started this server, so marks aimed at it arrive here.
    let sessionId: String?

    static let instructions = """
        Aki lets the user point at things on screen (any app, a browser page, a terminal) \
        and leave a comment on each mark. Annotations for this project are filtered by the \
        agent's worktree. Treat each pending annotation as a request: read_annotations, use \
        get_annotation_image only when the request is visual, then resolve_annotation when done. \
        Use wait_for_annotations to block until the user sends new marks.
        """

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                let message = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
            else { continue }
            guard let id = message["id"] else { continue }  // notifications need no reply
            let method = message["method"]?.string ?? ""
            let params = message["params"]?.object ?? [:]
            do {
                write(["jsonrpc": "2.0", "id": id, "result": try await handle(method, params)])
            } catch let error as RPCError {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
            } catch {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string("\(error)")]])
            }
        }
    }

    private func handle(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "initialize":
            return [
                "protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "aki", "version": .string(Aki.version)],
                "instructions": .string(Self.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(Self.tools)]
        case "tools/call":
            let name = params["name"]?.string ?? ""
            let arguments = params["arguments"]?.object ?? [:]
            do {
                return try await call(name, arguments)
            } catch let error as RPCError {
                throw error
            } catch {
                return ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let worktree = arguments["worktree"]?.string ?? self.worktree
        switch name {
        case "read_annotations":
            let status = arguments["status"]?.string ?? "pending"
            let all = try await client.list(status: status)
            if arguments["scope"]?.string == "all" {
                return text(all.isEmpty ? "No \(status) annotations." : AnnotationText.render(all))
            }
            let filter = WorktreeFilter(worktree: worktree, sessionId: sessionId)
            let mine = all.filter(filter.matches)
            await client.markRead(mine)
            var output = "\(mine.count) \(status) annotation(s) for \(worktree)"
            if !mine.isEmpty { output += "\n\n" + AnnotationText.render(mine) }
            let others = all.count - mine.count
            if others > 0 {
                output += "\n\n\(others) other annotation(s) belong to other worktrees or sites. "
                    + "Only take them if the user says so (scope: \"all\" lists them)."
            }
            return text(output)

        case "wait_for_annotations":
            let idle = arguments["idle_seconds"].flatMap(number) ?? Double(UserDefaults(suiteName: "ai.useaki.Aki")?.integer(forKey: "waitIdleSeconds") ?? 0).nonZero ?? 5
            let timeout = arguments["timeout_seconds"].flatMap(number) ?? 600
            let fresh = try await Waiter.waitForNew(
                client: client, worktree: worktree, sessionId: sessionId, idle: .seconds(idle), timeout: .seconds(timeout))
            await client.markRead(fresh)
            return text(
                fresh.isEmpty
                    ? "No new annotations in \(Int(timeout))s. Call again to keep waiting."
                    : "\(fresh.count) new annotation(s):\n\n" + AnnotationText.render(fresh))

        case "get_annotation_image":
            let id = try required("id", arguments)
            guard let annotation = try await client.get(id) else { return text("Annotation \(id) not found.", error: true) }
            guard let file = AnnotationImage.file(for: annotation), let data = try? Data(contentsOf: file) else {
                return text("Annotation \(id) has no image.")
            }
            return ["content": [
                ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(AnnotationImage.mimeType(of: file))],
                ["type": "text", "text": .string("Saved at \(file.path)")],
            ]]

        case "resolve_annotation":
            let id = try required("id", arguments)
            var patch: [String: JSONValue] = ["status": "completed", "resolved_at": .string(isoNow())]
            if let note = arguments["note"]?.string { patch["resolution"] = .string(note) }
            try await client.update(id, patch)
            return text("Resolved \(id).")

        case "delete_annotation":
            let id = try required("id", arguments)
            try await client.delete(id)
            return text("Deleted \(id).")

        default:
            throw RPCError(code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private func required(_ key: String, _ arguments: [String: JSONValue]) throws -> String {
        guard let value = arguments[key]?.string, !value.isEmpty else {
            throw RPCError(code: -32602, message: "Missing argument: \(key)")
        }
        return value
    }

    private func number(_ value: JSONValue) -> Double? {
        if case .number(let n) = value { return n }
        return value.string.flatMap(Double.init)
    }

    private func text(_ string: String, error: Bool = false) -> JSONValue {
        var result: [String: JSONValue] = ["content": [["type": "text", "text": .string(string)]]]
        if error { result["isError"] = true }
        return .object(result)
    }

    private func isoNow() -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
    }

    private func write(_ message: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static let worktreeArgument: JSONValue = [
        "type": "string",
        "description": "Worktree folder. Defaults to the folder the agent runs in.",
    ]

    static let tools: [JSONValue] = [
        [
            "name": "read_annotations",
            "description": "List the marks the user left on screen for this worktree (comment, page or app, element, image path).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "enum": ["pending", "completed", "archived", "all"], "default": "pending"],
                    "scope": ["type": "string", "enum": ["worktree", "all"], "default": "worktree",
                              "description": "\"all\" also lists marks from other worktrees and websites (references)."],
                    "worktree": worktreeArgument,
                ],
            ],
        ],
        [
            "name": "wait_for_annotations",
            "description": "Block until the user marks something new for this worktree and pauses for idle_seconds, then return the new marks.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "idle_seconds": ["type": "number", "default": 5],
                    "timeout_seconds": ["type": "number", "default": 600],
                    "worktree": worktreeArgument,
                ],
            ],
        ],
        [
            "name": "get_annotation_image",
            "description": "The screenshot of a mark. Use only when the request is visual (layout, color, spacing).",
            "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
        ],
        [
            "name": "resolve_annotation",
            "description": "Mark an annotation as done after handling it.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"], "note": ["type": "string", "description": "What was done (optional)."]],
                "required": ["id"],
            ],
        ],
        [
            "name": "delete_annotation",
            "description": "Delete an annotation that shouldn't be kept.",
            "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
        ],
    ]
}

struct RPCError: Error {
    let code: Int
    let message: String
}
