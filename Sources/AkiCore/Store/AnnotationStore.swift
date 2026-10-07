import Foundation

/// Annotations on disk at `<home>/annotations.json`. Being an actor, every read and
/// write is serialized, so concurrent requests can't lose each other's changes.
public actor AnnotationStore {
    public nonisolated let fileURL: URL
    public nonisolated let statsURL: URL
    private var cache: [Annotation]?
    /// The file's modification date when `cache` was read or written: another
    /// process (a second Aki, `aki serve`) writing it makes the cache stale.
    private var cacheStamp: Date?

    private var fileStamp: Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    private var statsCache: Stats?

    public init(directory: URL) {
        fileURL = directory.appending(path: "annotations.json")
        statsURL = directory.appending(path: "stats.json")
    }

    public struct Filter: Sendable {
        public var status: String?
        public var url: String?
        public var worktree: String?
        public var limit: Int?

        public init(status: String? = nil, url: String? = nil, worktree: String? = nil, limit: Int? = nil) {
            self.status = status
            self.url = url
            self.worktree = worktree
            self.limit = limit
        }
    }

    /// Matching annotations (no limit unless asked) and how many there are in total.
    public func list(_ filter: Filter = Filter()) -> (annotations: [Annotation], total: Int) {
        let all = load()
        var matching = all.filter { a in
            (filter.status == nil || filter.status == "all" || a.status == filter.status)
                && (filter.url == nil || a["url"]?.string == filter.url)
                && (filter.worktree == nil || a["worktree"]?.string == filter.worktree)
        }
        if let limit = filter.limit, limit >= 0 {
            matching = Array(matching.prefix(limit))
        }
        return (matching, all.count)
    }

    public func get(_ id: String) -> Annotation? {
        load().first { $0.id == id }
    }

    /// Inserts, or merges into the annotation with the same id.
    @discardableResult
    private func unlockedUpsert(_ incoming: Annotation) throws -> Annotation {
        var all = load()
        var annotation = incoming
        if annotation.id.isEmpty {
            annotation["id"] = .string(Annotation.newID())
        }
        let now = JSON.now()
        if let index = all.firstIndex(where: { $0.id == annotation.id }) {
            let before = all[index]
            all[index].fields.merge(annotation.fields) { _, new in new }
            all[index]["updated_at"] = .string(now)
            annotation = all[index]
            try save(all)
            countResolution(from: before, to: annotation)
        } else {
            if annotation["created_at"] == nil { annotation["created_at"] = .string(now) }
            if annotation["status"] == nil { annotation["status"] = "pending" }
            annotation["updated_at"] = .string(now)
            all.append(annotation)
            try save(all)
            let size = Self.sizeInBytes(annotation)
            annotation["size_bytes"] = .number(Double(size))
            all[all.count - 1] = annotation
            try save(all)
            record(annotation) { counts in
                counts.marks += 1
                counts.bytes += size
                if Self.hasImage(annotation) { counts.images += 1 }
            }
        }
        return annotation
    }

    /// Merges `patch` into an existing annotation. Nil when the id doesn't exist.
    private func unlockedUpdate(_ id: String, with patch: [String: JSONValue]) throws -> Annotation? {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        let before = all[index]
        all[index].fields.merge(patch) { _, new in new }
        all[index]["id"] = .string(id)
        all[index]["updated_at"] = .string(JSON.now())
        try save(all)
        countResolution(from: before, to: all[index])
        if all[index].status == "completed" { removeImage(of: all[index]) }
        return all[index]
    }

    private func unlockedDelete(_ id: String) throws -> Annotation? {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = all.remove(at: index)
        try save(all)
        removeImage(of: removed)
        return removed
    }

    /// Once an annotation is done or deleted its picture goes too, and its folder
    /// (only what Aki saved itself, under `<home>/marks/` or the old `images/`).
    private func removeImage(of annotation: Annotation) {
        let home = AkiHome(url: fileURL.deletingLastPathComponent())
        MarkFolder.remove(annotation, home: home)
        guard let path = annotation["image_path"]?.string, MarkFolder.isAkis(path, home: home) else { return }
        try? FileManager.default.removeItem(at: URL(filePath: path))
    }

    /// Once: pictures from the old layout (images/<project>/<session>/<id>.jpg, named
    /// after tabs that change) move to each mark's own folder, marks/<day>/<code>/.
    /// Returns how many moved.
    @discardableResult
    public func moveToMarkFolders() throws -> Int {
        try locked {
            let home = AkiHome(url: fileURL.deletingLastPathComponent())
            let old = home.url.appending(path: "images").standardizedFileURL.path + "/"
            var all = load()
            var moved = 0
            for i in all.indices {
                let annotation = all[i]
                guard let path = annotation["image_path"]?.string,
                      URL(filePath: path).standardizedFileURL.path.hasPrefix(old),
                      FileManager.default.fileExists(atPath: path),
                      let folder = MarkFolder.make(for: annotation.id, created: MarkFolder.created(annotation), home: home)
                else { continue }
                let ext = URL(filePath: path).pathExtension.isEmpty ? "jpg" : URL(filePath: path).pathExtension
                let target = folder.appending(path: "crop.\(ext)")
                try? FileManager.default.removeItem(at: target)
                guard (try? FileManager.default.moveItem(at: URL(filePath: path), to: target)) != nil else { continue }
                var fields = annotation.fields
                fields["image_path"] = .string(target.path)
                all[i] = Annotation(fields)
                MarkFolder.writeRecord(of: all[i], in: folder)
                moved += 1
            }
            if moved > 0 { try save(all) }
            // Folders left empty in the old place go.
            let imagesURL = home.url.appending(path: "images")
            if let walker = FileManager.default.enumerator(at: imagesURL, includingPropertiesForKeys: [.isDirectoryKey]) {
                let folders = walker.compactMap { $0 as? URL }
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.path.count > $1.path.count }
                for folder in folders + [imagesURL] where (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            return moved
        }
    }

    /// Forgets marks that were done more than `days` days ago (pictures too).
    /// Pending ones always stay. Returns how many went.
    @discardableResult
    private func unlockedForgetDone(olderThan days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var all = load()
        let old = all.filter { a in
            guard a.status == "completed", let text = a["updated_at"]?.string ?? a["created_at"]?.string,
                let date = iso.date(from: text) ?? plain.date(from: text)
            else { return false }
            return date < limit
        }
        guard !old.isEmpty else { return 0 }
        let ids = Set(old.map(\.id))
        all.removeAll { ids.contains($0.id) }
        try save(all)
        old.forEach(removeImage)
        return old.count
    }

    /// Replaces everything (the extension's sync). `skipped` when nothing changed.
    private func unlockedReplaceAll(_ annotations: [Annotation]) throws -> (count: Int, skipped: Bool) {
        let incoming = annotations.sorted { $0.id < $1.id }
        if incoming == load().sorted(by: { $0.id < $1.id }) {
            return (incoming.count, true)
        }
        try save(incoming)
        return (incoming.count, false)
    }

    // MARK: Stats

    /// Counts per day (`yyyy-MM-dd`, local time) and worktree. Kept apart from the
    /// annotations so deleting marks doesn't erase the history. Numbers only.
    public struct Counts: Codable, Equatable, Sendable {
        public var marks = 0
        public var images = 0
        public var resolved = 0
        /// What was sent, in bytes (picture + data); older stats have none.
        public var bytes = 0

        public init(marks: Int = 0, images: Int = 0, resolved: Int = 0, bytes: Int = 0) {
            self.marks = marks
            self.images = images
            self.resolved = resolved
            self.bytes = bytes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            marks = try c.decodeIfPresent(Int.self, forKey: .marks) ?? 0
            images = try c.decodeIfPresent(Int.self, forKey: .images) ?? 0
            resolved = try c.decodeIfPresent(Int.self, forKey: .resolved) ?? 0
            bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        }

        public static func + (a: Counts, b: Counts) -> Counts {
            Counts(marks: a.marks + b.marks, images: a.images + b.images, resolved: a.resolved + b.resolved,
                   bytes: a.bytes + b.bytes)
        }
    }

    public typealias Stats = [String: [String: Counts]]

    public func stats() -> Stats {
        if let statsCache { return statsCache }
        let loaded = (try? Data(contentsOf: statsURL)).flatMap { try? JSONDecoder().decode(Stats.self, from: $0) } ?? [:]
        statsCache = loaded
        return loaded
    }

    public static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// What a mark weighs: its data as stored, plus its picture's file (or inline image).
    public static func sizeInBytes(_ a: Annotation) -> Int {
        var size = (try? JSONEncoder().encode(a.fields))?.count ?? 0
        if let path = a["image_path"]?.string,
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        {
            size += fileSize.intValue
        }
        return size
    }

    private static func hasImage(_ a: Annotation) -> Bool {
        a["image_path"]?.string != nil || a["screenshot"]?.object?["data_url"]?.string != nil
    }

    private func countResolution(from before: Annotation, to after: Annotation) {
        guard before.status != "completed", after.status == "completed" else { return }
        record(after) { $0.resolved += 1 }
    }

    private func record(_ annotation: Annotation, _ change: (inout Counts) -> Void) {
        var all = stats()
        let day = Self.dayKey()
        let worktree = annotation["worktree"]?.string ?? ""
        var counts = all[day]?[worktree] ?? Counts()
        change(&counts)
        all[day, default: [:]][worktree] = counts
        statsCache = all
        // Best effort: a failed write loses a count, never an annotation.
        if let data = try? JSON.encode(all, pretty: true) {
            try? data.write(to: statsURL, options: .atomic)
        }
    }

    public func upsert(_ incoming: Annotation) throws -> Annotation {
        try locked { try unlockedUpsert(incoming) }
    }

    public func update(_ id: String, with patch: [String: JSONValue]) throws -> Annotation? {
        try locked { try unlockedUpdate(id, with: patch) }
    }

    public func delete(_ id: String) throws -> Annotation? {
        try locked { try unlockedDelete(id) }
    }

    public func forgetDone(olderThan days: Int) throws -> Int {
        try locked { try unlockedForgetDone(olderThan: days) }
    }

    public func replaceAll(_ annotations: [Annotation]) throws -> (count: Int, skipped: Bool) {
        try locked { try unlockedReplaceAll(annotations) }
    }

    /// Changes run under a lock on the file shared by every process (the app,
    /// `aki serve`): read, change and write as one step, so no two overwrite each other.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // No lock, no write: better a failed save (the mark stays queued) than two
        // processes overwriting each other.
        let fd = open(fileURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var got = flock(fd, LOCK_EX)
        while got != 0 && errno == EINTR { got = flock(fd, LOCK_EX) }
        guard got == 0 else { close(fd); throw CocoaError(.fileLocking) }
        defer { flock(fd, LOCK_UN); close(fd) }
        cache = nil  // under the lock, always the file as it is now
        return try body()
    }

    private func load() -> [Annotation] {
        if let cache, cacheStamp == fileStamp { return cache }
        var result: [Annotation] = []
        if let data = try? Data(contentsOf: fileURL),
            !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) })
        {
            do {
                result = try JSONDecoder().decode([Annotation].self, from: data)
            } catch {
                // Keep the broken file for inspection and start empty instead of failing every request.
                let ms = Int(Date().timeIntervalSince1970 * 1000)
                let backup = fileURL.appendingPathExtension("corrupted.\(ms)")
                try? FileManager.default.moveItem(at: fileURL, to: backup)
            }
        }
        cache = result
        cacheStamp = fileStamp
        return result
    }

    private func save(_ annotations: [Annotation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSON.encode(annotations, pretty: true).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cache = annotations
        cacheStamp = fileStamp
    }
}
