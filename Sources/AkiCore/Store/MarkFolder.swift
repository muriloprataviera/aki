import Foundation

/// Every mark has a folder of its own, found by its day and its short code:
///
///     ~/.aki/marks/2026-10-07/df9f68ee/
///         mark.json   what was asked, where, for which session
///         crop.jpg    the piece of screen marked
///
/// Nothing depends on a tab's name (they change). `annotations.json` stays the index.
public enum MarkFolder {
    /// A mark's short code: "aki_1791339895884_df9f68ee" → "df9f68". The same in the
    /// message typed to the agent, in the History and in `aki show` / `aki done`.
    public static func code(_ id: String) -> String {
        let tail = id.split(separator: "_").last.map(String.init) ?? id
        let clean = tail.lowercased().filter { $0.isLetter || $0.isNumber }
        return String(clean.prefix(6))
    }

    /// The folder's own name: the id's whole random part ("df9f68ee"), so two marks
    /// never share one; it starts with the code, so the code finds it by eye.
    static func folderName(_ id: String) -> String {
        let tail = id.split(separator: "_").last.map(String.init) ?? id
        let clean = tail.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return clean.isEmpty ? "mark" : clean
    }

    /// `<home>/marks/<day>/<id's random part>/`.
    public static func url(for id: String, created: Date = Date(), home: AkiHome = .default) -> URL {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return home.url.appending(path: "marks").appending(path: day.string(from: created)).appending(path: folderName(id))
    }

    /// The folder, made private (only you read it).
    public static func make(for id: String, created: Date = Date(), home: AkiHome = .default) -> URL? {
        let folder = url(for: id, created: created, home: home)
        let ok = (try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        return ok ? folder : nil
    }

    /// What a person reads opening the folder: the request and where it was made.
    /// Facts fixed when sent (its status lives in the index).
    public static func writeRecord(of annotation: Annotation, in folder: URL) {
        var record: [String: JSONValue] = ["id": .string(annotation.id), "code": .string(code(annotation.id))]
        for key in ["created_at", "comment", "kind", "url", "selector", "app", "worktree", "agent"] {
            if let value = annotation[key], value != .null { record[key] = value }
        }
        // The session's name without the tab's status sign ("✳ SITE" → "SITE").
        if let name = annotation["session_name"]?.string {
            record["session_name"] = .string(String(name.drop { !$0.isLetter && !$0.isNumber }))
        }
        guard let data = try? JSON.encode(record, pretty: true) else { return }
        let file = folder.appending(path: "mark.json")
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The day a mark was made, from its `created_at` (now when it has none).
    public static func created(_ annotation: Annotation) -> Date {
        guard let text = annotation["created_at"]?.string else { return Date() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
    }

    /// Whether a path is one of Aki's own (under `marks/` or the old `images/`).
    public static func isAkis(_ path: String, home: AkiHome = .default) -> Bool {
        let file = URL(filePath: path).standardizedFileURL.path
        return ["marks", "images"].contains { file.hasPrefix(home.url.appending(path: $0).standardizedFileURL.path + "/") }
    }

    /// Takes a mark's folder away (picture and record), and its day when that's empty.
    public static func remove(_ annotation: Annotation, home: AkiHome = .default) {
        let folder = url(for: annotation.id, created: created(annotation), home: home)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.removeItem(at: folder)
        let day = folder.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: day)
        }
    }

    /// Finds marks by their short codes (with or without "#") or full ids. Unknown or
    /// ambiguous ones come back in `problems`, said plainly.
    public static func resolve(_ tokens: [String], in all: [Annotation]) -> (found: [Annotation], problems: [String]) {
        var found: [Annotation] = []
        var problems: [String] = []
        for raw in tokens {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#“”\"', ")).lowercased()
            guard !token.isEmpty else { continue }
            if let exact = all.first(where: { $0.id.lowercased() == token }) {
                found.append(exact)
                continue
            }
            let matches = all.filter { code($0.id) == token || (token.count >= 4 && code($0.id).hasPrefix(token)) }
            switch matches.count {
            case 1: found.append(matches[0])
            case 0: problems.append("no mark \(raw)")
            default: problems.append("\(raw) matches \(matches.count) marks: \(matches.map(\.id).joined(separator: ", "))")
            }
        }
        return (found, problems)
    }
}

/// A mark's short code as people read it: "#df9f68".
public func markCode(_ id: String) -> String {
    let code = MarkFolder.code(id)
    return code.isEmpty ? "" : "#" + code
}
