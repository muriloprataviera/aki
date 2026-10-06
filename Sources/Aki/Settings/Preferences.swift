// Settings model adapted from Codenotch's Preferences and setting enums
// (MIT, Copyright (c) 2026 Vinz, https://github.com/vinzdg/codenotch).

import AkiCore
import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum SidebarEdge: String, CaseIterable, Identifiable {
    case left, right, top, bottom
    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }
    var title: String {
        switch self {
        case .left: L10n.t("Left")
        case .right: L10n.t("Right")
        case .top: L10n.t("Top")
        case .bottom: L10n.t("Bottom")
        }
    }
}

enum SidebarSize: String, CaseIterable, Identifiable {
    // Two sizes past Large for big monitors (Murilo, 06/10/2026); the bar still shrinks
    // by itself when it wouldn't fit the screen.
    case tiny, small, medium, large, extraLarge, huge
    var id: String { rawValue }
    var scale: CGFloat {
        switch self {
        case .tiny: 0.65
        case .small: 0.8
        case .medium: 1
        case .large: 1.25
        case .extraLarge: 1.5
        case .huge: 1.8
        }
    }
    var title: String {
        switch self {
        case .tiny: L10n.t("Extra small")
        case .small: L10n.t("Small")
        case .medium: L10n.t("Medium")
        case .large: L10n.t("Large")
        case .extraLarge: L10n.t("Extra large")
        case .huge: L10n.t("Huge")
        }
    }
}

/// What a new mark comes with ticked: the text it covers, its crop, both or none.
enum MarkContent: String, CaseIterable, Identifiable {
    /// Text always; the crop only when what you marked looks visual.
    case automatic, text, image, both, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: L10n.t("Automatic")
        case .text: L10n.t("Text")
        case .image: L10n.t("Crop")
        case .both: L10n.t("Both")
        case .none: L10n.t("None")
        }
    }
}

enum SidebarVisibility: String, CaseIterable, Identifiable {
    /// Always open.
    case alwaysShow
    /// A thin pill that opens when the pointer reaches it.
    case onHover
    case hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alwaysShow: L10n.t("Always")
        case .onHover: L10n.t("On hover")
        case .hidden: L10n.t("Hidden")
        }
    }
}

/// The sidebar's outline: a card with four round corners, floating a little off
/// the edge (Aki's), or Codenotch's flares hugging the edge.
enum BarShape: String, CaseIterable, Identifiable {
    case card, flares
    var id: String { rawValue }
    var title: String {
        switch self {
        case .card: L10n.t("4 corners")
        case .flares: L10n.t("Flares")
        }
    }
}

/// Light or dark: following the Mac, or fixed.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.t("Automatic")
        case .light: L10n.t("Light")
        case .dark: L10n.t("Dark")
        }
    }
}

/// The colour that marks things: Aki's red, the Mac's accent, or one of the system's.
enum AccentChoice: String, CaseIterable, Identifiable {
    case aki, system, blue, purple, pink, red, orange, yellow, green, graphite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aki: "Aki"
        case .system: L10n.t("Mac's accent")
        default: L10n.t(rawValue.capitalized)
        }
    }
    /// The swatch (for .system, the Mac's current accent).
    var color: Color {
        switch self {
        case .aki: Color(red: 1.0, green: 59 / 255, blue: 31 / 255)
        case .system: Color(nsColor: .controlAccentColor)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .pink: Color(nsColor: .systemPink)
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Color(nsColor: .systemYellow)
        case .green: Color(nsColor: .systemGreen)
        case .graphite: Color(nsColor: .systemGray)
        }
    }
}

enum SurfaceStyle: String, CaseIterable, Identifiable {
    case glass, darkGlass, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: L10n.t("Glass")
        case .darkGlass: L10n.t("Dark glass")
        case .solid: L10n.t("Solid")
        }
    }
    /// Liquid Glass needs macOS 26; below that, and with Reduce Transparency, it's solid.
    var effective: SurfaceStyle {
        if #available(macOS 26.0, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return self
        }
        return .solid
    }
}

enum AppPresence: String, CaseIterable, Identifiable {
    case dock, menuBar, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dock: L10n.t("Dock")
        case .menuBar: L10n.t("Menu bar")
        case .hidden: L10n.t("Neither")
        }
    }
    var activationPolicy: NSApplication.ActivationPolicy { self == .dock ? .regular : .accessory }
    var wantsStatusItem: Bool { self == .menuBar }
}

