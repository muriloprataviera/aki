import Foundation

/// Another program run to its end, within a time limit: one stuck (`git` in a folder
/// iCloud is still downloading, `lsof` on a stalled disk, an Orca updating, a slow
/// `.zshrc`) is stopped and counts as failed, so it never holds up the sidebar or a send.
public enum Command {
    /// Its output when it ends well in time (exit 0), else nil. `anyEnd`: whatever it
    /// printed however it ended (`lsof` ends in error when one of the processes asked
    /// about is gone, and still lists the others').
    public static func output(_ path: String, _ arguments: [String], timeout: TimeInterval = 5, anyEnd: Bool = false) -> Data? {
        let result = run(path, arguments, timeout: timeout, capture: true)
        return result?.status == 0 || anyEnd ? result?.output : nil
    }

    /// Whether it ended well in time (exit 0); its output isn't kept.
    public static func succeeds(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Bool {
        run(path, arguments, timeout: timeout, capture: false)?.status == 0
    }

    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval, capture: Bool)
        -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let output = Buffer(), ended = DispatchSemaphore(value: 0)
        let pipe = Pipe()
        if capture {
            process.standardOutput = pipe
            // Read as it comes (a long answer would fill the pipe and hold the program).
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; ended.signal() } else { output.append(chunk) }
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Asked to stop, then made to (a shell waiting on its .zshrc may not listen).
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // The rest of its answer (a second at most: something it started may hold the pipe).
        if capture, ended.wait(timeout: .now() + 1) == .timedOut { pipe.fileHandleForReading.readabilityHandler = nil }
        return (process.terminationStatus, output.data)
    }

    private final class Buffer: @unchecked Sendable {
        private var collected = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) { lock.withLock { collected.append(chunk) } }
        var data: Data { lock.withLock { collected } }
    }
}
