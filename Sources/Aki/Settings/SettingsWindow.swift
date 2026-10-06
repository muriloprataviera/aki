// Settings window copied from Codenotch's SettingsWindowController and
// SettingsView (MIT, Copyright (c) 2026 Vinz, https://github.com/vinzdg/codenotch),
// with Aki's panes in place of its provider ones.

import AkiCore
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let preferences: Preferences
    private let model: SidebarModel
    var recentre: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }

    init(preferences: Preferences, model: SidebarModel) {
        self.preferences = preferences
        self.model = model
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            window.close()
            return
        }
        show()
    }

    func show() {
        if let window {
            if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) { window.center() }
            surface(window)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: SettingsView.height),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = L10n.t("Aki Settings")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = true
        window.delegate = self
        window.initialFirstResponder = nil
        window.contentView = NSHostingView(
            rootView: SettingsView(
                preferences: preferences, model: model,
                recentre: { [weak self] in self?.recentre() },
                quit: { [weak self] in self?.quit() }))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        surface(window)
        layoutTrafficLights(in: window)
    }

    /// A window needs the app in the foreground; the Dock icon comes back while it's open.
    private func surface(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
        AppWindows.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // Once it's gone (still visible while closing).
        DispatchQueue.main.async { AppWindows.refresh() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        layoutTrafficLights(in: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        layoutTrafficLights(in: window)
    }

    /// Centres the traffic lights in the sidebar's header band, measured from the
    /// top of the window (not of the title bar, which is shorter than the band).
    private func layoutTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview, let content = window.contentView else { return }
        for (index, button) in buttons.enumerated() {
            let center = NSPoint(
                x: 26 + CGFloat(index) * 22.5,
                y: content.isFlipped
                    ? SettingsView.headerHeight / 2 : content.bounds.height - SettingsView.headerHeight / 2)
            let local = container.convert(center, from: content)
            button.setFrameOrigin(NSPoint(x: local.x - button.frame.width / 2, y: local.y - button.frame.height / 2))
        }
    }
}

// MARK: Sections

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    // Sidebar order: everyday settings first, plumbing last.
    case setup, general, appearance, annotations, keyboard, agents, claude, codex, terminals, storage
    var id: String { rawValue }

    /// One pane per agent, folded under Agents in the sidebar.
    static let agentPanes: [SettingsSection] = [.claude, .codex]
    static var topLevel: [SettingsSection] { allCases.filter { !agentPanes.contains($0) } }

    var agent: AkiCore.AgentSession.Agent? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        default: nil
        }
    }

    var title: String {
        switch self {
        case .agents: L10n.t("Agents")
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .terminals: L10n.t("Terminals")
        case .appearance: L10n.t("Appearance")
        case .annotations: L10n.t("Marking")
        case .setup: L10n.t("Get started")
        case .general: L10n.t("General")
        case .keyboard: L10n.t("Shortcuts")
        case .storage: L10n.t("Storage")
        }
    }

    var subtitle: String {
        switch self {
        case .agents: L10n.t("Choose which coding agents the sidebar shows.")
        case .claude: L10n.t("Claude Code's terminals and connection.")
        case .codex: L10n.t("Codex's terminals and connection.")
        case .terminals: L10n.t("Where your agents run. Aki isn't a terminal: it connects to the ones you already use.")
        case .appearance: L10n.t("How the sidebar looks and where it sits.")
        case .annotations: L10n.t("How marking works.")
        case .setup: L10n.t("What Aki needs from your Mac, and why.")
        case .general: L10n.t("Startup, language and everything else.")
        case .keyboard: L10n.t("Aki's shortcuts, and starting it from Raycast, Alfred or Spotlight.")
        case .storage: L10n.t("Pictures, cleanup and where your data lives.")
        }
    }

    var icon: String {
        switch self {
        case .agents: "person.crop.circle.fill"
        case .claude, .codex: "terminal"
        case .terminals: "macwindow.on.rectangle"
        case .appearance: "paintbrush.fill"
        case .annotations: "scope"
        case .setup: "checklist"
        case .general: "gearshape.fill"
        case .keyboard: "keyboard.fill"
        case .storage: "internaldrive.fill"
        }
    }
}

