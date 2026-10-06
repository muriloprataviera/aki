import Foundation

public enum Aki {
    public static let version = "0.3.3-beta.5"
    /// Next to Vibe Annotations' 3846, so both can run side by side.
    public static let defaultPort: UInt16 = 3850
}

/// Aki's data folder: `~/.aki`, or `$AKI_HOME` when set.
public struct AkiHome: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var `default`: AkiHome {
        if let custom = ProcessInfo.processInfo.environment["AKI_HOME"], !custom.isEmpty {
            return AkiHome(url: URL(filePath: custom))
        }
        return AkiHome(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aki"))
    }

    public var tokenURL: URL { url.appending(path: "token") }

    /// Secret the CLI and MCP send as `Authorization: Bearer <token>`. Created on first
    /// use, readable only by the user, so other users and web pages can't call the API.
    public func token() throws -> String {
        // Aki's folder is the user's alone, whatever made it first.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        if let saved = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 32
        {
            return saved
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var generator = SystemRandomNumberGenerator()
        let token = (0..<4).map { _ in String(format: "%016llx", generator.next()) }.joined()
        // Born readable by the user only (never a moment open to others).
        let temp = url.appending(path: ".token.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: tokenURL.path) {
            _ = try FileManager.default.replaceItemAt(tokenURL, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: tokenURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }
}
