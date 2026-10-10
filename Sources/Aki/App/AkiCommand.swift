import AppKit

/// The short `aki` command in Terminal: a link in /usr/local/bin (on every Mac's path)
/// to the app's own binary. The installer makes it; Get started offers it to those who
/// came by the DMG. With it, what Aki types to agents says `aki list` instead of the
/// full path inside the app: shorter, and harder for an agent to get wrong.
enum AkiCommand {
    static let link = "/usr/local/bin/aki"

    /// The binary in /Applications (stays put across updates), else this running copy.
    /// …only when it's this same version (an older one there wouldn't know the newer
    /// commands the messages name).
    static var target: String {
        let installed = "/Applications/Aki.app/Contents/MacOS/Aki"
        let running = Bundle.main.executablePath ?? installed
        guard FileManager.default.isExecutableFile(atPath: installed) else { return running }
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let theirs = Bundle(path: "/Applications/Aki.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return mine == nil || mine == theirs ? installed : running
    }

    /// The link is there and leads to Aki.
    static var installed: Bool {
        guard let real = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return false }
        return URL(filePath: real).standardizedFileURL.path == URL(filePath: target).standardizedFileURL.path
    }

    /// How a message to an agent names Aki's command.
    static var invocation: String { installed ? "aki" : "'\(target)'" }

    /// Makes the link; macOS asks for the password (it's a system folder). True when it's there.
    @MainActor @discardableResult
    static func install() -> Bool {
        let path = target.replacingOccurrences(of: "'", with: "")
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(path)' \(link)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return installed
    }
}