/// The panel's surfaces. Near-black and flat: the window a shade darker than the
/// sidebar, hairlines instead of shadows.
private enum SettingsPalette {
    static let window = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let sidebar = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let hairline = Color.white.opacity(0.07)
    static let edge = Color.white.opacity(0.09)
    static let selected = Color.white.opacity(0.10)
    static let hovered = Color.white.opacity(0.05)
}

/// The explanation under a setting, as Codenotch writes them.
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsView: View {
    static let width: CGFloat = 860
    static let height: CGFloat = 600
    static let headerHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 220
    static let cornerRadius: CGFloat = 20

    @Bindable var preferences: Preferences
    let model: SidebarModel
    let recentre: () -> Void
    let quit: () -> Void

    @State private var selection: SettingsSection = SettingsView.firstSection
    /// The pane the window opens on: Get started until Aki has been set up once.
    fileprivate static var firstSection: SettingsSection {
        MainActor.assumeIsolated { Preferences.shared.onboarded } ? .agents : .setup
    }
    @State private var didRecentre = false
    @State private var setupResults: [String: Bool] = [:]
    @State private var setupRunning: Set<String> = []
    @State private var agentsExpanded = true
    @State private var authorHovered: String?
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                pane(for: selection)
                    .id(selection)
                    .transition(reduceMotion ? .opacity : .blurFade)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.24), value: selection)
            .clipped()
        }
        // Rebuilt when the language changes, so segmented pickers pick up new titles.
        .id(preferences.language)
        .tint(Color(nsColor: .controlAccentColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPalette.window)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(SettingsPalette.edge, lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The band the traffic lights sit in.
            Color.clear.frame(height: Self.headerHeight)

            // The logotype, big: "aki" with the pointer's pin as the dot.
            Group {
                // The lockup (symbol + logotype, one image so they always line up),
                // centred over the list.
                if let logo = Bundle.main.url(forResource: "Logotype", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                    Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 40)
                } else {
                    Text("aki").font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.topLevel) { section in
                        SettingsSidebarRow(
                            section: section, isSelected: selection == section, selectionSpace: selectionSpace,
                            count: section == .agents ? trackedCount : nil,
                            disclosure: section == .agents ? $agentsExpanded : nil,
                            select: { selectSection(section) })
                        if section == .agents, agentsExpanded {
                            ForEach(SettingsSection.agentPanes) { child in
                                SettingsSidebarRow(
                                    section: child, isSelected: selection == child, selectionSpace: selectionSpace,
                                    indent: true, select: { selectSection(child) })
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                SettingsQuitRow(quit: quit)
                Text("Aki \(SettingsView.prettyVersion)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.32))
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebar)
        .overlay(alignment: .trailing) { SettingsPalette.hairline.frame(width: 1) }
    }

    private var trackedCount: Int {
        (preferences.tracksClaude ? 1 : 0) + (preferences.tracksCodex ? 1 : 0)
    }

    /// The pill slides on a spring; the pane itself crossfades on its own.
    private func selectSection(_ section: SettingsSection) {
        guard section != selection else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { selection = section }
    }

    /// A large title and a line under it, fixed above the scrolling content,
    /// then a hairline across the whole pane.
    private func pane(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                Text(section.subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsPalette.hairline.frame(height: 1)

            paneContent(for: section)
                .scrollContentBackground(.hidden)
                .buttonStyle(SettingsButtonStyle())
        }
    }

    @ViewBuilder private func paneContent(for section: SettingsSection) -> some View {
        switch section {
        case .agents: agentsPane
        case .claude: agentPane(.claude)
        case .codex: agentPane(.codex)
        case .terminals: terminalsPane
        case .appearance: appearancePane
        case .annotations: annotationsPane
        case .setup: GetStartedPane(openAgents: { selectSection(.agents) })
        case .general: generalPane
        case .keyboard: keyboardPane
        case .storage: storagePane
        }
    }

    // MARK: Panes

    private var agentsPane: some View {
        Form {
            Section(L10n.t("Agents")) {
                ForEach(AkiCore.AgentSession.Agent.allCases, id: \.self) { agent in
                    agentRow(agent, title: agent.displayName, isOn: Binding(
                        get: { preferences.tracks(agent) }, set: { preferences.setTracks(agent, $0) }))
                }
                Caption(L10n.t("One ring per agent. Hover it to see its terminals; click it to keep the card open."))
            }
            Section(L10n.t("Connect")) {
                setupRow("claude", L10n.t("Claude Code"), action: L10n.t("Connect"))
                setupRow("codex", L10n.t("Codex"), action: L10n.t("Connect"))
                setupRow("cli", L10n.t("Command `aki`"), action: L10n.t("Install"))
                wakeStepper
                Caption(L10n.t("Adds Aki's MCP so the agent reads your marks. Conversations already open see it after a restart (/exit, then claude --resume)."))
            }
        }
        .formStyle(.grouped)
    }

    private func agentPane(_ agent: AkiCore.AgentSession.Agent) -> some View {
        let sessions = model.sessions.filter { $0.agents.contains(agent) }
        return Form {
            Section(L10n.t("Terminals")) {
                if sessions.isEmpty {
                    Caption(L10n.t("No terminals open right now."))
                }
                ForEach(sessions) { session in
                    Toggle(isOn: Binding(
                        get: { !preferences.hiddenWorktrees.contains(session.worktree) },
                        set: { shown in
                            if shown { preferences.hiddenWorktrees.remove(session.worktree) }
                            else { preferences.hiddenWorktrees.insert(session.worktree) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.label(for: session))
                            Text([session.branch, session.worktree].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Caption(L10n.t("Switch a terminal off to leave it out of the sidebar."))
            }
            Section(L10n.t("Connect")) {
                setupRow(agent == .claude ? "claude" : "codex", agent.displayName, action: L10n.t("Connect"))
                wakeStepper
                Caption(L10n.t("Adds Aki's MCP so the agent reads your marks."))
            }
        }
        .formStyle(.grouped)
    }

    private func agentRow(_ agent: AkiCore.AgentSession.Agent, title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                AgentGlyphView(agent: agent, size: 16).foregroundStyle(.white)
                Text(title)
            }
        }
    }

    private var terminalsPane: some View {
        // Which app each open conversation runs in, counted per app.
        let owners = model.terminals.compactMap { TerminalApp.owner(of: $0.pid)?.bundleIdentifier }
        let counts = Dictionary(owners.map { ($0, 1) }, uniquingKeysWith: +)
        let installed = TerminalApp.installed
        let others = Set(owners).subtracting(installed.map(\.id))
        return Form {
            // What Aki does with your terminals, in three lines, before any switch.
            Section {
                StepLine(number: 1, text: L10n.t("Aki finds every Claude Code / Codex session open in these apps and shows it as a ring in the sidebar."))
                StepLine(number: 2, text: L10n.t("Double-click a ring to jump to that session."))
                StepLine(number: 3, text: L10n.t("When you send marks, Aki types the request into the session (Orca). In other terminals the agent picks them up through the MCP or `aki wait`."))
            } header: { Text(L10n.t("How it works")) }

            Section {
                ForEach(installed) { app in
                    terminalRow(
                        id: app.id, name: app.name, icon: app.icon, running: app.isRunning, sessions: counts[app.id] ?? 0,
                        caption: L10n.t(app.reach == .tab
                            ? "Double-click opens the session's tab · Aki types the request in it"
                            : "Double-click brings the app forward · the agent reads marks itself"))
                }
                if !others.isEmpty {
                    ForEach(Array(others).sorted(), id: \.self) { id in
                        let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
                        terminalRow(
                            id: id, name: app?.localizedName ?? id, icon: app?.icon, running: true, sessions: counts[id] ?? 0,
                            caption: L10n.t("Double-click brings the app forward · the agent reads marks itself"))
                    }
                }
            } header: { Text(L10n.t("Show sessions from")) } footer: {
                Caption(L10n.t("Switch an app off to leave its sessions out of the sidebar."))
            }

            Section {
                wakeStepper
                LabeledContent(L10n.t("Agent connection (MCP)")) {
                    Button(L10n.t("Open Agents")) { selectSection(.agents) }
                }
                Caption(L10n.t("Connect Claude Code and Codex once in Agents, so they can read your marks."))
            } header: { Text(L10n.t("Sending to the agent")) }
        }
        .formStyle(.grouped)
    }

    private func terminalRow(id: String, name: String, icon: NSImage?, running: Bool, sessions: Int, caption: String) -> some View {
        Toggle(isOn: Binding(
            get: { !preferences.disconnectedApps.contains(id) },
            set: { connected in
                if connected { preferences.disconnectedApps.remove(id) } else { preferences.disconnectedApps.insert(id) }
            }
        )) {
            HStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                        if running {
                            Text(sessions > 0 ? "\(sessions) \(L10n.t(sessions == 1 ? "session" : "sessions"))" : L10n.t("open"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Caption(caption)
                }
            }
        }
    }

    private var appearancePane: some View {
        Form {
            Section(L10n.t("Sidebar")) {
                Picker(L10n.t("Show"), selection: $preferences.visibility) {
                    ForEach(SidebarVisibility.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(visibilityExplanation)

                Picker(L10n.t("Edge"), selection: $preferences.edge) {
                    ForEach(SidebarEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("The screen edge the sidebar is pinned to."))

                Toggle(L10n.t("Show projects"), isOn: $preferences.showProjects)
                Caption(L10n.t("Sessions of one project side by side, with its name over them."))

                Picker(L10n.t("Theme"), selection: $preferences.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(L10n.t("Accent color")) {
                    HStack(spacing: 7) {
                        ForEach(AccentChoice.allCases) { choice in
                            let on = preferences.accent == choice
                            Button { preferences.accent = choice } label: {
                                ZStack {
                                    if choice == .system {
                                        Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                                    } else {
                                        Circle().fill(choice.color)
                                    }
                                    if choice == .aki {
                                        Circle().fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)).frame(width: 7, height: 7)
                                    }
                                }
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.9 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(choice.title)
                        }
                    }
                }
                Caption(L10n.t("Automatic follows your Mac's light or dark look. The accent marks what's chosen and what needs you; \"Aki\" is the brand's red."))

                Picker(L10n.t("Shape"), selection: $preferences.barShape) {
                    ForEach(BarShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("A card with four round corners, or flares that hug the screen edge."))

                if #available(macOS 26.0, *) {
                    Picker(L10n.t("Surface"), selection: $preferences.surface) {
                        ForEach(SurfaceStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Caption(L10n.t("Glass follows the desktop behind it; solid is always black."))
                }

                Picker(L10n.t("Size"), selection: $preferences.size) {
                    ForEach(SidebarSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("Scales the rings and the bar together. The card keeps its size."))

                Picker(L10n.t("Rings"), selection: $preferences.ringMode) {
                    ForEach(RingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("One ring per terminal with its name, or one per agent."))

                if preferences.ringMode == .terminals {
                    Stepper(value: $preferences.maxTerminals, in: 2...12) {
                        HStack {
                            Text(L10n.t("Show at most"))
                            Spacer()
                            Text("\(preferences.maxTerminals)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Caption(L10n.t("The busiest terminals get a ring; the rest are one hover away in the +N ring."))
                }

                Picker(L10n.t("Card"), selection: $preferences.cardDetail) {
                    ForEach(CardDetail.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("What the card beside a ring shows."))

                HStack {
                    Caption(L10n.t("Drag the dots beside the settings button, or hold ⌥ and drag the sidebar, to slide it along its edge."))
                    Spacer()
                    Button {
                        preferences.alongFraction = 0.5
                        recentre()
                        withAnimation(.easeInOut(duration: 0.15)) { didRecentre = true }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            withAnimation(.easeInOut(duration: 0.15)) { didRecentre = false }
                        }
                    } label: {
                        Label(L10n.t("Recentre"), systemImage: didRecentre ? "checkmark" : "arrow.counterclockwise")
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .prominent))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var visibilityExplanation: String {
        switch preferences.visibility {
        case .alwaysShow: L10n.t("Always open, with every ring showing.")
        case .onHover: L10n.t("A thin pill until the pointer reaches it.")
        case .hidden: L10n.t("Out of sight. Open Aki again to bring Settings back.")
        }
    }

    private var annotationsPane: some View {
        Form {
            Section(L10n.t("Marking")) {
                Toggle(L10n.t("Freeze the screen while marking"), isOn: $preferences.freezeScreen)
                Caption(L10n.t("Off: the screen keeps running and each mark takes its own picture."))
                Picker(L10n.t("Ticked on a new mark"), selection: $preferences.markContent) {
                    ForEach(MarkContent.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("Automatic: the text always, the crop only when what you marked looks visual. You can still change each mark."))
            }
        }
        .formStyle(.grouped)
    }

    private var storagePane: some View {
        Form {
            Section(L10n.t("Disk space")) {
                let usage = model.diskUsage
                LabeledContent(L10n.t("Pictures sent")) {
                    Text("\(Bytes.text(usage.imageBytes)) · \(usage.imageCount)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                LabeledContent(L10n.t("This Mac's disk")) {
                    Text("\(Bytes.text(usage.diskFree)) \(L10n.t("free of")) \(Bytes.text(usage.diskTotal))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                DiskBar(usage: usage)
                LabeledContent(L10n.t("No longer needed")) {
                    HStack(spacing: 8) {
                        Text("\(Bytes.text(usage.unusedBytes)) · \(usage.unusedCount)")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button(L10n.t("Delete")) { model.cleanImages() }
                            .disabled(usage.unusedCount == 0)
                    }
                }
                Caption(L10n.t("Pictures of marks already resolved or deleted. Aki deletes them by itself as the agent resolves; this clears what's left."))
                Picker(L10n.t("Keep done marks for"), selection: $preferences.keepDays) {
                    Text("7 \(L10n.t("days"))").tag(7)
                    Text("30 \(L10n.t("days"))").tag(30)
                    Text("90 \(L10n.t("days"))").tag(90)
                    Text(L10n.t("forever")).tag(0)
                }
                Picker(L10n.t("Pictures at most"), selection: $preferences.maxPicturesMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                Caption(L10n.t("Pending marks always stay. Pictures live in ~/.aki/images/<project>/<session>/ and never pass the limit: the oldest no mark needs go first."))
            }
            Section(L10n.t("Data")) {
                LabeledContent(L10n.t("Server"), value: model.serverStatus.label)
                LabeledContent(L10n.t("Data folder")) {
                    Button(L10n.t("Open")) {
                        let url = AkiHome.default.url
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
                Caption(L10n.t("Everything stays on this Mac, in ~/.aki."))
            }
        }
        .formStyle(.grouped)
    }

    private var keyboardPane: some View {
        Form {
            Section {
                let _ = preferences.shortcutTick
                LabeledContent(L10n.t("Mark the screen")) {
                    ShortcutRecorder(combo: $preferences.markShortcut, fallback: .mark,
                                     taken: GlobalShortcuts.shared.taken.contains("mark"))
                }
                LabeledContent(L10n.t("History")) {
                    ShortcutRecorder(combo: $preferences.historyShortcut, fallback: .history,
                                     taken: GlobalShortcuts.shared.taken.contains("history"))
                }
                Caption(L10n.t("They work in any app. Click one and press the new keys; esc cancels."))
            } header: { Text(L10n.t("Anywhere")) }
            Section(L10n.t("While marking")) {
                ForEach(Self.shortcuts, id: \.keys) { item in
                    LabeledContent(L10n.t(item.title)) {
                        Text(item.keys).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
            }
            Section(L10n.t("Raycast, Alfred and Spotlight")) {
                ForEach(Self.links, id: \.url) { link in
                    LabeledContent(L10n.t(link.title)) { CopyLink(text: link.url) }
                }
                Caption(L10n.t("Any launcher that opens a link can drive Aki with these."))
                LabeledContent("Raycast") {
                    Button(L10n.t("Add to Raycast")) { RaycastCommands.install() }
                }
                Caption(L10n.t("In Raycast: Settings → Extensions → + → Add Script Directory, and pick the folder that opened. Each command can get its own hotkey there."))
                Caption(L10n.t("Spotlight (⌘Space): in the Shortcuts app, make a shortcut that opens aki://mark. It shows up in Spotlight by its name."))
            }
        }
        .formStyle(.grouped)
    }

    /// The links Aki answers (aki://…), for launchers.
    static let links: [(title: String, url: String)] = [
        ("Mark the screen", "aki://mark"), ("History", "aki://history"),
        ("Settings…", "aki://settings"), ("Show or hide the sidebar", "aki://sidebar"),
    ]

    /// "0.2.0-beta.1" reads "0.2 beta", "0.2.0-beta.3" "0.2 beta 3", "0.3.0" "0.3".
    static var prettyVersion: String {
        let parts = Aki.version.split(separator: "-", maxSplits: 1)
        var number = String(parts[0])
        if number.hasSuffix(".0") { number.removeLast(2) }
        guard parts.count > 1 else { return number }
        let tag = parts[1].split(separator: ".")
        let name = String(tag.first ?? "beta")
        let n = tag.count > 1 ? String(tag[1]) : "1"
        return n == "1" ? "\(number) \(name)" : "\(number) \(name) \(n)"
    }

    private var generalPane: some View {
        Form {
            Section {
                Picker(L10n.t("Language"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle(L10n.t("Open at login"), isOn: $preferences.launchAtLogin)
                if let error = preferences.loginError {
                    Caption(error)
                }
                Picker(L10n.t("App icon"), selection: $preferences.presence) {
                    ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Caption(L10n.t("Where Aki shows itself besides the sidebar."))
            }
            Section(L10n.t("Updates")) {
                LabeledContent(L10n.t("Version")) {
                    HStack(spacing: 8) {
                        Text("Aki \(Self.prettyVersion)").foregroundStyle(.secondary).monospacedDigit()
                        Button(L10n.t("Check now")) { Updates.shared.checkForUpdates() }
                    }
                }
                // What the check found, here too (the sidebar's pill may be hidden).
                if model.update != .idle {
                    HStack(spacing: 6) {
                        Image(systemName: model.update.icon)
                        Text(model.update.text).monospacedDigit()
                        Spacer()
                        if model.update.clickable, case .available = model.update {
                            Button(L10n.t("Update")) { Updates.shared.tap() }
                        }
                    }
                    .foregroundStyle(model.update == .failed ? AkiPalette.red : .secondary)
                }
                Toggle(L10n.t("Install updates by themselves"), isOn: $preferences.installUpdatesByThemselves)
                Toggle(L10n.t("Get beta versions"), isOn: $preferences.betaUpdates)
                Caption(L10n.t("Aki checks every hour. Betas bring new things first and may be less steady."))
            }
            Section(L10n.t("Privacy")) {
                Toggle(L10n.t("Send anonymous notices to the maker"), isOn: $preferences.installPing)
                Caption(L10n.t("When Aki is installed and each time it updates: its version (and the one before), your macOS version and language. No account, no identifier, nothing you mark or type."))
                Caption(L10n.t("Why: to know how many people use Aki and on which version, so the right things get fixed first and old versions can be retired safely."))
            }
            Section(L10n.t("About")) {
                HStack(spacing: 14) {
                    Image(nsImage: AkiBrand.appIcon).resizable().interpolation(.high).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aki \(Self.prettyVersion)").font(.system(size: 14, weight: .semibold))
                        Caption(L10n.t("Point at anything on screen. Your coding agent reads it."))
                    }
                }
                .padding(.vertical, 2)
            }
            Section {
                HStack(spacing: 4) {
                    Text(L10n.t("App designed and developed by"))
                    Text("Murilo Prataviera").foregroundStyle(.primary)
                    Text("·")
                    ForEach(Self.authorLinks, id: \.label) { link in
                        Link(link.label, destination: link.url)
                            .foregroundStyle(authorHovered == link.label ? Color(nsColor: .controlAccentColor) : .primary)
                            .underline(authorHovered == link.label)
                            .animation(.easeOut(duration: 0.12), value: authorHovered)
                            .onHover { inside in
                                authorHovered = inside ? link.label : nil
                                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The shortcuts inside marking (the two global ones can be changed above them).
    static let shortcuts: [(title: String, keys: String)] = [
        ("Add to queue", "⏎"), ("Send now", "⌘⏎"),
        ("Next session", "⇥"), ("Walk the page's elements", "↑ ↓ ← →"), ("Leave", "esc"), ("Settings…", "⌘,"),
    ]

    /// Where to find the author.
    static let authorLinks: [(label: String, url: URL)] = [
        ("X", URL(string: "https://x.com/muprataviera")!),
        ("Instagram", URL(string: "https://www.instagram.com/muriloprataviera")!),
        ("GitHub", URL(string: "https://github.com/muriloprataviera")!),
    ]

    private func setupRow(_ key: String, _ title: String, action: String) -> some View {
        LabeledContent(title) {
            ConnectButton(title: action, result: setupResults[key], running: setupRunning.contains(key)) {
                setupRunning.insert(key)
                Task {
                    let ok = await Setup.run(key)
                    setupRunning.remove(key)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { setupResults[key] = ok }
                }
            }
        }
        .task { if setupResults[key] == nil, await Setup.isConnected(key) { setupResults[key] = true } }
    }

    /// How long after your last mark the agent wakes (also next to Connect).
    private var wakeStepper: some View {
        Group {
            Toggle(L10n.t("Send to the terminal by itself"), isOn: $preferences.autoDeliver)
            Stepper(value: $preferences.waitIdleSeconds, in: 1...30) {
                HStack {
                    Text(L10n.t("Wake the agent after"))
                    Spacer()
                    Text("\(preferences.waitIdleSeconds) s").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Caption(L10n.t("Types the request into the session's Orca tab when you stop marking (it waits while the agent is working)."))
            Toggle(L10n.t("Destination follows the Orca tab you click"), isOn: $preferences.followOrcaTab)
            Caption(L10n.t("Click an agent's tab in Orca and new marks go to it. Other apps and tabs keep the destination."))
        }
    }
}

/// A numbered line of a short how-to.
private struct StepLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(AkiPalette.red))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Wires Aki into the user's agents and shell. Runs through a login shell so the
/// user's PATH (where `claude` and `codex` live) applies.
enum Setup {
    /// Whether it's already wired (so the row shows ✓ when you open Settings).
    static func isConnected(_ key: String) async -> Bool {
        let command: String
        switch key {
        case "claude": command = "claude mcp get aki"
        case "codex": command = "codex mcp get aki"
        case "cli": command = "test -x \"$HOME/.local/bin/aki\""
        default: return false
        }
        return await shell(command)
    }

    private static func shell(_ command: String) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    static func run(_ key: String) async -> Bool {
        guard let binary = Bundle.main.executablePath else { return false }
        let quoted = "'\(binary)'"
        let command: String
        switch key {
        case "claude": command = "claude mcp remove --scope user aki >/dev/null 2>&1; claude mcp add --scope user aki -- \(quoted) mcp"
        case "codex": command = "codex mcp remove aki >/dev/null 2>&1; codex mcp add aki -- \(quoted) mcp"
        case "cli": command = "mkdir -p \"$HOME/.local/bin\" && ln -sf \(quoted) \"$HOME/.local/bin/aki\""
        default: return false
        }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}

// MARK: Components (Codenotch's)

/// One row of the settings sidebar: a white symbol, the name, and an optional count.
private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let selectionSpace: Namespace.ID
    var indent = false
    var count: Int? = nil
    var disclosure: Binding<Bool>? = nil
    let select: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    /// Bumped each time the row becomes selected, to play the icon's bounce once.
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pill = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18)
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : isHovered ? 0.85 : 0.6))
                // Leans toward the pointer's row a hair, and pops once on selection.
                .offset(x: isHovered && !isSelected && !reduceMotion ? 1.5 : 0)
            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : isHovered ? 0.92 : 0.78))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(isHovered || isSelected ? 0.55 : 0.42))
                    .contentTransition(.numericText())
            }
            if let disclosure {
                DisclosureChevron(isExpanded: disclosure)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { value in
                    isPressed = false
                    if abs(value.translation.width) < 6, abs(value.translation.height) < 6 { select() }
                }
        )
        .padding(.leading, indent ? 28 : 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background {
            ZStack {
                if isHovered && !isSelected {
                    Self.pill.fill(SettingsPalette.hovered).transition(.opacity)
                }
                if isSelected {
                    Self.pill
                        .fill(SettingsPalette.selected)
                        .overlay {
                            // A hairline lit from above, so the pill reads as raised.
                            Self.pill.strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.5)
                        }
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
        }
        .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isPressed)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.14)) { isHovered = hovering } }
        .onChange(of: isSelected) { _, selected in if selected { bounce += 1 } }
    }

    @ViewBuilder private var icon: some View {
        if let agent = section.agent {
            AgentGlyphView(agent: agent, size: 14)
                .keyframeAnimator(initialValue: 1.0, trigger: bounce) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    SpringKeyframe(1.18, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
        } else {
            Image(systemName: section.icon)
                .font(.system(size: indent ? 12 : 13, weight: .regular))
                .symbolEffect(.bounce, value: bounce)
        }
    }
}

/// The arrow that folds Agents' panes away: brighter under the pointer, a soft
/// disc behind it, and a springy turn.
private struct DisclosureChevron: View {
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(isHovered ? 0.85 : 0.45))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(isHovered ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(SettingsPressStyle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
    }
}

private struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct SettingsQuitRow: View {
    let quit: () -> Void
    @State private var isHovered = false
    private static let hoverRed = Color(red: 1, green: 0.42, blue: 0.4)

    var body: some View {
        Button(action: quit) {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 18)
                Text(L10n.t("Quit Aki"))
                    .font(.system(size: 13, weight: .regular))
            }
            .foregroundStyle(isHovered ? Self.hoverRed : Color.white.opacity(0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? SettingsPalette.hovered : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.14)) { isHovered = hovering } }
    }
}

private struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

private extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(radius: 10, opacity: 0), identity: BlurFade(radius: 0, opacity: 1))
    }
}

/// Connect: spins while it works, then a ✓ that pops with a little burst.
private struct ConnectButton: View {
    let title: String
    let result: Bool?
    let running: Bool
    let action: () -> Void
    @State private var burst = false

    var body: some View {
        HStack(spacing: 8) {
            if running {
                ProgressView().controlSize(.small)
            } else if let result {
                ZStack {
                    // The burst: a ring of sparks flying out once.
                    ForEach(0..<8, id: \.self) { i in
                        Circle()
                            .fill(result ? AkiPalette.aurora[i % AkiPalette.aurora.count] : Color.red)
                            .frame(width: 3, height: 3)
                            .offset(y: burst ? -13 : -4)
                            .rotationEffect(.degrees(Double(i) * 45))
                            .opacity(burst ? 0 : 1)
                    }
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(result ? Color.green : Color.red)
                        .scaleEffect(burst ? 1 : 0.4)
                }
                .onAppear {
                    burst = false
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { burst = true }
                }
                Text(L10n.t(result ? "Connected" : "Failed")).font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            Button(result == true ? L10n.t("Reconnect") : title, action: action)
                .disabled(running)
        }
    }
}

/// "12,4 MB", "1,2 GB".
enum Bytes {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The disk as a bar: what's used, and Aki's pictures in Aki's colours (drawn at
/// least a sliver wide so you can see it's there).
private struct DiskBar: View {
    let usage: DiskUsage

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(usage.diskTotal), 1)
            let used = Double(usage.diskTotal - usage.diskFree) / total
            let aki = usage.imageBytes > 0 ? max(Double(usage.imageBytes) / total, 0.004) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: geo.size.width * used)
                Capsule().fill(AkiPalette.auroraDiagonal).frame(width: max(geo.size.width * aki, aki > 0 ? 4 : 0))
            }
        }
        .frame(height: 8)
        .help(String(format: "%.4f%%", usage.shareOfDisk * 100))
    }
}
