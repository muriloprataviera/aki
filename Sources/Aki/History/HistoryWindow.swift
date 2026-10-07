import AkiCore
import AppKit
import SwiftUI

/// Everything you've marked, in the middle of the screen (⇧⌘H by default): by session,
/// newest first, with what's still waiting and what the agent already resolved.
@MainActor
final class HistoryWindowController {
    private let model: SidebarModel
    private var panel: NSPanel?

    init(model: SidebarModel) {
        self.model = model
    }

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show(session: String? = nil, queue: Bool = false) {
        model.historySession = session
        model.historyOnQueue = queue
        model.historyRequest += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        AppWindows.refresh()
    }

    private var escMonitor: Any?

    private func makePanel() -> NSPanel {
        // esc closes it, even with the cursor in the search field (which would keep the key).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let panel = self?.panel, panel.isKeyWindow else { return event }
            panel.orderOut(nil)
            return nil
        }
        // A regular Mac window: close, minimise and zoom in the corner, as everywhere.
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = L10n.t("History")
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(white: 0.06, alpha: 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 480, height: 380)
        panel.collectionBehavior.insert(.fullScreenPrimary)
        panel.contentView = NSHostingView(rootView: HistoryView(model: model, close: { [weak panel] in panel?.orderOut(nil) }))
        return panel
    }
}

/// Closes with esc or ⌘W.
private final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    /// ⌘W and the red button: hidden, ready to come back.
    override func performClose(_ sender: Any?) { orderOut(nil) }
    /// However it's hidden, Aki leaves ⌘Tab if no other window of it is open.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        MainActor.assumeIsolated { AppWindows.refresh() }
    }
}

private struct HistoryView: View {
    let model: SidebarModel
    let close: () -> Void

    enum Show: String, CaseIterable { case pending, resolved, all }

