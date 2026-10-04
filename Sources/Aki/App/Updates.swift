import AppKit
import Sparkle

/// In-app updates with Sparkle: once a day Aki reads the appcast on the site
/// (useaki.vercel.app/appcast.xml), and when there's a newer version it shows
/// Sparkle's window — what's new, download, install and reopen. Every update is
/// signed with Aki's own key (the public half is in Info.plist), so nothing else
/// can pose as one. Beta versions reach only those who turn them on.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    var updater: SPUUpdater { controller.updater }

    /// Starts the daily check (call once at launch).
    func start() {
        _ = controller
        updater.automaticallyDownloadsUpdates = Preferences.shared.installUpdatesByThemselves
    }

    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setInstallsByThemselves(_ on: Bool) {
        updater.automaticallyDownloadsUpdates = on
    }

    // MARK: SPUUpdaterDelegate

    /// Beta versions (`<sparkle:channel>beta</sparkle:channel>` in the appcast) only
    /// for those who asked for them.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { Preferences.shared.betaUpdates ? ["beta"] : [] }
    }
}
