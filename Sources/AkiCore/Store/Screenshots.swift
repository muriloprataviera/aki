import Foundation

/// The Mac's own screenshots piling up (the Desktop, Downloads, the folder chosen
/// in the Screenshot app): how many, how much room, and the old ones to the Trash.
/// Never deletes for good, and only looks when asked.
public struct Screenshots: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var url: URL
        public var bytes: Int64
        public var date: Date
    }

    public var files: [File] = []

    public init(files: [File] = []) { self.files = files }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// Taken more than `days` ago.
    public func older(than days: Int, now: Date = Date()) -> [File] {
        let cut = now.addingTimeInterval(-Double(days) * 24 * 3600)
        return files.filter { $0.date < cut }
    }
    /// The folder holding the most, to show in Finder.
    public var mainFolder: URL? {
        Dictionary(grouping: files, by: { $0.url.deletingLastPathComponent() })
            .max { $0.value.count < $1.value.count }?.key
    }

    /// Where macOS puts screenshots: the folder chosen in the Screenshot app, the
    /// Desktop (its default) and Downloads.
    public static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders = [home.appending(path: "Desktop"), home.appending(path: "Downloads")]
        if let chosen = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !chosen.isEmpty {
            let url = URL(filePath: (chosen as NSString).expandingTildeInPath)
            if !folders.contains(url) { folders.insert(url, at: 0) }
        }
        return folders
    }

    /// Every screenshot in `folders` and the folders inside them (two levels down).
    public static func scan(_ folders: [URL] = folders) -> Screenshots {
        var found: [File] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        for folder in folders {
            guard let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walk {
                if walk.level > 2 { walk.skipDescendants(); continue }
                guard isScreenshot(url), seen.insert(url.standardizedFileURL.path).inserted,
                    let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                found.append(File(url: url, bytes: Int64(values.fileSize ?? 0),
                                  date: values.creationDate ?? values.contentModificationDate ?? Date()))
            }
        }
        return Screenshots(files: found.sorted { $0.date < $1.date })
    }

    /// Marked as one by macOS, or named the way it names them, in any language.
    public static func isScreenshot(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "heic", "tiff", "pdf", "mov"].contains(url.pathExtension.lowercased()) else { return false }
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        // The name, then the date: "Screenshot 2026-10-10 at 15.30.00" (not "screenshot of the logo").
        let name = url.lastPathComponent.lowercased()
        return namePrefixes.contains { prefix in
            guard name.hasPrefix(prefix) else { return false }
            return name.dropFirst(prefix.count).drop { $0 == " " }.prefix(10).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
        }
    }

    /// How macOS starts a screenshot's (or screen recording's) name in each language.
    static let namePrefixes = [
        "screenshot", "screen shot", "screen recording",
        "captura de tela", "gravação de tela", "captura de pantalla", "grabación de pantalla",
        "capture d’écran", "capture d'écran", "enregistrement de l’écran",
        "bildschirmfoto", "bildschirmaufnahme", "istantanea schermo", "registrazione schermo",
        "スクリーンショット", "画面収録", "截屏", "屏幕录制", "스크린샷", "화면 기록",
    ]

    /// Moves them to the Trash (they can come back from there). Returns the bytes moved.
    @discardableResult
    public static func trash(_ files: [File]) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for file in files where (try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)) != nil {
            count += 1
            bytes += file.bytes
        }
        return (count, bytes)
    }
}
