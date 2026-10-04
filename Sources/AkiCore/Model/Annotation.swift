import Foundation

/// One mark on the screen: a point, an area or a browser element, with its comment.
///
/// Field names follow Vibe Annotations (commit 8864e12c) so its extension can talk
/// to Aki unchanged: `id`, `url`, `comment`, `selector`, `element_context`,
/// `screenshot`, `status` (pending | completed | archived), `created_at`, `updated_at`.
/// Aki adds `worktree` (the folder of the agent session it belongs to), `app`
/// (where it was marked), `batch_id` (marks sent with the same Enter), `kind` and
/// `image_path`. Unknown fields are kept as they arrive.
public struct Annotation: Codable, Equatable, Sendable {
    public var fields: [String: JSONValue]

    public init(_ fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        fields = try [String: JSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }

    public subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    public var id: String { fields["id"]?.string ?? "" }
    public var status: String { fields["status"]?.string ?? "pending" }

    /// New marks keep their agent even after its process closes. Older marks
    /// identify non-Claude agents by their original `<agent>:<pid>` session id.
    public var destinationAgent: AgentSession.Agent? {
        if let name = fields["agent"]?.string, let agent = AgentSession.Agent(rawValue: name) { return agent }
        guard let id = fields["session_id"]?.string else { return nil }
        if let separator = id.firstIndex(of: ":") {
            return AgentSession.Agent(rawValue: String(id[..<separator]))
        }
        // Before destination metadata, UUID session ids came from Claude's registry.
        return UUID(uuidString: id) != nil ? .claude : nil
    }

    static func newID() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<9).map { _ in chars.randomElement()! })
        return "aki_\(ms)_\(suffix)"
    }
}
