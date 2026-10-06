import AkiCore
import Foundation

/// One notice to the maker that Aki was installed: sent once, a couple of minutes after the
/// first launch (time to turn it off in Get started), only while Settings → General allows it.
/// It carries Aki's version, the macOS version, the chip and the language — no account, no
/// identifier, nothing the person marks. The download host turns it into a Telegram message.
@MainActor
enum InstallPing {
    private static let sentKey = "installPingSent"
    private static let endpoint = URL(string: "https://aki-updates.vercel.app/ping")!

    static func scheduleIfNeeded(_ preferences: Preferences) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: sentKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            guard preferences.installPing, !defaults.bool(forKey: sentKey) else { return }
            send { ok in if ok { defaults.set(true, forKey: sentKey) } }
        }
    }

    private static func send(done: @escaping @MainActor (Bool) -> Void) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body: [String: String] = [
            "version": Aki.version,
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "chip": "Apple Silicon",
            "language": Locale.preferredLanguages.first ?? "",
        ]
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
