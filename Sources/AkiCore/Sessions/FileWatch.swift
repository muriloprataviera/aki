import CoreServices
import Foundation

/// The files that changed under some folders, as macOS tells them (FSEvents): nothing runs
/// while nothing is written, and a pass reads only what changed instead of walking
/// thousands of files. When macOS can't tell exactly (events dropped, a folder replaced),
/// `take()` asks for a full look instead.
public final class FileWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = Set<String>()
    /// A full look is due: at the start, and whenever the events can't be trusted.
    private var rescan = true
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ai.useaki.filewatch", qos: .utility)

    /// The folders watched (the ones that existed when it started).
    public let folders: [String]

    public init?(folders: [URL], latency: TimeInterval = 2) {
        self.folders = folders.map(\.path)
        let paths = folders.map(\.path) as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watch = Unmanaged<FileWatch>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            let distrust = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            watch.lock.withLock {
                for i in 0..<min(count, paths.count) {
                    if flags[i] & distrust != 0 { watch.rescan = true }
                    // A folder moved in or out tells nothing of the files inside: look at all.
                    let movedFolder = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
                    if flags[i] & movedFolder == movedFolder { watch.rescan = true }
                    watch.changed.insert(paths[i])
                }
            }
        }
        // File-level events; paths as CFStrings; no history before now (the first look is full).
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, options)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// What changed since the last call, or nil when a full look is due.
    public func take() -> Set<String>? {
        lock.withLock {
            defer { changed.removeAll(); rescan = false }
            return rescan ? nil : changed
        }
    }

    /// The next `take()` asks for a full look (a pass that couldn't finish its reading).
    public func distrust() {
        lock.withLock { rescan = true }
    }
}
