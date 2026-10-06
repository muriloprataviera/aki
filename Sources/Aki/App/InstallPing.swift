import AkiCore
import Foundation

/// Anonymous notices to the maker, said plainly in Get started and Settings: one when
/// Aki is installed and one each time it updates, so he knows how many people use Aki
/// and on which version (what to fix first, when an old version can be left behind).
/// Each carries Aki's version (and, on an update, the one before), the macOS version,
/// the chip and the language — no account, no identifier, nothing the person marks or
/// types. Only while Settings → General → Privacy allows it; the install one waits a
/// couple of minutes after the first launch (time to turn it off in Get started).
/// The download host turns them into a Telegram message.
@MainActor
enum InstallPing {
    private static let sentKey = "installPingSent"
    /// The version Aki last ran as: a different one now means it was updated.
    private static let lastVersionKey = "lastRunVersion"
    private static let endpoint = URL(string: "https://aki-updates.vercel.app/ping")!

    static func scheduleIfNeeded(_ preferences: Preferences) {
        let defaults = UserDefaults.standard
        let before = defaults.string(forKey: lastVersionKey)
        defaults.set(Aki.version, forKey: lastVersionKey)
        let installed = !defaults.bool(forKey: sentKey)
        let updatedFrom = before.flatMap { $0 != Aki.version ? $0 : nil }
        guard installed || updatedFrom != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (installed ? 120 : 15)) {
            guard preferences.installPing else { return }
            if installed {
                send(event: "install", from: nil) { ok in if ok { defaults.set(true, forKey: sentKey) } }
            } else {
                send(event: "update", from: updatedFrom) { _ in }
            }
        }
    }

    private static func send(event: String, from: String?, done: @escaping @MainActor (Bool) -> Void) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var body: [String: String] = [
            "event": event,
            "version": Aki.version,
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "chip": "Apple Silicon",
            "language": Locale.preferredLanguages.first ?? "",
        ]
        if let from { body["from"] = from }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The maker's own Macs carry a private mark so his tests show up as tests.
        if let me = UserDefaults.standard.string(forKey: "akiMeToken"), !me.isEmpty {
            request.setValue(me, forHTTPHeaderField: "X-Aki-Me")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
            Task { @MainActor in done(ok) }
        }.resume()
    }
}
