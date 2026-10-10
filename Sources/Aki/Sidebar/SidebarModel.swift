import AkiCore
import AppKit
import SwiftUI
import Observation

/// One ring: an agent (Claude, Codex) and the terminals it has open.
struct AgentGroup: Identifiable, Equatable {
    let agent: AgentSession.Agent
    /// Terminals shown in the sidebar (the ring's state comes from these).
    var sessions: [AgentSession]
    /// Terminals the user hid; listed in the card only on request.
    var hidden: [AgentSession] = []

    var id: String { agent.rawValue }
    var pending: Int { sessions.reduce(0) { $0 + $1.pending } }
    var working: Bool { sessions.contains(where: \.working) }
    var listening: Bool { sessions.contains(where: \.listening) }
}

/// What one ring in the sidebar stands for.
enum Ring: Identifiable, Equatable {
    case agent(AgentGroup)
    case terminal(AgentTerminal)
    /// Terminals past the limit, folded into one "+N" ring.
    case more([AgentTerminal])
    /// Sessions you hid, in one small ring at the end, to bring them back.
    case hidden([AgentTerminal])

    var id: String {
        switch self {
        case .agent(let group): "agent:" + group.id
        case .terminal(let terminal): "terminal:" + terminal.id
        case .more: "more"
        case .hidden: "hidden"
        }
    }

    var pending: Int {
        switch self {
        case .agent(let group): group.pending
        case .terminal(let terminal): terminal.pending
        case .more(let sessions): sessions.reduce(0) { $0 + $1.pending }
        case .hidden: 0
        }
    }
}

@MainActor @Observable
final class SidebarModel {
    enum ServerStatus: Equatable {
        case starting
        case listening(UInt16)
        case portBusy(UInt16)
        case failed(String)

        var label: String {
            switch self {
            case .starting: "Starting…"
            case .listening(let port): "127.0.0.1:\(port)"
            case .portBusy(let port): "Port \(port) in use by another Aki"
            case .failed(let message): "Server error: \(message)"
            }
        }
    }

    var sessions: [AgentSession] = []
    /// Every agent conversation open (Claude sessions, Codex processes).
    var terminals: [AgentTerminal] = []
    /// The conversation new marks go to.
    var selectedTerminal: String?
    /// Where new marks go: the chosen session while it can be marked for (hidden from
    /// the sidebar too: picked from "+N"), else the first one shown.
    /// The session you chose last (a ring, the marking's picker, where marks went last).
    /// Never guessed from activity: a session also starts working by itself (a task
    /// finishing, a notice), and a guess sent marks to the wrong terminal.
    var markingDestination: String? {
        if let id = selectedTerminal, markableTerminals.contains(where: { $0.id == id }) { return id }
        return visibleTerminals.first?.id
    }
    /// The scale the sidebar is drawn at (set by the controller: shrunk when the
    /// bar wouldn't fit the screen), so drawing and clicks agree.
    var layoutScale: CGFloat?
    /// A double-click is taking you to this conversation: its ring launches and
    /// the card says where.
    var jumping: (id: String, app: String)?
    /// Opens the marking overlay (set by the app).
    var startMarking: () -> Void = {}
    /// The first scan of the open sessions has finished.
    var loaded = false
    /// Called once the first list of sessions arrives (the sidebar opens then).
    var onLoaded: () -> Void = {}
    /// Opens the history, filtered to a session (set by the app).
    @ObservationIgnored var openHistory: (String?) -> Void = { _ in }
    /// Shows where a session's marks can go (set by the sidebar: a menu at the pointer).
    @ObservationIgnored var chooseMoveTarget: (AgentTerminal) -> Void = { _ in }
    /// Conversations that just received marks: their rings pulse.
    var flashed: Set<String> = []
    /// Sessions about to get the request: when the wait started and when it ends
    /// (the card counts down, the ring's arc runs out).
    var deliverAt: [String: (start: Date, end: Date)] = [:]
    /// Sessions whose agent just finished every mark: their ring flashes a ✓.
    var finished: Set<String> = []
    /// Sessions whose marks were just moved elsewhere: emptied, not finished.
    @ObservationIgnored private var movedFrom: Set<String> = []

