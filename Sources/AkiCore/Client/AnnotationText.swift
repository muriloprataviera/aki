import Foundation

/// Plain-text rendering of annotations for agents (CLI output and MCP results).
public enum AnnotationText {
    public static func render(_ annotations: [Annotation], home: AkiHome = .default) -> String {
        annotations
            .sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }
            .map { render($0, home: home) }
            .joined(separator: "\n\n")
    }

    public static func render(_ a: Annotation, home: AkiHome = .default) -> String {
        var lines = ["## \(markCode(a.id)) · \(a.id)  (\(shortDate(a["created_at"]?.string)))"]
        if let url = a["url"]?.string, !url.isEmpty { lines.append("page:     \(url)") }
        if let app = a["app"]?.object {
            let name = app["name"]?.string ?? app["bundle_id"]?.string ?? "?"
            let window = app["window"]?.string.map { " — \($0)" } ?? ""
            lines.append("app:      \(name)\(window)")
        }
        let comment = a["comment"]?.string ?? ""
        lines.append("comment:  \(comment.isEmpty ? "(no text)" : comment)")
        if let kind = a["kind"]?.string { lines.append("kind:     \(kind)") }
        let context = a["element_context"]?.object ?? [:]
        if let tag = context["tag"]?.string {
            let path = context["path"]?.string ?? a["selector"]?.string ?? ""
            lines.append("element:  <\(tag)> \(path)")
        } else if let selector = a["selector"]?.string, !selector.isEmpty {
            lines.append("element:  \(selector)")
        }
        if let text = context["text"]?.string, !text.isEmpty { lines.append("text:     \(text.prefix(200))") }
        if let selected = a["selected_text"]?.string, !selected.isEmpty {
            lines.append("on screen:")
            lines.append(contentsOf: selected.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).map { "  │ \($0)" })
        }
        if let file = a["source_file_path"]?.string, !file.isEmpty { lines.append("file:     \(file)") }
        for (property, change) in (a["pending_changes"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let value = change.object?["value"], value != .null else { continue }
            lines.append("change:   \(property): \(describe(change.object?["original"])) → \(describe(value))")
        }
        if let image = AnnotationImage.file(for: a, home: home) { lines.append("image:    \(image.path)") }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: "—"
        }
    }

    private static func shortDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

/// The picture attached to an annotation: Aki's own `image_path`, or the extension's
/// inline `screenshot.data_url`, saved once to `<home>/images/` so agents get a file.
public enum AnnotationImage {
    public static func file(for a: Annotation, home: AkiHome = .default) -> URL? {
        if let path = a["image_path"]?.string, FileManager.default.fileExists(atPath: path) {
            return URL(filePath: path)
        }
        guard let dataURL = a["screenshot"]?.object?["data_url"]?.string,
            let comma = dataURL.firstIndex(of: ","),
            let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        let header = dataURL[..<comma]
        let ext = header.contains("png") ? "png" : header.contains("jpeg") ? "jpg" : "webp"
        // In the mark's own folder, like Aki's own marks.
        guard let folder = MarkFolder.make(for: a.id, created: MarkFolder.created(a), home: home) else { return nil }
        let file = folder.appending(path: "crop.\(ext)")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        }
        return file
    }

    public static func mimeType(of file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "image/webp"
        }
    }
}
