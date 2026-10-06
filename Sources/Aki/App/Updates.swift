import AkiCore
import AppKit
import Sparkle

/// Where an update stands, as the pill by the sidebar shows it.
enum UpdateState: Equatable {
    case idle
    /// You asked ("Check for Updates…"): looking.
    case checking
    /// A newer version, waiting for a click.
    case available(String)
    /// Downloading it; the fraction once the size is known.
    case downloading(String, Double?)
    /// Unpacking and swapping it in; Aki restarts by itself right after.
    case installing(String)
    /// You asked and there's nothing newer (shown a few seconds).
    case upToDate
    /// It didn't work (shown a few seconds; the next check tries again).
    case failed
    /// Just restarted on this version (shown a few seconds).
    case updated(String)

    var version: String? {
        switch self {
        case .available(let v), .downloading(let v, _), .installing(let v), .updated(let v): v
        default: nil
        }
    }
}

/// In-app updates, all inside Aki, like Orca: every hour Aki reads the feed
/// (aki-updates.vercel.app/appcast.xml); a newer version shows as a pill by the
/// sidebar (and a dot on the menu bar pin). Nothing is downloaded until you click
/// it; then the pill becomes a progress bar, and Aki restarts by itself on the new
/// version (swapping an app always needs that) and says so for a moment.
/// Sparkle does the work — checking, the signed download, the install — and Aki
/// draws every step instead of Sparkle's windows. Every update is signed with
/// Aki's own key (public half in Info.plist), so nothing else can pose as one.
@MainActor
final class Updates: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    static let shared = Updates()

    private lazy var updater = SPUUpdater(
        hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)

    /// The sidebar's pill and the menu bar's dot follow it.
    var onChange: (UpdateState) -> Void = { _ in }
    private(set) var state: UpdateState = .idle {
        didSet {
            guard state != oldValue else { return }
            onChange(state)
            fade?.cancel()
            // Messages go away by themselves.
            let after: Double? = switch state {
            case .upToDate: 3
            case .failed: 6
            case .updated: 8
            default: nil
            }
            if let after {
                let shown = state
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { if self?.state == shown { self?.state = .idle } }
                }
                fade = work
                DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
            }
        }
    }
    private var fade: DispatchWorkItem?

    /// The version waiting for a click (the menu offers it too).
    var available: String? { if case .available(let v) = state { v } else { nil } }

    /// Sparkle's question for the update found, answered when you click the pill.
    private var answer: ((SPUUserUpdateChoice) -> Void)?
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    /// `AKI_FAKE_UPDATE=0.9.9`: the pill and a pretend download (design work, screenshots).
    private var fake: String? { ProcessInfo.processInfo.environment["AKI_FAKE_UPDATE"] }

    private let updatingFromKey = "updatingFrom"

    /// Starts the hourly check (call once at launch).
    func start() {
        // Restarted by an update: say so for a moment.
        let defaults = UserDefaults.standard
        if let from = defaults.string(forKey: updatingFromKey) {
            defaults.removeObject(forKey: updatingFromKey)
            if from != Aki.version { state = .updated(Aki.version) }
        }
        if let fake {
            state = .available(fake)
            return
        }
        updater.automaticallyDownloadsUpdates = false
        do { try updater.start() } catch { NSLog("Aki updates: \(error.localizedDescription)") }
    }

    /// "Check for Updates…" in the menus and Settings.
    @objc func checkForUpdates() {
        if case .available = state { install(); return }
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    /// A click on the pill: install what's waiting, or look again.
    func tap() {
        switch state {
        case .available: install()
        case .idle, .upToDate, .failed: checkForUpdates()
        case .checking, .downloading, .installing, .updated: break
        }
    }

    private func install() {
        guard case .available(let version) = state else { return }
        if fake != nil { pretend(version); return }
        state = .downloading(version, nil)
        let reply = answer
        answer = nil
        reply?(.install)
    }

    /// Kept for Settings: an update found is downloaded and installed with no click.
    func setInstallsByThemselves(_ on: Bool) {}

    // MARK: SPUUserDriver — every step, drawn by Aki

    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Aki checks by itself (Info.plist says so); never ask.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated { state = .checking }
    }

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
                                     reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        MainActor.assumeIsolated {
            if appcastItem.isInformationOnlyUpdate { reply(.dismiss); return }
            answer = reply
            state = .available(version)
            if Preferences.shared.installUpdatesByThemselves { install() }
        }
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        MainActor.assumeIsolated { state = state == .checking ? .upToDate : .idle }
    }

    nonisolated func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        MainActor.assumeIsolated {
            NSLog("Aki updates: \(error.localizedDescription)")
            // A check made by itself failing (offline) says nothing; one you asked for, or a download, does.
            switch state {
            case .checking, .downloading, .installing: state = .failed
            default: state = .idle
            }
        }
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            expected = 0
            received = 0
            if let version = state.version { state = .downloading(version, 0) }
        }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { expected = expectedContentLength }
    }

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            received += length
            guard let version = state.version, expected > 0 else { return }
            state = .downloading(version, min(Double(received) / Double(expected), 1))
        }
    }

    nonisolated func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated { if let version = state.version { state = .installing(version) } }
    }

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            if let version = state.version { state = .installing(version) }
            // Restart right away: the new version comes back on its own.
            UserDefaults.standard.set(Aki.version, forKey: updatingFromKey)
        }
        reply(.install)
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                          retryTerminatingApplication: @escaping () -> Void) {
        MainActor.assumeIsolated { if let version = state.version { state = .installing(version) } }
    }

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    nonisolated func showUpdateInFocus() {}

    nonisolated func dismissUpdateInstallation() {
        MainActor.assumeIsolated {
            answer = nil
            switch state {
            case .checking, .downloading, .installing, .available: state = .idle
            default: break
            }
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Beta versions (`<sparkle:channel>beta</sparkle:channel>` in the appcast) only
    /// for those who asked for them.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { Preferences.shared.betaUpdates ? ["beta"] : [] }
    }

    // MARK: Pretend (AKI_FAKE_UPDATE)

    private func pretend(_ version: String) {
        var fraction = 0.0
        state = .downloading(version, 0)
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                fraction += 0.025
                if fraction < 1 {
                    self.state = .downloading(version, fraction)
                } else {
                    timer.invalidate()
                    self.state = .installing(version)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.state = .updated(version) }
                }
            }
        }
    }
}
