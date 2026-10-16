import Foundation

/// Aki's texts: written in English in the code (`L10n.t("…")`), one table per
/// language in `L10n+<Language>.swift`. Plain dictionaries, so it builds without Xcode.
/// A repeated key crashes the app at launch: check before adding one.
enum L10n {
    /// Only written from the main actor (Preferences); read anywhere.
    nonisolated(unsafe) static var language: AppLanguage = .system
    /// The shortcuts as chosen; `{mark}` and `{history}` in any text become them.
    nonisolated(unsafe) static var markKeys = "⇧⌘A"
    nonisolated(unsafe) static var historyKeys = "⇧⌘H"
    static var mark: String { markKeys }
    static var history: String { historyKeys }

    /// The language in use: the one chosen, or the Mac's when it's one Aki speaks.
    static var code: String? {
        if language != .system { return language.code }
        return macLanguage
    }

    /// The Mac's language, when Aki speaks it: looked up once (every text asks), and
    /// again when the Mac's language changes.
    nonisolated(unsafe) private static var macLanguage: String? = {
        NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil) { _ in
            macLanguage = lookUpMacLanguage()
        }
        return lookUpMacLanguage()
    }()

    private static func lookUpMacLanguage() -> String? {
        let mac = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        return ["pt", "es", "fr", "de", "ja", "zh", "ko", "it"].contains(mac) ? mac : nil
    }

    static var isPortuguese: Bool { code == "pt" }
    /// Dates and numbers in the language in use.
    static var locale: Locale {
        if let code { return Locale(identifier: code) }
        // English chosen: dates in English too, whatever the Mac's language.
        return language == .english ? Locale(identifier: "en") : .current
    }

    static func t(_ english: String) -> String {
        let table: [String: String]? = switch code {
        case "pt": portuguese
        case "es": spanish
        case "fr": french
        case "de": german
        case "ja": japanese
        case "zh": chinese
        case "ko": korean
        case "it": italian
        default: nil
        }
        let text = table?[english] ?? english
        guard text.contains("{") else { return text }
        return text.replacingOccurrences(of: "{mark}", with: markKeys).replacingOccurrences(of: "{history}", with: historyKeys)
    }
}