enum RingMode: String, CaseIterable, Identifiable {
    /// One ring per terminal, with its name under it.
    case terminals
    /// One ring per agent (Claude, Codex).
    case agents
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminals: L10n.t("Terminals")
        case .agents: L10n.t("Agents")
        }
    }
}

enum CardDetail: String, CaseIterable, Identifiable {
    /// Just the terminals.
    case compact
    /// Terminals, today's numbers and the 30-day chart.
    case full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: L10n.t("Terminals only")
        case .full: L10n.t("Terminals and stats")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    // The site's languages, in its order (Italian after them).
    case system, english, portuguese, spanish, french, german, japanese, chinese, korean, italian
    var id: String { rawValue }
    /// Each language in its own words with its flag (so you find yours whatever is showing).
    var title: String {
        switch self {
        case .system: "🌐 " + L10n.t("System")
        case .english: "🇺🇸 English"
        case .portuguese: "🇧🇷 Português"
        case .spanish: "🇪🇸 Español"
        case .french: "🇫🇷 Français"
        case .german: "🇩🇪 Deutsch"
        case .japanese: "🇯🇵 日本語"
        case .chinese: "🇨🇳 中文"
        case .korean: "🇰🇷 한국어"
        case .italian: "🇮🇹 Italiano"
        }
    }
    /// The two-letter code ("pt", "es"…); nil for English.
    var code: String? {
        switch self {
        case .system, .english: nil
        case .portuguese: "pt"
        case .spanish: "es"
        case .french: "fr"
        case .german: "de"
        case .japanese: "ja"
        case .chinese: "zh"
        case .korean: "ko"
        case .italian: "it"
        }
    }
}

