import AppKit
import Sparkle

/// In-app updates with Sparkle: once a day Aki reads the feed
/// (aki-updates.vercel.app/appcast.xml). A newer version is only *announced* —
/// a pill by the sidebar and a dot on the menu bar pin, like Orca — nothing is
/// downloaded until you click it; then Sparkle's window shows what's new and
/// installs. Every update is signed with Aki's own key (public half in
/// Info.plist), so nothing else can pose as one. Betas only for those who ask.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)

    /// The version waiting to be installed (nil when up to date): the sidebar's
    /// pill and the menu bar's dot follow it.
    var onAvailable: (String?) -> Void = { _ in }
    private(set) var available: String? { didSet { onAvailable(available) } }

    var updater: SPUUpdater { controller.updater }

    /// Starts the daily check (call once at launch).
    func start() {
        _ = controller
        updater.automaticallyDownloadsUpdates = Preferences.shared.installUpdatesByThemselves
    }

    /// Also what the pill does: Sparkle's window with what's new and Install.
    @objc func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setInstallsByThemselves(_ on: Bool) {
        updater.automaticallyDownloadsUpdates = on
    }

    // MARK: Gentle reminders (Aki shows them, not Sparkle's window)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A check Aki made by itself: never pop a window over your work; announce it.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { if !handleShowingUpdate { available = version } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { available = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { available = nil }
    }

    // MARK: SPUUpdaterDelegate

    /// Beta versions (`<sparkle:channel>beta</sparkle:channel>` in the appcast) only
    /// for those who asked for them.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { Preferences.shared.betaUpdates ? ["beta"] : [] }
    }
}
