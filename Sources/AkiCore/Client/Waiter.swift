import Foundation

/// Waits for new pending annotations in a worktree and returns them once the user
/// has stopped marking for `idle` seconds, so a batch of marks arrives together.
public enum Waiter {
    public static func waitForNew(
        client: AkiClient, worktree: String, sessionId: String? = nil, idle: Duration = .seconds(5),
        timeout: Duration? = nil, poll: Duration = .seconds(2)
    ) async throws -> [Annotation] {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now + $0 }
        var seen: Set<String>?
        var fresh: [String: Annotation] = [:]
        var lastChange = clock.now

        while true {
            if let annotations = try? await client.list(status: "pending") {
                let filter = WorktreeFilter(worktree: worktree, sessionId: sessionId)
                let mine = annotations.filter(filter.matches)
                if seen == nil {
                    // Whatever is already pending when we start isn't "new".
                    seen = Set(mine.map(\.id))
                } else {
                    for annotation in mine where !seen!.contains(annotation.id) && fresh[annotation.id] != annotation {
                        fresh[annotation.id] = annotation
                        lastChange = clock.now
                    }
                    // Marks resolved or deleted meanwhile don't count.
                    let pendingIDs = Set(mine.map(\.id))
                    fresh = fresh.filter { pendingIDs.contains($0.key) }
                }
            }
            if !fresh.isEmpty && clock.now - lastChange >= idle {
                return Array(fresh.values)
            }
            if let deadline, clock.now >= deadline { return Array(fresh.values) }
            try await Task.sleep(for: poll)
        }
    }
}