    /// For a few seconds, that session emptying out is a move, not work done.
    private func noteMoved(_ id: String) {
        movedFrom.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.movedFrom.remove(id) }
    }
    var stats: AnnotationStore.Stats = [:]
    var expanded = false {
        didSet {
            guard expanded != oldValue else { return }
            // Settled: open and done moving (cards and corner arcs wait for it).
            settleWork?.cancel()
            if !expanded { settled = false; return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { if self?.expanded == true { self?.settled = true } }
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
        }
    }
    var settled = false
    @ObservationIgnored private var settleWork: DispatchWorkItem?
    /// Ring under the pointer while open; its card shows beside the sidebar.
    var hovered: Int?
    /// Ring clicked: its card stays open until clicked again or elsewhere.
    var pinned: Int?
    var orbHovered = false
    var gripHovered = false
    var markButtonHovered = false
    var historyButtonHovered = false
    /// The end of the card the pointer is at (0 start, 1 far end): its two
    /// corner buttons show; elsewhere they stay out of sight.
    var cornerEnd: Int?
    /// The pointer is over the sidebar (the corner arcs light up).
    var pointerInside = false
    /// The project name under the pointer (it shows it can be edited).
    var hoveredProject: String?
    /// The resize corner under the pointer, and while it's being dragged.
    var resizeHovered = false
    /// A new version waiting (announced, not downloaded): its pill shows by the bar.
    /// The update pill by the sidebar: a new version, its download, the restart.
    var update: UpdateState = .idle
    var resizing = false
    /// The session the history window is filtered to (nil = all).
    var historySession: String?
    /// The History opens on the queue (the menu's "See the queue").
    var historyOnQueue = false
    /// Counts each request to open the History, so the same request twice still lands.
    var historyRequest = 0
    var eyeHovered = false
    /// The project whose name is being typed, right over its group, and the text.
    var editingProject: String? {
        didSet { if editingProject == nil, oldValue != nil { onProjectEditEnded() } }
    }
    var projectDraft = ""
    /// The sidebar gives the keyboard back when a name is done.
    @ObservationIgnored var onProjectEditEnded: () -> Void = {}

    func commitProjectName() {
        guard let key = editingProject else { return }
        let name = projectDraft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.uppercased() == autoProjectLabel(key) { preferences.projectNames[key] = nil }
        else { preferences.projectNames[key] = name }
        editingProject = nil
    }
    var hideButtonHovered = false
    /// Clickable parts of the card, reported by the views (panel coordinates).
    var targets: [String: CGRect] = [:]
    /// The target under the pointer, if any.
    var hoveredTarget: String?
    /// Agents whose card lists hidden terminals too.
    var showingHidden: Set<String> = []
    /// Each click on the settings orb turns its gear once more.
    var settingsSpins = 0
    /// Worktree that new marks go to.
    var selected: String?
    var serverStatus: ServerStatus = .starting

    let store: AnnotationStore
    let preferences: Preferences
    private var refreshTask: Task<Void, Never>?

    init(store: AnnotationStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    /// One group per tracked agent, Claude first, even with no terminal open
    /// (its ring is then dimmed), as Codenotch keeps every provider's ring.
    var groups: [AgentGroup] {
        var result: [AgentGroup] = []
        for agent in AgentSession.Agent.allCases {
            guard preferences.tracks(agent) else { continue }
            let mine = sessions.filter { $0.agents.contains(agent) }
            // Claude and Codex always get a ring; others only once they're running.
            if mine.isEmpty && agent != .claude && agent != .codex { continue }
            let hidden = mine.filter { preferences.hiddenWorktrees.contains($0.worktree) }
            let shown = mine.filter { !preferences.hiddenWorktrees.contains($0.worktree) }
            result.append(AgentGroup(agent: agent, sessions: shown, hidden: hidden))
        }
        return result
    }

    /// Every open session of a tracked agent: the numbered ones first, then the
    /// hidden ones and those past the limit (by name). For moving marks anywhere.
    var allTerminals: [AgentTerminal] {
        let visible = visibleTerminals
        let ids = Set(visible.map(\.id))
        let rest = terminals.filter { !ids.contains($0.id) && preferences.tracks($0.agent) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return visible + rest
    }

    /// A session's colour: its project's when projects are shown (every ring of a
    /// project alike), else its own by number.
    func hue(of terminal: AgentTerminal) -> Color {
        guard preferences.showProjects else { return AkiPalette.hue(number: number(of: terminal.id)) }
        return projectHue(projectKey(of: terminal))
    }

    func hue(ofID id: String?) -> Color {
        guard let id, let terminal = terminals.first(where: { $0.id == id }) else { return Color.white.opacity(0.6) }
        return hue(of: terminal)
    }

    /// Each project its own colour, in the order the projects appear.
    func projectHue(_ key: String) -> Color {
        var keys: [String] = []
        for t in visibleTerminals where !keys.contains(projectKey(of: t)) { keys.append(projectKey(of: t)) }
        guard let i = keys.firstIndex(of: key) else { return Color.white.opacity(0.6) }
        return AkiPalette.sessionHues[i % AkiPalette.sessionHues.count]
    }

    /// A session's number (1, 2, 3…): its place in sidebar order. ⌘1–⌘9 picks it while marking.
    func number(of id: String) -> Int? {
        visibleTerminals.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Off in Settings: its agent untracked, its project switched off (Claude / Codex)
    /// or its terminal app disconnected (Terminals).
    private func switchedOff(_ terminal: AgentTerminal) -> Bool {
        preferences.hiddenWorktrees.contains(terminal.worktree)
            || !preferences.tracks(terminal.agent)
            || (TerminalApp.owner(of: terminal.pid)?.bundleIdentifier.map(preferences.disconnectedApps.contains) ?? false)
    }

    /// Every session you can mark for: the sidebar's, then the ones hidden from it.
    /// Hiding a ring tidies the sidebar; it doesn't take the session off the picker.
    var markableTerminals: [AgentTerminal] {
        visibleTerminals + terminals.filter { (preferences.hiddenTerminals.contains($0.id) || resting($0)) && !switchedOff($0) }
    }

    /// Untouched for more than two days, with nothing for it and not the destination:
    /// it waits in "+N" and comes back by itself when it moves again.
    func resting(_ t: AgentTerminal) -> Bool {
        guard let updated = t.updatedAt, Date().timeIntervalSince(updated) > 2 * 86_400 else { return false }
        return t.pending == 0 && t.id != selectedTerminal && t.state != .waiting && t.state != .working && t.state != .shell
    }

    /// Conversations of tracked agents that aren't hidden, in sidebar order.
    var visibleTerminals: [AgentTerminal] {
        let shown = terminals.filter { !preferences.hiddenTerminals.contains($0.id) && !switchedOff($0) && !resting($0) }
        // Your dragged order first; sessions you never moved keep their place after.
        let rank = Dictionary(preferences.ringOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = shown.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        // Sessions of one project side by side (its first session sets its place).
        guard preferences.showProjects else { return ordered }
        var projects: [String] = []
        for t in ordered where !projects.contains(projectKey(of: t)) { projects.append(projectKey(of: t)) }
        return projects.flatMap { key in ordered.filter { projectKey(of: $0) == key } }
    }

    /// The ring being dragged and how far along the edge it has moved (points).
    var dragging: (id: String, offset: CGFloat)?

    /// While dragging: where the dragged ring would land, as an index into `rings`
    /// (kept among the session rings), given the distance between rings.
    func proposedIndex(step: CGFloat) -> Int? {
        guard let dragging, let from = rings.firstIndex(where: { $0.id == "terminal:" + dragging.id }) else { return nil }
        let slots = rings.indices.filter { if case .terminal = rings[$0] { return true } else { return false } }
        let moved = Int((dragging.offset / max(step, 1)).rounded())
        return min(max(from + moved, slots.first ?? from), slots.last ?? from)
    }

    /// Ring positions while dragging: the dragged one leaves its slot and the
    /// others close the gap and open one where it would land.
    func displayIndex(of index: Int, step: CGFloat) -> Int {
        if draggingProject != nil { return projectDisplayIndex(of: index, step: step) ?? index }
        guard let dragging, let from = rings.firstIndex(where: { $0.id == "terminal:" + dragging.id }),
            let to = proposedIndex(step: step), index != from
        else { return index }
        if from < to, index > from, index <= to { return index - 1 }
        if from > to, index >= to, index < from { return index + 1 }
        return index
    }

    /// The project being dragged by its name, and how far along the edge (points).
    var draggingProject: (key: String, offset: CGFloat)?

    /// Runs of session rings from one project, in sidebar order (indices into `rings`).
    func projectRuns() -> [(key: String, indices: [Int])] {
        var runs: [(key: String, indices: [Int])] = []
        for (i, ring) in rings.enumerated() {
            guard case .terminal(let t) = ring else { continue }
            let key = projectKey(of: t)
            if let last = runs.last, last.key == key, last.indices.last == i - 1 {
                runs[runs.count - 1].indices.append(i)
            } else {
                runs.append((key, [i]))
            }
        }
        return runs
    }

    /// While a project is dragged: the order its rings' groups would land in. It goes
    /// past a neighbour once its middle crosses the neighbour's middle.
    func proposedProjectOrder(step: CGFloat) -> [String]? {
        guard let draggingProject else { return nil }
        let runs = projectRuns()
        guard let dragged = runs.first(where: { $0.key == draggingProject.key }) else { return nil }
        func middle(_ indices: [Int]) -> CGFloat { CGFloat(indices.first! + indices.last!) / 2 }
        let moved = middle(dragged.indices) + draggingProject.offset / max(step, 1)
        var order = runs.filter { $0.key != dragged.key }
        let place = order.filter { middle($0.indices) < moved }.count
        order.insert(dragged, at: place)
        return order.map(\.key)
    }

    /// Where a ring sits while a project is dragged: the other groups slide over.
    private func projectDisplayIndex(of index: Int, step: CGFloat) -> Int? {
        guard let order = proposedProjectOrder(step: step) else { return nil }
        let runs = projectRuns()
        guard let start = runs.first?.indices.first else { return nil }
        var next = start
        for key in order {
            guard let run = runs.first(where: { $0.key == key }) else { continue }
            if let at = run.indices.firstIndex(of: index) { return next + at }
            next += run.indices.count
        }
        return nil
    }

    /// Puts a project's sessions, all together, in the order given and remembers it.
    func moveProjects(to order: [String]) {
        var keys = order
        for t in visibleTerminals where !keys.contains(projectKey(of: t)) { keys.append(projectKey(of: t)) }
        let ids = keys.flatMap { key in visibleTerminals.filter { projectKey(of: $0) == key }.map(\.id) }
        preferences.ringOrder = ids + preferences.ringOrder.filter { !ids.contains($0) }
    }

    /// Puts a session's ring at `index` among the visible ones and remembers it.
    func move(_ id: String, to index: Int) {
        var order = visibleTerminals.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: min(max(index, 0), order.count))
        preferences.ringOrder = order + preferences.ringOrder.filter { !order.contains($0) }
    }

    /// The sidebar's rings, per the "Rings" setting.
    var rings: [Ring] {
        switch preferences.ringMode {
        case .agents: return groups.map(Ring.agent)
        case .terminals:
            // Hidden sessions live in the "+N" ring, with the ones past the limit.
            let hidden = terminals.filter {
                (preferences.hiddenTerminals.contains($0.id) || (resting($0) && !switchedOff($0))) && preferences.tracks($0.agent)
            }
            let all = visibleTerminals
            let limit = max(2, preferences.maxTerminals)
            guard all.count > limit else { return all.map(Ring.terminal) + (hidden.isEmpty ? [] : [.more(hidden)]) }
            // The ones that need you or are busy get a ring (and the destination
            // always does); shown in their usual order so rings don't jump around.
            func activity(_ t: AgentTerminal) -> Int {
                var score = t.id == selectedTerminal ? 32 : 0
                if t.state == .waiting { score += 16 }
                if t.pending > 0 { score += 8 }
                if t.state == .working || t.state == .shell { score += 4 }
                if t.state == .listening { score += 2 }
                return score
            }
            let ranked = all.enumerated().sorted { a, b in
                activity(a.element) != activity(b.element) ? activity(a.element) > activity(b.element) : a.offset < b.offset
            }
            let kept = Set(ranked.prefix(limit - 1).map(\.element.id))
            return all.filter { kept.contains($0.id) }.map(Ring.terminal) + [.more(all.filter { !kept.contains($0.id) } + hidden)]
        }
    }

    /// Two letters that tell sessions apart: initials of the name's words, or its
    /// first two letters ("PHOTO EDITOR" → "PE", "DASHBOARD" → "DA").
    func monogram(for name: String) -> String {
        let words = name.split(whereSeparator: { "_-. ".contains($0) }).filter { !$0.isEmpty && $0.first!.isLetter }
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first) : Array(name.filter(\.isLetter).prefix(2))
        return String(letters).uppercased()
    }

    /// The project a conversation belongs to, as the sidebar names folders.
    /// The project a session belongs to: the closest numbered folder it lives under
    /// ("08_ACME_LEGACY" for a worktree deep inside it), else its own folder.
    func projectKey(of terminal: AgentTerminal) -> String {
        let parts = URL(filePath: terminal.worktree).pathComponents
        // The innermost one: "04_PROJETOS" above everything isn't a project.
        return parts.last { $0.range(of: #"^\d+_"#, options: .regularExpression) != nil } ?? parts.last ?? ""
    }

    /// A project's short name over its group of rings: no number, and without a
    /// first word every project shares ("ACME_LEGACY" → "LEGACY", "CHROME_EXTENSION" → "CHROME").
    func projectLabel(_ key: String) -> String {
        func words(_ k: String) -> [String] {
            k.replacingOccurrences(of: #"^\d+[_\-. ]+"#, with: "", options: .regularExpression)
                .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
        }
        if let given = preferences.projectNames[key], !given.isEmpty { return given.uppercased() }
        return autoProjectLabel(key)
    }

    /// The name a project gets by itself (see `projectLabel`).
    func autoProjectLabel(_ key: String) -> String {
        func words(_ k: String) -> [String] {
            k.replacingOccurrences(of: #"^\d+[_\-. ]+"#, with: "", options: .regularExpression)
                .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init)
        }
        var w = words(key)
        // A first word its sibling folders share ("ACME_" in 08_ACME_LEGACY,
        // 09_ACME_PAYMENTS…) says nothing: it goes.
        if w.count > 1, let terminal = terminals.first(where: { projectKey(of: $0) == key }) {
            var folder = URL(filePath: terminal.worktree)
            while folder.lastPathComponent != key, folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)) ?? []
            if siblings.filter({ words($0).first == w[0] }).count > 1 { w.removeFirst() }
        }
        return (w.first ?? key).uppercased()
    }

    func project(of terminal: AgentTerminal) -> String {
        let name = URL(filePath: terminal.worktree).lastPathComponent
        return name.replacingOccurrences(of: #"^\d+[_\-. ]+"#, with: "", options: .regularExpression)
    }

    /// The app the conversation runs in ("Orca", "Warp"…), when found.
    func appName(of terminal: AgentTerminal) -> String? {
        TerminalApp.owner(of: terminal.pid)?.localizedName
    }

    func appIcon(of terminal: AgentTerminal) -> NSImage? {
        TerminalApp.owner(of: terminal.pid)?.icon
    }

    func select(_ terminal: AgentTerminal) {
        selectedTerminal = terminal.id
        selected = terminal.worktree
    }

    /// After a restart: marks sent in the last day that never reached their
    /// terminal (Aki closed before it typed the request) go out again.
    func resumeDeliveries() async {
        await refresh()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let since = Date().addingTimeInterval(-24 * 3600)
        let pending = await store.list(.init(status: "pending")).annotations
        let waiting = pending.filter { a in
            guard a["delivered_at"]?.string == nil, a["read_at"]?.string == nil,
                  let text = a["created_at"]?.string, let date = iso.date(from: text) ?? plain.date(from: text)
            else { return false }
            return date > since
        }
        let ids = Set(terminals.filter { t in
            waiting.contains { a in
                a["session_id"]?.string == t.id || (a["session_id"] == nil && a["worktree"]?.string == t.worktree)
            }
        }.map(\.id))
        if !ids.isEmpty { deliverLater(to: Array(ids)) }
    }

    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                await self?.refreshStates()
                self?.followOrcaFocus()
            }
        }
    }

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The Orca tab last seen in focus: the destination changes only when you click
    /// another tab, so a choice made on the sidebar holds until then.
    @ObservationIgnored private var lastOrcaTab: String?

    /// Clicking an agent's tab in Orca makes it the destination. Any other tab, app or
    /// doubt (two sessions with that name) leaves the destination as it was.
    private func followOrcaFocus() {
        guard preferences.followOrcaTab, let title = OrcaFocus.focusedTabTitle() else { return }
        // The name without the status sign in front (✳ resting, a spinner working): a
        // session starting to work isn't you clicking its tab.
        let wanted = TerminalJump.normalized(title)
        guard wanted != lastOrcaTab else { return }
        let matches = markableTerminals.filter { $0.orcaHandle != nil && TerminalJump.normalized($0.name) == wanted }
        // A tab with no session (yet): noted as passed through ("?"), so coming back to
        // the one before counts as a click; a session that appears for it is picked then.
        guard matches.count == 1 else {
            lastOrcaTab = "?" + wanted
            return
        }
        lastOrcaTab = wanted
        if selectedTerminal != matches[0].id { selectedTerminal = matches[0].id }
    }

    /// Claude Code writes its state (working, waiting for you, idle) to its session
    /// file the moment it changes: reading those small files is cheap, so rings and
    /// the marking picker follow within half a second. The full scan stays every 3 s.
    private func refreshStates() async {
        let live = await Task.detached { ClaudeSessions.live() }.value
        var updated = terminals
        var changed = false
        for session in live {
            guard let i = updated.firstIndex(where: { $0.id == session.sessionId }) else { continue }
            var state: AgentTerminal.State = switch session.status {
            case .waiting: .waiting
            case .busy: .working
            case .shell: .shell
            default: updated[i].state == .listening ? .listening : .idle
            }
            // "Running a command" (or busy) long after Orca's tab went back to "✳": a
            // background task, the conversation itself is waiting for you.
            if state == .working || state == .shell, TerminalJump.restsByTab(updated[i], since: session.updatedAt) == true {
                state = .idle
            }
            if updated[i].state != state {
                updated[i].state = state
                changed = true
            }
        }
        if changed { terminals = updated }
    }

    /// Claude Code's status per session (context, limits), from the status line.
    var claudeStatus: [String: ClaudeStatus] = [:]
    @ObservationIgnored private var lastCleanup = Date.distantPast
    /// Marks saved in the marking queue but not sent yet (shown on the pill).
    var queuedMarks = 0
    /// The marks saved but not sent (they wait for the next round of marking),
    /// as the History shows them.
    var queuedList: [QueuedMark] = []
    /// History's queue buttons: back to marking with it, drop one, drop them all.
    var resumeQueue: () -> Void = {}
    var removeQueued: (UUID) -> Void = { _ in }
    var clearQueue: () -> Void = {}
    /// Send the queue (nil) or one mark of it, and change where one goes.
    var sendQueued: (UUID?) -> Void = { _ in }
    var moveQueued: (UUID, String) -> Void = { _, _ in }
    /// Marking is on screen (the sidebar keeps its hands off the cursor).
    @ObservationIgnored var marking = false
    /// Bytes and marks sent to each session (by session id).
    var sentBySession: [String: (bytes: Int, marks: Int)] = [:]
    var accountLimits: ClaudeStatus? { ClaudeStatus.latestLimits(in: claudeStatus) }

    /// Room Aki's pictures take on this Mac (measured on each refresh).
    var diskUsage = DiskUsage()

    /// Deletes the pictures no waiting mark needs.
    func cleanImages() {
        Task {
            let pending = await store.list(.init(status: "pending")).annotations
            await Task.detached { DiskUsage.clean(pending: pending) }.value
            await refresh()
        }
    }

    func refresh() async {
        let pending = await store.list(.init(status: "pending")).annotations
        let (found, scanned, usage) = await Task.detached {
            (AgentSessions.scan(pending: pending), AgentSessions.terminals(pending: pending),
             DiskUsage.measure(pending: pending))
        }.value
        let open = await Task.detached { TerminalJump.namedTerminals(scanned) }.value
        if usage != diskUsage { diskUsage = usage }
        // Housekeeping, at most once an hour: old done marks go, pictures stay under the limit.
        if Date().timeIntervalSince(lastCleanup) > 3600 {
            lastCleanup = Date()
            _ = try? await store.forgetDone(olderThan: preferences.keepDays)
            let maxBytes = Int64(preferences.maxPicturesMB) * 1_000_000
            await Task.detached { DiskUsage.trim(toMax: maxBytes, pending: pending) }.value
        }
        // What each session has been sent so far (all its marks, done or not).
        let everything = await store.list(.init()).annotations
        var sizes: [String: (bytes: Int, marks: Int)] = [:]
        for a in everything {
            let key = a["session_id"]?.string ?? a["worktree"]?.string ?? ""
            let size = a["size_bytes"]?.double.map(Int.init) ?? AnnotationStore.sizeInBytes(a)
            sizes[key, default: (0, 0)].bytes += size
            sizes[key, default: (0, 0)].marks += 1
        }
        if sizes.mapValues({ [$0.bytes, $0.marks] }) != sentBySession.mapValues({ [$0.bytes, $0.marks] }) { sentBySession = sizes }
        let statuses = await Task.detached { ClaudeStatus.all() }.value
        if statuses != claudeStatus { claudeStatus = statuses }
        // Every mark of a session resolved by its agent: a ✓ on its ring.
        for terminal in open where terminal.pending == 0 && !movedFrom.contains(terminal.id) {
            if let before = terminals.first(where: { $0.id == terminal.id }), before.pending > 0 {
                finished.insert(terminal.id)
                let id = terminal.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finished.remove(id) }
            }
        }
        if open != terminals { terminals = open }
        if !loaded {
            loaded = true
            onLoaded()
        }
        if let id = selectedTerminal, !open.contains(where: { $0.id == id }) { selectedTerminal = nil }
        let latest = await store.stats()
        if found != sessions { sessions = found }
        if latest != stats { stats = latest }
        if let selected, !found.contains(where: { $0.worktree == selected }) { self.selected = nil }
        if let hovered, hovered >= rings.count { self.hovered = nil }
        if let pinned, pinned >= rings.count { self.pinned = nil }
    }

    /// Folder name without a numeric prefix ("06_DASHBOARD" → "DASHBOARD"); when two
    /// worktrees would show the same label, the branch tells them apart.
    func label(for session: AgentSession) -> String {
        let base = Self.shortName(session.name)
        let clash = sessions.contains { $0.worktree != session.worktree && Self.shortName($0.name) == base }
        if clash, let branch = session.branch { return "\(base) · \(branch)" }
        return base
    }

    private static func shortName(_ name: String) -> String {
        let trimmed = name.replacingOccurrences(of: #"^\d+[_\-. ]+"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Counts for some worktrees: today, and marks per day for the last `days`.
    func counts(for worktrees: Set<String>, days: Int = 30) -> (today: AnnotationStore.Counts, daily: [Int]) {
        func sum(_ day: String) -> AnnotationStore.Counts {
            (stats[day] ?? [:]).filter { worktrees.contains($0.key) }.values.reduce(AnnotationStore.Counts(), +)
        }
        let calendar = Calendar.current
        let daily = (0..<days).reversed().map { offset -> Int in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            return sum(AnnotationStore.dayKey(date)).marks
        }
        return (sum(AnnotationStore.dayKey()), daily)
    }

    /// The smallest target under `point` (so the eye wins over its row).
    func target(at point: CGPoint) -> String? {
        targets.filter { $0.key != "card" && $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
    }

    /// Runs a click on a target. Returns false when there was nothing to do.
    func perform(_ target: String) -> Bool {
        let parts = target.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        switch parts[0] {
        case "row":
            guard let session = sessions.first(where: { $0.worktree == parts[1] }),
                !preferences.hiddenWorktrees.contains(session.worktree) else { return true }
            // The card it was clicked in says which agent (Claude and Codex can share a folder).
            let open = (pinned ?? hovered).flatMap { $0 < rings.count ? rings[$0] : nil }
            if case .agent(let group)? = open { select(session, agent: group.agent) } else { select(session) }
        case "eye":
            guard let session = sessions.first(where: { $0.worktree == parts[1] }) else { return true }
            toggleHidden(session)
        case "mark":
            if let terminal = terminals.first(where: { $0.id == parts[1] }) { select(terminal) }
            pinned = nil
            hovered = nil
            startMarking()
        case "history":
            pinned = nil
            hovered = nil
            openHistory(parts[1])
        case "move":
            if let terminal = terminals.first(where: { $0.id == parts[1] }) { chooseMoveTarget(terminal) }
        case "term":
            if let terminal = terminals.first(where: { $0.id == parts[1] }) { select(terminal) }
        case "hide":
            if preferences.hiddenTerminals.contains(parts[1]) { preferences.hiddenTerminals.remove(parts[1]) }
            else { preferences.hiddenTerminals.insert(parts[1]) }
        case "deliver":
            if let terminal = terminals.first(where: { $0.id == parts[1] }) { deliver(terminal) }
        case "queue":
            break
        case "unhideall":
            preferences.hiddenTerminals.removeAll()
        case "more":
            if showingHidden.contains(parts[1]) { showingHidden.remove(parts[1]) } else { showingHidden.insert(parts[1]) }
        default:
            return false
        }
        return true
    }

    func toggleHidden(_ session: AgentSession) {
        if preferences.hiddenWorktrees.contains(session.worktree) {
            preferences.hiddenWorktrees.remove(session.worktree)
        } else {
            preferences.hiddenWorktrees.insert(session.worktree)
        }
    }

    func select(_ session: AgentSession, agent: AgentSession.Agent? = nil) {
        selected = session.worktree
        // Marking goes by terminal: the latest one open in that folder (of that agent).
        // Resting sessions count too (a project shown only by its older ones).
        if let terminal = markableTerminals.filter({ $0.worktree == session.worktree && (agent == nil || $0.agent == agent) })
            .max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) {
            selectedTerminal = terminal.id
        }
    }

    /// Marks every pending mark aimed at this conversation as resolved.
    func resolveAll(in terminal: AgentTerminal) {
        Task {
            let pending = await store.list(.init(status: "pending")).annotations
            for annotation in pending
            where annotation["session_id"]?.string == terminal.id
                || (annotation["session_id"] == nil && annotation["worktree"]?.string == terminal.worktree)
            {
                _ = try? await store.update(annotation.id, with: ["status": "completed"])
            }
            await refresh()
        }
    }

    /// Sessions waiting to get the request (see `deliverLater`).
    @ObservationIgnored private var waits: [String: Task<Void, Never>] = [:]
    /// Where "Send to the terminal now" stands for each session.
    var delivery: [String: DeliveryState] = [:]
    enum DeliveryState { case sending, sent, failed }

    /// Types the request into the session's tab now.
    func deliver(_ terminal: AgentTerminal) {
        guard delivery[terminal.id] != .sending else { return }
        delivery[terminal.id] = .sending
        Task {
            // The marks this request is about, taken before it goes: any arriving
            // meanwhile still count as not delivered (their own wait sends them).
            // One look at the store for both: the message names exactly the marks
            // then recorded as delivered (a mark arriving later waits for its own).
            let pending = await pendingMarks(of: terminal)
            let waiting = pending.filter { $0["delivered_at"]?.string == nil }.map(\.id)
            var current = terminal
            current.pendingIDs = pending.sorted { ($0["created_at"]?.string ?? "") < ($1["created_at"]?.string ?? "") }.map(\.id)
            let result = await TerminalJump.deliver(to: current)
            delivery[terminal.id] = result == .sent ? .sent : .failed
            if result == .sent { await markDelivered(waiting, for: terminal) }
            try? await Task.sleep(for: .seconds(3))
            delivery[terminal.id] = nil
        }
    }

    /// Written on the marks themselves, so a restart still knows they went.
    private func markDelivered(_ ids: [String], for terminal: AgentTerminal) async {
        let now = ISO8601DateFormatter().string(from: Date())
        let wanted = Set(ids)
        // Still this session's (one moved elsewhere meanwhile waits for its new one).
        for annotation in await store.list(.init(status: "pending")).annotations where wanted.contains(annotation.id)
            && (annotation["session_id"]?.string == terminal.id
                || (annotation["session_id"] == nil && annotation["worktree"]?.string == terminal.worktree)) {
            _ = try? await store.update(annotation.id, with: ["delivered_at": .string(now)])
        }
        await refresh()
    }

    private func undeliveredIDs(of terminal: AgentTerminal) async -> [String] {
        await pendingMarks(of: terminal).filter { $0["delivered_at"]?.string == nil }.map(\.id)
    }

    /// The session's pending marks, as the store has them now.
    private func pendingMarks(of terminal: AgentTerminal) async -> [Annotation] {
        await store.list(.init(status: "pending")).annotations.filter { annotation in
            annotation["session_id"]?.string == terminal.id
                || (annotation["session_id"] == nil && annotation["worktree"]?.string == terminal.worktree)
        }
    }

    /// After a send: once you've stopped for the chosen seconds, each session
    /// gets the request — right away if it's free, else when it stops working.
    func deliverLater(to ids: [String], now: Bool = false) {
        guard preferences.autoDeliver || now else { return }
        if now {
            for id in ids { waits[id]?.cancel(); waits[id] = nil; deliverAt[id] = nil }
            Task {
                // "Send now": straight into each session's tab, busy or not (Claude
                // Code keeps a message typed while it works and reads it next).
                await refresh()
                for id in ids { if let terminal = terminals.first(where: { $0.id == id }) { deliver(terminal) } }
            }
            return
        }
        // One wait per session, started over each time marks arrive: the request
        // goes once, after the last of them, and only if some still haven't gone.
        for id in ids {
            waits[id]?.cancel()
            let wait = Double(preferences.waitIdleSeconds)
            deliverAt[id] = (Date(), Date().addingTimeInterval(wait))
            waits[id] = Task { [weak self] in
                defer { if !Task.isCancelled { self?.deliverAt[id] = nil } }
                try? await Task.sleep(for: .seconds(wait))
                // As long as marks wait: an agent busy for an hour still gets them after.
                while true {
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh()
                    // Started over (new marks) or sent by hand while refreshing.
                    guard !Task.isCancelled else { return }
                    // Turned off meanwhile: nothing goes by itself.
                    guard self.preferences.autoDeliver else { break }
                    guard let terminal = self.terminals.first(where: { $0.id == id }), terminal.undelivered > 0 else { break }
                    if terminal.state != .working && terminal.state != .shell {
                        self.deliver(terminal)
                        break
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
                if !Task.isCancelled { self?.waits[id] = nil }
            }
        }
    }

    /// One mark to another session; it's sent there like a fresh one.
    func moveMark(_ id: String, to target: AgentTerminal) async {
        if let source = await store.list(.init(status: "pending")).annotations.first(where: { $0.id == id })?["session_id"]?.string {
            noteMoved(source)
        }
        var fields = target.identityFields
        fields.merge(["session_id": .string(target.id), "worktree": .string(target.worktree),
                      "delivered_at": .null, "read_at": .null]) { _, new in new }
        _ = try? await store.update(id, with: fields)
        await refresh()
        deliverLater(to: [target.id])
    }

    /// Hands a session's waiting marks to another one (its queue moves over).
    func moveMarks(from source: AgentTerminal, to target: AgentTerminal) {
        noteMoved(source.id)
        Task {
            let pending = await store.list(.init(status: "pending")).annotations
            for annotation in pending
            where annotation["session_id"]?.string == source.id
                || (annotation["session_id"] == nil && annotation["worktree"]?.string == source.worktree)
            {
                var fields = target.identityFields
                fields.merge(["session_id": .string(target.id), "worktree": .string(target.worktree),
                              "delivered_at": .null, "read_at": .null]) { _, new in new }
                _ = try? await store.update(annotation.id, with: fields)
            }
            await refresh()
            deliverLater(to: [target.id])
        }
    }

    func resolveAll(in session: AgentSession) {
        Task {
            let pending = await store.list(.init(status: "pending")).annotations
            for annotation in pending where annotation["worktree"]?.string == session.worktree {
                _ = try? await store.update(annotation.id, with: ["status": "completed"])
            }
            await refresh()
        }
    }
}

/// A mark waiting in the queue, as listed outside marking.
struct QueuedMark: Identifiable, Equatable {
    let id: UUID
    let number: Int
    let comment: String
    let text: String?
    let destination: String?
    let image: NSImage?
}
