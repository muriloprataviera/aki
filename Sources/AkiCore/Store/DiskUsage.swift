import Foundation

/// How much room Aki's pictures take, next to the disk they're on, and which of
/// them nothing needs any more (their marks are done or gone).
public struct DiskUsage: Sendable, Equatable {
    public var imageBytes: Int64 = 0
    public var imageCount = 0
    /// Pictures no pending mark points to.
    public var unusedBytes: Int64 = 0
    public var unusedCount = 0
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0

    public init() {}

    /// Share of the disk the pictures take (0…1).
    public var shareOfDisk: Double { diskTotal > 0 ? Double(imageBytes) / Double(diskTotal) : 0 }

    public static func measure(pending: [Annotation], home: AkiHome = .default) -> DiskUsage {
        var usage = DiskUsage()
        let used = Set(pending.compactMap { $0["image_path"]?.string }.map { URL(filePath: $0).standardizedFileURL.path })
        for file in files(home: home) {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            usage.imageBytes += size
            usage.imageCount += 1
            if !used.contains(file.standardizedFileURL.path) {
                usage.unusedBytes += size
                usage.unusedCount += 1
            }
        }
        if let values = try? home.url.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        {
            usage.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            usage.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        return usage
    }

    /// Deletes the pictures no pending mark needs. Returns the bytes freed.
    @discardableResult
    public static func clean(pending: [Annotation], home: AkiHome = .default) -> Int64 {
        let used = Set(pending.compactMap { $0["image_path"]?.string }.map { URL(filePath: $0).standardizedFileURL.path })
        var freed: Int64 = 0
        for file in files(home: home) where !used.contains(file.standardizedFileURL.path) {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? FileManager.default.removeItem(at: file)) != nil { freed += size }
        }
        return freed
    }

    /// Every picture, in every project / session folder.
    private static func files(home: AkiHome) -> [URL] {
        let folder = home.url.appending(path: "images")
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// Keeps the pictures under `maxBytes`: the ones no waiting mark needs go
    /// first, oldest first. Returns the bytes freed.
    @discardableResult
    public static func trim(toMax maxBytes: Int64, pending: [Annotation], home: AkiHome = .default) -> Int64 {
        let used = Set(pending.compactMap { $0["image_path"]?.string }.map { URL(filePath: $0).standardizedFileURL.path })
        let all = files(home: home).map { file -> (URL, Int64, Date, Bool) in
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (file, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast,
                    used.contains(file.standardizedFileURL.path))
        }
        var total = all.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maxBytes else { return 0 }
        var freed: Int64 = 0
        // Unneeded first, then the oldest of the rest.
        for (file, size, _, _) in all.sorted(by: { ($0.3 ? 1 : 0, $0.2) < ($1.3 ? 1 : 0, $1.2) }) where total > maxBytes {
            if (try? FileManager.default.removeItem(at: file)) != nil {
                total -= size
                freed += size
            }
        }
        return freed
    }
}