    @State private var annotations: [Annotation] = []
    @State private var show: Show = .all
    @State private var session: String?
    /// One AI only (Claude, Codex…), or all of them.
    @State private var agent: AgentSession.Agent?
    /// One app the sessions ran in (Orca, VS Code, Terminal…), by bundle id.
    @State private var app: String?
    /// One project (worktree).
    @State private var project: String?
    /// Words to find in the comment, the text read, the page or the element.
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Room for close / minimise / zoom.
                Color.clear.frame(width: 62, height: 1)
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AkiPalette.auroraDiagonal)
                Text(L10n.t("History")).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Spacer()
                ForEach(Show.allCases, id: \.self) { option in
                    let on = show == option
                    Button { withAnimation(.easeOut(duration: 0.15)) { show = option } } label: {
                        Text("\(L10n.t(option == .pending ? "Pending" : option == .resolved ? "Done marks" : "All")) \(count(option))")
                            .font(.system(size: 10.5, weight: on ? .bold : .medium))
                            .foregroundStyle(on ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.001)))
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                }
            }
            // Find, then narrow by AI, app, project and session.
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    TextField(L10n.t("Search marks"), text: $query)
                        .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.white)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                .frame(maxWidth: 220)
                FilterMenu(icon: { agentIcon(agent) }, title: agent?.displayName ?? L10n.t("All AIs"), active: agent != nil,
                           clear: { agent = nil }) {
                    Button("\(L10n.t("All AIs"))") { agent = nil }
                    Divider()
                    ForEach(agents, id: \.self) { value in
                        Button("\(value.displayName)  ·  \(annotations.filter { agentOf($0) == value }.count)") { agent = value }
                    }
                }
                FilterMenu(icon: { appIcon(app) }, title: app.flatMap(appName) ?? L10n.t("All apps"), active: app != nil,
                           clear: { app = nil }) {
                    Button(L10n.t("All apps")) { app = nil }
                    Divider()
                    ForEach(apps, id: \.self) { id in
                        Button("\(appName(id) ?? id)  ·  \(annotations.filter { appOf($0) == id }.count)") { app = id }
                    }
                }
                FilterMenu(icon: { Image(systemName: "folder").font(.system(size: 10, weight: .semibold)) },
                           title: project.map(projectName) ?? L10n.t("All projects"), active: project != nil,
                           clear: { project = nil }) {
                    Button(L10n.t("All projects")) { project = nil }
                    Divider()
                    ForEach(projects, id: \.self) { wt in
                        Button("\(projectName(wt))  ·  \(annotations.filter { $0["worktree"]?.string == wt }.count)") { project = wt }
                    }
                }
                FilterMenu(icon: { Image(systemName: "terminal").font(.system(size: 10, weight: .semibold)) },
                           title: session.flatMap { key in sessions.first { $0.id == key }?.name } ?? L10n.t("All sessions"),
                           active: session != nil, clear: { session = nil }) {
                    Button(L10n.t("All sessions")) { session = nil }
                    Divider()
                    ForEach(sessions, id: \.id) { chip in
                        Button("\(chip.number.map { "\($0)  " } ?? "")\(chip.name)  ·  \(Bytes.text(Int64(sessionBytes(chip.id))))") { session = chip.id }
                    }
                }
                Spacer(minLength: 0)
            }
            // Marks saved but not sent yet: their own block on top, apart from the history.
            if !model.queuedList.isEmpty {
                QueueSection(model: model, close: close)
                HStack(spacing: 8) {
                    Text(L10n.t("History").uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.white.opacity(0.4))
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                }
                .padding(.top, 4)
            }
            if filtered.isEmpty {
                Spacer()
                Text(L10n.t("Nothing here yet. Mark with {mark}.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.self) { day in
                            Section {
                                ForEach(filtered.filter { dayKey($0) == day }, id: \.id) { a in
                                    HistoryRow(annotation: a, name: name(of: a), number: number(of: a),
                                               identity: SessionIdentity(annotation: a, terminal: terminal(of: a)),
                                               sessions: model.allTerminals.map { ($0, model.number(of: $0.id)) },
                                               move: { t in act { await model.moveMark(a.id, to: t) } },
                                               resolve: { act { _ = try? await model.store.update(a.id, with: ["status": .string("completed")]) } },
                                               delete: { act { _ = try? await model.store.delete(a.id) } },
                                               resend: terminal(of: a).map { t in { model.deliver(t) } })
                                }
                            } header: {
                                Text(dayTitle(day).uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.top, 4).padding(.bottom, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(white: 0.06))
                            }
                        }
                    }
                    // Room for the scroll bar, so it never sits on the ✓.
                    .padding(.trailing, 12)
                }
            }
            HStack {
                Text(model.preferences.keepDays > 0
                     ? "\(L10n.t("Done marks are deleted after")) \(model.preferences.keepDays) \(L10n.t("days"))"
                     : L10n.history)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("\(L10n.t("Sent")): \(Bytes.text(Int64(totals.sent))) · \(L10n.t("on this Mac now")): \(Bytes.text(totals.onDisk))")
                    .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.55)).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.06))
        // The header shares the title bar's row with close / minimise / zoom.
        .ignoresSafeArea()
        .task { await load() }
        .onAppear(perform: openAsAsked)
        // Every request to open it (the queue, a session) chooses the tab again.
        .onChange(of: model.historyRequest) { openAsAsked() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in Task { await load() } }
    }

    // MARK: Data

    private func load() async {
        let all = await model.store.list(.init()).annotations
            .sorted { ($0["created_at"]?.string ?? "") > ($1["created_at"]?.string ?? "") }
        let latest = Array(all.prefix(400))
        if latest.map(\.fields) != annotations.map(\.fields) { annotations = latest }
    }

    private func act(_ work: @escaping () async -> Void) {
        Task {
            await work()
            await load()
            await model.refresh()
        }
    }

    private var filtered: [Annotation] {
        annotations.filter { a in
            (session == nil || sessionKey(a) == session)
                && (agent == nil || agentOf(a) == agent)
                && (app == nil || appOf(a) == app)
                && (project == nil || a["worktree"]?.string == project)
                && matches(a)
                && (show == .all || (show == .pending ? a.status != "completed" : a.status == "completed"))
        }
    }

    private var days: [String] {
        var seen = Set<String>()
        return filtered.map(dayKey).filter { seen.insert($0).inserted }
    }

    private struct SessionChip { let id: String; let name: String; let number: Int?; let identity: SessionIdentity }

    private var sessions: [SessionChip] {
        var seen = Set<String>()
        return annotations.compactMap { a -> SessionChip? in
            let key = sessionKey(a)
            guard seen.insert(key).inserted else { return nil }
            return SessionChip(id: key, name: name(of: a), number: number(of: a), identity: SessionIdentity(annotation: a, terminal: terminal(of: a)))
        }
        .sorted { ($0.number ?? 99) < ($1.number ?? 99) }
    }

    private func sessionBytes(_ key: String) -> Int {
        annotations.filter { sessionKey($0) == key }.reduce(0) { $0 + HistorySize.of($1) }
    }

    /// Everything sent (in the list), and what of it still sits on this Mac.
    private var totals: (sent: Int, onDisk: Int64) {
        (annotations.reduce(0) { $0 + HistorySize.of($1) }, model.diskUsage.imageBytes)
    }

    private func sessionKey(_ a: Annotation) -> String {
        a["session_id"]?.string ?? a["worktree"]?.string ?? "-"
    }

    private func agentOf(_ a: Annotation) -> AgentSession.Agent? {
        SessionIdentity(annotation: a, terminal: terminal(of: a)).agent
    }

    /// The AIs the marks went to, in a fixed order.
    private var agents: [AgentSession.Agent] {
        let found = Set(annotations.compactMap(agentOf))
        return AgentSession.Agent.allCases.filter(found.contains)
    }

    /// What the opening asked for: a session's marks, or everything (the queue is always on top).
    private func openAsAsked() {
        session = model.historySession
    }

    private func count(_ option: Show) -> Int {
        return annotations.filter { option == .all || (option == .pending ? $0.status != "completed" : $0.status == "completed") }.count
    }

    private func matches(_ a: Annotation) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let hay = [a["comment"]?.string, a["selected_text"]?.string, a["url"]?.string, a["selector"]?.string,
                   a["element_context"]?.object?["text"]?.string, name(of: a)]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return hay.contains(q)
    }

    private func appOf(_ a: Annotation) -> String? {
        SessionIdentity(annotation: a, terminal: terminal(of: a)).appBundleID
    }

    /// The apps the sessions ran in, most used first.
    private var apps: [String] {
        let all = annotations.compactMap(appOf)
        return Array(Set(all)).sorted { a, b in all.filter { $0 == a }.count > all.filter { $0 == b }.count }
    }

    private func appName(_ bundle: String) -> String? {
        annotations.lazy.map { SessionIdentity(annotation: $0, terminal: self.terminal(of: $0)) }
            .first { $0.appBundleID == bundle }?.appName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The projects (worktrees) marked in, most used first.
    private var projects: [String] {
        let all = annotations.compactMap { $0["worktree"]?.string }
        return Array(Set(all)).sorted { a, b in all.filter { $0 == a }.count > all.filter { $0 == b }.count }
    }

    private func projectName(_ worktree: String) -> String { URL(filePath: worktree).lastPathComponent }

    @ViewBuilder private func agentIcon(_ value: AgentSession.Agent?) -> some View {
        if let value { AgentGlyphView(agent: value, size: 11) } else { Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)) }
    }

    @ViewBuilder private func appIcon(_ bundle: String?) -> some View {
        if let bundle { TerminalAppIcon(bundleID: bundle, size: 12) } else { Image(systemName: "macwindow").font(.system(size: 10, weight: .semibold)) }
    }

    private func agentChip(_ value: AgentSession.Agent?) -> some View {
        let on = agent == value
        return Button { withAnimation(.easeOut(duration: 0.15)) { agent = value } } label: {
            HStack(spacing: 5) {
                if let value {
                    AgentGlyphView(agent: value, size: 11)
                    Text(value.displayName)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                    Text(L10n.t("All AIs"))
                }
            }
            .font(.system(size: 10.5, weight: on ? .bold : .medium))
            .foregroundStyle(on ? .black : .white.opacity(0.75))
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .hoverLift()
    }

    private func terminal(of a: Annotation) -> AgentTerminal? {
        guard let id = a["session_id"]?.string else { return nil }
        return model.terminals.first { $0.id == id }
    }

    private func name(of a: Annotation) -> String {
        if let terminal = terminal(of: a) { return terminal.name }
        if let name = a["session_name"]?.string, !name.isEmpty { return name }
        return a["worktree"]?.string.map { URL(filePath: $0).lastPathComponent } ?? L10n.t("closed session")
    }

    private func number(of a: Annotation) -> Int? {
        terminal(of: a).flatMap { model.number(of: $0.id) }
    }

    /// The day in this Mac's time zone ("2026-10-03").
    private func dayKey(_ a: Annotation) -> String {
        HistoryDate.parse(a["created_at"]?.string).map { AnnotationStore.dayKey($0) } ?? ""
    }

    private func dayTitle(_ key: String) -> String {
        if key == AnnotationStore.dayKey() { return L10n.t("Today") }
        if key == AnnotationStore.dayKey(Date().addingTimeInterval(-86_400)) { return L10n.t("Yesterday") }
        return key
    }

    private func chip(_ id: String?, title: String, hue: Color, number: Int?, identity: SessionIdentity? = nil) -> some View {
        let on = session == id
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { session = id }
        } label: {
            HStack(spacing: 4) {
                if let number {
                    Text("\(number)").font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black).frame(width: 13, height: 13).background(Circle().fill(hue))
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let identity {
                        SessionIdentityView(identity: identity, size: 10)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    Text(title).font(.system(size: 10, weight: on ? .bold : .medium)).lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(on ? .white : .white.opacity(0.6))
            .padding(.horizontal, 9).frame(height: identity == nil ? 24 : 38)
            .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.05)))
            .overlay(Capsule().strokeBorder(on ? hue.opacity(0.8) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}

private struct HistoryRow: View {
    let annotation: Annotation
    let name: String
    let number: Int?
    let identity: SessionIdentity
    /// Open sessions to move it to, with their numbers.
    let sessions: [(AgentTerminal, Int?)]
    let move: (AgentTerminal) -> Void
    let resolve: () -> Void
    let delete: () -> Void
    let resend: (() -> Void)?
    @State private var hovered = false

    private var done: Bool { annotation.status == "completed" }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(number.map(String.init) ?? "·")
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 15, height: 15)
                .background(Circle().fill(AkiPalette.hue(number: number)))
                .opacity(done ? 0.5 : 1)
            if let image = AnnotationImage.file(for: annotation).flatMap({ NSImage(contentsOf: $0) }) {
                Button { ImageZoom.show(image) } label: {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 34, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(done ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
                .help(L10n.t("See it bigger"))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(comment).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(done ? 0.45 : 0.92))
                    .strikethrough(done, color: .white.opacity(0.35)).lineLimit(2)
                // Icons for the AI and the app (names on hover), then the session.
                HStack(spacing: 6) {
                    SessionIdentityView(identity: identity, size: 12, showAppName: false, showAgentName: false)
                    Text(name).lineLimit(1)
                    if let worktree = annotation["worktree"]?.string {
                        Text("· " + URL(filePath: worktree).lastPathComponent).lineLimit(1).opacity(0.6)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(done ? 0.65 : 0.85))
                Text(details).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovered {
                HStack(spacing: 3) {
                    if !done {
                        // Another terminal: the mark moves there (and goes to it if sending by itself is on).
                        Menu {
                            let others = sessions.filter { $0.0.id != annotation["session_id"]?.string }
                            ForEach(others.filter { $0.1 != nil }, id: \.0.id) { t, n in
                                Button { move(t) } label: {
                                    SessionMenuLabel(terminal: t, title: "\(n ?? 0)  \(t.agent.displayName) · \(t.name)")
                                }
                            }
                            let rest = others.filter { $0.1 == nil }
                            if !rest.isEmpty {
                                Divider()
                                ForEach(rest, id: \.0.id) { t, _ in
                                    Button { move(t) } label: {
                                        SessionMenuLabel(terminal: t, title: "\(t.agent.displayName) · \(t.name) — \(URL(filePath: t.worktree).lastPathComponent)")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.14)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .hoverLift()
                        .help(L10n.t("Move to another terminal"))
                    }
                    if !done, let resend { iconButton("paperplane.fill", L10n.t("Send to the terminal now"), resend) }
                    if !done { iconButton("checkmark", L10n.t("Mark as done"), resolve) }
                    iconButton("trash", L10n.t("Delete"), delete)
                }
            } else if done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.green.opacity(0.8))
                    .help(L10n.t("Done marks"))
            } else {
                Circle().fill(Color.white.opacity(0.7)).frame(width: 6, height: 6).padding(.trailing, 3)
                    .help(L10n.t("Pending"))
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovered ? 0.07 : 0)))
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
    }

    private var comment: String {
        let text = annotation["comment"]?.string ?? ""
        return text.isEmpty ? L10n.t("(no comment)") : text
    }

    private var details: String {
        var parts: [String] = []
        if let selector = annotation["selector"]?.string, !selector.isEmpty { parts.append(selector) }
        if let url = annotation["url"]?.string, let host = URL(string: url)?.host() { parts.append(host) }
        else if let app = annotation["app"]?.object?["name"]?.string { parts.append(app) }
        if let date = HistoryDate.parse(annotation["created_at"]?.string) {
            parts.append(date.formatted(date: .omitted, time: .shortened))
        }
        parts.append(Bytes.text(Int64(HistorySize.of(annotation))))
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .help(help)
    }
}

enum HistoryDate {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }
}

/// Lifts and brightens a little under the pointer, with the hand cursor.
private struct HoverLift: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .brightness(hovered ? 0.15 : 0)
            .scaleEffect(hovered ? 1.07 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovered)
            .onHover { inside in
                hovered = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }
}