/// Every user setting, persisted in UserDefaults. Observable, so views and the
/// sidebar controller react to changes directly.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    var edge: SidebarEdge { didSet { defaults.set(edge.rawValue, forKey: Keys.edge) } }
    var size: SidebarSize { didSet { defaults.set(size.rawValue, forKey: Keys.size) } }
    /// The two global shortcuts (Settings → General → Shortcuts).
    var markShortcut: KeyCombo {
        didSet { defaults.set(markShortcut.stored, forKey: Keys.markShortcut); L10n.markKeys = markShortcut.display }
    }
    var historyShortcut: KeyCombo {
        didSet { defaults.set(historyShortcut.stored, forKey: Keys.historyShortcut); L10n.historyKeys = historyShortcut.display }
    }
    /// Bumped when the shortcuts are registered again (redraws what shows them).
    var shortcutTick = 0
    var visibility: SidebarVisibility { didSet { defaults.set(visibility.rawValue, forKey: Keys.visibility) } }
    var surface: SurfaceStyle { didSet { defaults.set(surface.rawValue, forKey: Keys.surface) } }
    var barShape: BarShape { didSet { defaults.set(barShape.rawValue, forKey: Keys.barShape) } }
    var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: Keys.accent) } }
    /// The Mac's appearance and accent right now (kept up to date by the app).
    var macIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var macAccentTick = 0
    /// Dark in effect: the theme chosen, or the Mac's when it follows it.
    var isDark: Bool { theme == .system ? macIsDark : theme == .dark }
    /// Names you gave projects (folder → name over its rings).
    var projectNames: [String: String] { didSet { defaults.set(projectNames, forKey: Keys.projectNames) } }
    /// Group the rings by project, with each project's name over its group.
    var showProjects: Bool { didSet { defaults.set(showProjects, forKey: Keys.showProjects) } }
    /// Freeze the screen while marking (off: it keeps running, each mark takes its picture).
    var freezeScreen: Bool { didSet { defaults.set(freezeScreen, forKey: Keys.freezeScreen) } }
    var markContent: MarkContent { didSet { defaults.set(markContent.rawValue, forKey: Keys.markContent) } }
    /// Get started was shown once (it opens by itself on the first launch only).
    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }
    /// The browser answered Aki's page question last time it was checked.
    var browserReady: Bool { didSet { defaults.set(browserReady, forKey: Keys.browserReady) } }
    /// The marking hint bar: folded into a dot, and where you dragged it.
    var hintsFolded: Bool { didSet { defaults.set(hintsFolded, forKey: Keys.hintsFolded) } }
    var hintsOffset: CGSize {
        didSet { defaults.set([hintsOffset.width, hintsOffset.height], forKey: Keys.hintsOffset) }
    }
    /// Done marks are forgotten after this many days (0 = never). Pending ones stay.
    var keepDays: Int { didSet { defaults.set(keepDays, forKey: Keys.keepDays) } }
    /// Updates download and install by themselves (else Aki asks first).
    var installUpdatesByThemselves: Bool {
        didSet { defaults.set(installUpdatesByThemselves, forKey: Keys.installUpdates); Updates.shared.setInstallsByThemselves(installUpdatesByThemselves) }
    }
    /// Beta versions: new things first, for those who want to try them.
    var betaUpdates: Bool { didSet { defaults.set(betaUpdates, forKey: Keys.betaUpdates) } }
    /// One anonymous notice to the maker on first launch (version, macOS, language). On by default; off sends nothing.
    var installPing: Bool { didSet { defaults.set(installPing, forKey: Keys.installPing) } }
    /// Pictures never take more than this on disk (MB); the oldest unneeded go first.
    var maxPicturesMB: Int { didSet { defaults.set(maxPicturesMB, forKey: Keys.maxPicturesMB) } }
    var presence: AppPresence { didSet { defaults.set(presence.rawValue, forKey: Keys.presence) } }
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            L10n.language = language
        }
    }
    var tracksClaude: Bool { didSet { defaults.set(tracksClaude, forKey: Keys.tracksClaude) } }
    /// Agents other than Claude and Codex you switched off.
    var untrackedAgents: Set<String> {
        didSet { defaults.set(Array(untrackedAgents).sorted(), forKey: Keys.untrackedAgents) }
    }

    func tracks(_ agent: AgentSession.Agent) -> Bool {
        switch agent {
        case .claude: tracksClaude
        case .codex: tracksCodex
        default: !untrackedAgents.contains(agent.rawValue)
        }
    }

    func setTracks(_ agent: AgentSession.Agent, _ on: Bool) {
        switch agent {
        case .claude: tracksClaude = on
        case .codex: tracksCodex = on
        default: if on { untrackedAgents.remove(agent.rawValue) } else { untrackedAgents.insert(agent.rawValue) }
        }
    }
    var tracksCodex: Bool { didSet { defaults.set(tracksCodex, forKey: Keys.tracksCodex) } }
    /// Most terminal rings the sidebar shows; the rest fold into a "+N" ring.
    var maxTerminals: Int { didSet { defaults.set(maxTerminals, forKey: Keys.maxTerminals) } }
    var ringMode: RingMode { didSet { defaults.set(ringMode.rawValue, forKey: Keys.ringMode) } }
    var cardDetail: CardDetail { didSet { defaults.set(cardDetail.rawValue, forKey: Keys.cardDetail) } }
    /// Terminals the user chose not to see in the sidebar.
    var hiddenWorktrees: Set<String> {
        didSet { defaults.set(Array(hiddenWorktrees).sorted(), forKey: Keys.hidden) }
    }
    /// Terminal apps the user disconnected (bundle ids): Aki won't jump into them.
    var disconnectedApps: Set<String> {
        didSet { defaults.set(Array(disconnectedApps).sorted(), forKey: Keys.disconnectedApps) }
    }
    /// The order you dragged the session rings into (session ids, first to last).
    var ringOrder: [String] { didSet { defaults.set(ringOrder, forKey: Keys.ringOrder) } }
    /// Agent sessions the user chose not to see as rings (by session id).
    var hiddenTerminals: Set<String> {
        didSet { defaults.set(Array(hiddenTerminals).sorted(), forKey: Keys.hiddenTerminals) }
    }
    /// Seconds without new marks before `aki wait` wakes the agent.
    var waitIdleSeconds: Int { didSet { defaults.set(waitIdleSeconds, forKey: Keys.waitIdle) } }
    /// Types "read Aki's marks" into the session's tab by itself, that many seconds after you send.
    var autoDeliver: Bool { didSet { defaults.set(autoDeliver, forKey: Keys.autoDeliver) } }
    /// Where the sidebar sits along its edge: 0…1 from the start (top or left).
    var alongFraction: Double { didSet { defaults.set(alongFraction, forKey: Keys.along) } }

    /// Read from the system each time rather than stored: the user can change it
    /// in System Settings → Login Items behind our back.
    var launchAtLogin: Bool {
        get {
            _ = loginRevision
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = L10n.t("Couldn't change it. Move Aki to Applications and try again.")
            }
            loginRevision += 1
        }
    }
    var loginError: String?
    private var loginRevision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        edge = value(Keys.edge, SidebarEdge.bottom)
        size = value(Keys.size, SidebarSize.small)
        let mark = KeyCombo(stored: defaults.string(forKey: Keys.markShortcut)) ?? .mark
        let history = KeyCombo(stored: defaults.string(forKey: Keys.historyShortcut)) ?? .history
        markShortcut = mark
        historyShortcut = history
        L10n.markKeys = mark.display
        L10n.historyKeys = history.display
        visibility = value(Keys.visibility, SidebarVisibility.onHover)
        surface = value(Keys.surface, SurfaceStyle.glass)
        barShape = value(Keys.barShape, BarShape.card)
        theme = value(Keys.theme, AppTheme.system)
        accent = value(Keys.accent, AccentChoice.aki)
        projectNames = defaults.dictionary(forKey: Keys.projectNames) as? [String: String] ?? [:]
        showProjects = defaults.object(forKey: Keys.showProjects) as? Bool ?? true
        freezeScreen = defaults.object(forKey: Keys.freezeScreen) as? Bool ?? false
        markContent = value(Keys.markContent, MarkContent.automatic)
        onboarded = defaults.bool(forKey: Keys.onboarded)
        browserReady = defaults.bool(forKey: Keys.browserReady)
        hintsFolded = defaults.bool(forKey: Keys.hintsFolded)
        let offset = defaults.array(forKey: Keys.hintsOffset) as? [Double] ?? []
        hintsOffset = offset.count == 2 ? CGSize(width: offset[0], height: offset[1]) : .zero
        keepDays = defaults.object(forKey: Keys.keepDays) as? Int ?? 30
        installUpdatesByThemselves = defaults.object(forKey: Keys.installUpdates) as? Bool ?? false
        betaUpdates = defaults.object(forKey: Keys.betaUpdates) as? Bool ?? false
        installPing = defaults.object(forKey: Keys.installPing) as? Bool ?? true
        maxPicturesMB = defaults.object(forKey: Keys.maxPicturesMB) as? Int ?? 200
        presence = value(Keys.presence, AppPresence.menuBar)
        language = value(Keys.language, AppLanguage.system)
        tracksClaude = defaults.object(forKey: Keys.tracksClaude) as? Bool ?? true
        tracksCodex = defaults.object(forKey: Keys.tracksCodex) as? Bool ?? true
        untrackedAgents = Set(defaults.stringArray(forKey: Keys.untrackedAgents) ?? [])
        cardDetail = value(Keys.cardDetail, CardDetail.compact)
        ringMode = value(Keys.ringMode, RingMode.terminals)
        maxTerminals = defaults.object(forKey: Keys.maxTerminals) as? Int ?? 10
        hiddenWorktrees = Set(defaults.stringArray(forKey: Keys.hidden) ?? [])
        hiddenTerminals = Set(defaults.stringArray(forKey: Keys.hiddenTerminals) ?? [])
        ringOrder = defaults.stringArray(forKey: Keys.ringOrder) ?? []
        disconnectedApps = Set(defaults.stringArray(forKey: Keys.disconnectedApps) ?? [])
        waitIdleSeconds = defaults.object(forKey: Keys.waitIdle) as? Int ?? 3
        autoDeliver = defaults.object(forKey: Keys.autoDeliver) as? Bool ?? true
        alongFraction = defaults.object(forKey: Keys.along) as? Double ?? 0.5
        L10n.language = language
    }

    private enum Keys {
        static let edge = "sidebarEdge"
        static let markShortcut = "markShortcut"
        static let historyShortcut = "historyShortcut"
        static let size = "sidebarSize"
        static let visibility = "sidebarVisibility"
        static let surface = "surfaceStyle"
        static let barShape = "barShape"
        static let theme = "theme"
        static let accent = "accentColor"
        static let projectNames = "projectNames"
        static let showProjects = "showProjects"
        static let freezeScreen = "freezeScreen"
        static let markContent = "markContent"
        static let onboarded = "onboarded"
        static let browserReady = "browserReady"
        static let hintsFolded = "hintsFolded"
        static let hintsOffset = "hintsOffset"
        static let keepDays = "keepDays"
        static let installUpdates = "installUpdatesByThemselves"
        static let betaUpdates = "betaUpdates"
        static let installPing = "installPing"
        static let maxPicturesMB = "maxPicturesMB"
        static let presence = "appPresence"
        static let language = "appLanguage"
        static let tracksClaude = "tracksClaude"
        static let tracksCodex = "tracksCodex"
        static let untrackedAgents = "untrackedAgents"
        static let waitIdle = "waitIdleSeconds"
        static let autoDeliver = "autoDeliver"
        static let along = "sidebarAlong"
        static let cardDetail = "cardDetail"
        static let ringMode = "ringMode"
        static let maxTerminals = "maxTerminals"
        static let hidden = "hiddenWorktrees"
        static let hiddenTerminals = "hiddenTerminals"
        static let ringOrder = "ringOrder"
        static let disconnectedApps = "disconnectedApps"
    }
}
