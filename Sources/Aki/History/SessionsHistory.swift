import AkiCore
import SwiftUI

/// The History's two sides: the marks, and the conversations of the last week.
enum HistoryTab { case marks, sessions }

/// "Marks · Sessions", at the top of the History.
struct HistoryTabs: View {
    @Binding var tab: HistoryTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach([HistoryTab.marks, .sessions], id: \.self) { option in
                let on = tab == option
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = option } } label: {
                    Text(L10n.t(option == .marks ? "Marks" : "Sessions"))
                        .font(.system(size: 11, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? .black : .white.opacity(0.65))
                        .padding(.horizontal, 9).frame(height: 21)
                        .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.001)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// The last 7 days' conversations (Claude Code in a terminal or in the Claude app,
/// Codex), open or closed, like Orca's session history: open ones go to their place,
/// closed ones come back in a new Orca tab (or a new Code session of the Claude app).
struct SessionsHistoryView: View {
    let model: SidebarModel
    @Binding var tab: HistoryTab

    @State private var entries: [SessionHistory.Entry]?
    @State private var query = ""
    @State private var notice: String?
    /// Open Codex conversations: their log's id → their terminal (Codex names them by process).
    @State private var codexOpen: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Room for close / minimise / zoom.
                Color.clear.frame(width: 62, height: 1)
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AkiPalette.auroraDiagonal)
                Text(L10n.t("History")).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                HistoryTabs(tab: $tab)
                Spacer()
                Text(L10n.t("Last 7 days")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                TextField(L10n.t("Search sessions"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.white)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
            .frame(maxWidth: 260)
            if let notice {
                Text(notice).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let entries {
                if shown(entries).isEmpty {
                    Spacer()
                    Text(L10n.t("No conversations in the last 7 days.")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                            ForEach(days(shown(entries)), id: \.self) { day in
                                Section {
                                    ForEach(shown(entries).filter { dayKey($0.updated) == day }) { entry in row(entry) }
                                } header: {
                                    Text(dayTitle(day).uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6)
                                        .foregroundStyle(.white.opacity(0.4))
                                        .padding(.top, 4).padding(.bottom, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(white: 0.06))
                                }
                            }
                        }
                        .padding(.trailing, 12)
                    }
                }
            } else {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("Loading sessions…")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.06))
        .ignoresSafeArea()
        // Read once when the tab opens (off the main thread), then every half minute.
        .task {
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { SessionHistory.recent() }.value
                if found != entries { entries = found }
                // Codex in terminals (the Codex app can't be taken to one conversation: its
                // ones stay "Resume", in a terminal).
                let codex = model.terminals.filter { $0.agent == .codex && DesktopApps.bundleID(of: $0.id) == nil }
                let byLog = await Task.detached(priority: .utility) { () -> [String: String] in
                    let logs = CodexSessions.openLogs(of: codex.map(\.pid))
                    var ids: [String: String] = [:]
                    for terminal in codex {
                        for log in logs[terminal.pid] ?? [] {
                            let uuid = log.deletingPathExtension().lastPathComponent.split(separator: "-").suffix(5).joined(separator: "-")
                            ids[uuid] = terminal.id
                        }
                    }
                    return ids
                }.value
                if byLog != codexOpen { codexOpen = byLog }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func row(_ entry: SessionHistory.Entry) -> some View {
        let open = model.terminals.first { $0.id == entry.id || $0.id == codexOpen[entry.id] }
        let folder = URL(filePath: entry.cwd).lastPathComponent
        return Button {
            if let open {
                model.open(open)
            } else {
                Task {
                    switch await model.resume(entry) {
                    case .orca: notice = L10n.t("Opened in a new Orca tab.")
                    case .newInApp: notice = L10n.t("A new Code session of that folder opened in the Claude app (it can't reopen an old one). The command to resume it is on the clipboard.")
                    case .copied: notice = L10n.t("Command copied: paste it in a terminal to resume the conversation.")
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                AgentGlyphView(agent: entry.agent, size: 13).foregroundStyle(.white.opacity(0.8)).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title ?? folder).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(folder) · \(entry.updated.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(L10n.t(open != nil ? "Open now" : "Resume"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(open != nil ? Color.black : Color.white.opacity(0.8))
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(open != nil ? Color.green.opacity(0.85) : Color.white.opacity(0.1)))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        }
        .buttonStyle(.plain)
        .hoverLift()
    }

    private func shown(_ list: [SessionHistory.Entry]) -> [SessionHistory.Entry] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return list }
        return list.filter { ($0.title ?? "").lowercased().contains(words) || $0.cwd.lowercased().contains(words) }
    }

    private func dayKey(_ date: Date) -> String { AnnotationStore.dayKey(date) }

    private func days(_ list: [SessionHistory.Entry]) -> [String] {
        var seen: [String] = []
        for entry in list where !seen.contains(dayKey(entry.updated)) { seen.append(dayKey(entry.updated)) }
        return seen
    }

    private func dayTitle(_ key: String) -> String {
        if key == AnnotationStore.dayKey() { return L10n.t("Today") }
        if key == AnnotationStore.dayKey(Date().addingTimeInterval(-86_400)) { return L10n.t("Yesterday") }
        return key
    }
}
