import AppKit
import CoreGraphics

/// Whether anyone is at the Mac: the sidebar's rounds rest while the screen sleeps or is
/// locked, and slow down while nothing has been touched for a minute (a key or the mouse
/// brings them back within a round).
@MainActor
enum Away {
    private(set) static var asleep = false
    private(set) static var locked = false
    private static var watching: [NSObjectProtocol] = []

    /// Screen asleep or the session locked (or switched to another user).
    static var now: Bool {
        start()
        return asleep || locked
    }

    /// No key, click or mouse move for a minute.
    static var idle: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 60
    }

    private static func start() {
        guard watching.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor () -> Void) {
            watching.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { change() }
            })
        }
        on(workspace, NSWorkspace.screensDidSleepNotification) { asleep = true }
        on(workspace, NSWorkspace.screensDidWakeNotification) { asleep = false }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { locked = true }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { locked = false }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { locked = true }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { locked = false }
    }
}