extension View {
    fileprivate func hoverLift() -> some View { modifier(HoverLift()) }
}

/// What a mark weighed when it was sent (stored with it; older ones measured now).
enum HistorySize {
    static func of(_ a: Annotation) -> Int {
        if let n = a["size_bytes"]?.double { return Int(n) }
        return AnnotationStore.sizeInBytes(a)
    }
}

/// One filter of the history: a pill with an icon and what's chosen; a click lists
/// the options, the × (when something is chosen) goes back to all.
private struct FilterMenu<Icon: View, Items: View>: View {
    @ViewBuilder let icon: () -> Icon
    let title: String
    let active: Bool
    let clear: () -> Void
    @ViewBuilder let items: () -> Items
    @State private var hovered = false
    @State private var clearHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                items()
            } label: {
                HStack(spacing: 5) {
                    icon()
                    // A long project or session name is cut, so the row always fits.
                    Text(title.count > 20 ? title.prefix(19) + "…" : title).lineLimit(1)
                        .help(title)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
                }
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                // The label draws itself (a plain button style keeps these colours).
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            if active {
                Button(action: clear) {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(clearHovered ? Color.white : Color.black.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(clearHovered ? Color.black.opacity(0.75) : Color.black.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .onHover { clearHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: clearHovered)
                .help(L10n.t("Clear"))
            }
        }
        .padding(.horizontal, 9).frame(height: 26)
        .background(Capsule().fill(active ? Color.white : Color.white.opacity(hovered ? 0.13 : 0.07)))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// The marks saved but not sent yet (they wait for the next round of marking):
/// back to marking with them, drop one, or drop them all.
private struct QueueSection: View {
    let model: SidebarModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(AkiPalette.red))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(L10n.t("In the queue, not sent")) · \(model.queuedList.count)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    Text(L10n.t("They go to your agent when you send them."))
                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button { model.sendQueued(nil) } label: {
                    Label(model.queuedList.count > 1 ? "\(L10n.t("Send all")) (\(model.queuedList.count))" : L10n.t("Send"),
                          systemImage: "paperplane.fill")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .hoverLift()
                .help(L10n.t("Send them to their sessions now"))
                Button {
                    close()
                    model.resumeQueue()
                } label: {
                    Label(L10n.t("Keep marking"), systemImage: "scope")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .hoverLift()
                .help(L10n.t("Opens marking with the queue, to add more and send"))
                Button { model.clearQueue() } label: {
                    Label(L10n.t("Clear"), systemImage: "trash")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .hoverLift()
                .help(L10n.t("Clear the queue"))
            }
            ForEach(model.queuedList) { mark in
                HStack(spacing: 8) {
                    Text("\(mark.number)")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                        .frame(width: 15, height: 15).background(Circle().fill(AkiPalette.hue(number: mark.number)))
                    if let image = mark.image {
                        Button { ImageZoom.show(image) } label: {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 34, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
                        .help(L10n.t("See it bigger"))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mark.comment.isEmpty ? (mark.text ?? L10n.t("(no comment)")) : mark.comment)
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
                        // Where it goes: a menu of the sessions, to send it elsewhere.
                        Menu {
                            ForEach(model.markableTerminals) { terminal in
                                Button { model.moveQueued(mark.id, terminal.id) } label: {
                                    if terminal.id == mark.destination { Label(terminal.name, systemImage: "checkmark") } else { Text(terminal.name) }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if let id = mark.destination, let terminal = model.allTerminals.first(where: { $0.id == id }) {
                                    SessionIdentityView(identity: SessionIdentity(terminal: terminal), size: 11,
                                                        showAppName: false, showAgentName: false)
                                    Text(terminal.name).lineLimit(1)
                                } else {
                                    Text(L10n.t("Choose where it goes")).foregroundStyle(AkiPalette.red)
                                }
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                            }
                            .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help(L10n.t("Change where it goes"))
                    }
                    Spacer(minLength: 0)
                    Button { model.sendQueued(mark.id) } label: {
                        Image(systemName: "paperplane.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                    .help(L10n.t("Send only this one"))
                    Button { model.removeQueued(mark.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                    .help(L10n.t("Remove from the queue"))
                }
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(
            colors: [AkiPalette.red.opacity(0.16), AkiPalette.red.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AkiPalette.red.opacity(0.45), lineWidth: 1))
    }
}
