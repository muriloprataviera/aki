import AkiCore
import AppKit
import SwiftUI

/// Settings → Get started: every permission Aki asks the Mac for, why, whether
/// it's already given (checked live) and a button that goes straight there.
struct GetStartedPane: View {
    let openAgents: () -> Void

    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var access = AXIsProcessTrusted()
    @State private var browser: Bool?
    @State private var agent = false
    @State private var askedScreen = false

    private static func pane(_ name: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)")!
    }

    var body: some View {
        Form {
            Section {
                Text(L10n.t("A few minutes, once. Aki asks the Mac for a few permissions; here is each one, why, and a button that takes you there. Each turns green when it's done."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Where Aki lives, so nobody looks for it in the Dock or ⌘Tab.
            Section(L10n.t("Where Aki lives")) {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: AkiBrand.pin(size: 16)).renderingMode(.template).foregroundStyle(AkiPalette.red)
                    Text(L10n.t("Aki is always on: the bar at the edge of your screen and the pin in the menu bar. It's not in the Dock or ⌘Tab (it shows there while this window is open). Press {mark} to mark, {history} for the history, or search \"Aki\" in Spotlight to come back here. Want it in the Dock? General → App icon."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L10n.t("Needed")) {
                SetupStep(
                    number: 1, done: screen,
                    goal: L10n.t("To see what you mark"),
                    example: L10n.t("You circle a broken chart: your agent gets the picture. You mark an error in the terminal: it gets the text."),
                    permission: L10n.t("Screen Recording"),
                    why: L10n.t("macOS asks this of any app that looks at the screen. Nothing is recorded and nothing leaves your Mac."),
                    action: askedScreen && !screen ? L10n.t("Restart Aki") : L10n.t("Allow"),
                    help: askedScreen && !screen ? L10n.t("macOS applies this permission after Aki restarts.") : nil
                ) {
                    if askedScreen { Self.restart(); return }
                    askedScreen = true
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(Self.pane("Privacy_ScreenCapture"))
                }
                SetupStep(
                    number: 2, done: access,
                    goal: L10n.t("To point at buttons and rows in any app"),
                    example: L10n.t("You hover a folder in Finder or a layer in Figma: Aki outlines it, and your agent gets its name and what it is."),
                    permission: L10n.t("Accessibility"),
                    why: L10n.t("It's how Mac apps describe their buttons and lists to other apps."),
                    action: L10n.t("Allow")
                ) {
                    ElementProbe.askForAccess()
                    NSWorkspace.shared.open(Self.pane("Privacy_Accessibility"))
                }
                SetupStep(
                    number: 3, done: agent,
                    goal: L10n.t("To hand your marks to your agent"),
                    example: L10n.t("You press ⌘⏎ and Claude Code, in its terminal, reads \"Center the title\" with the exact element, then fixes it."),
                    permission: L10n.t("Aki's MCP server in Claude Code or Codex"),
                    why: L10n.t("It's how agents get new tools. One click; conversations already open see it after a restart."),
                    action: L10n.t("Open Agents"), reopen: L10n.t("Open Agents"), reopenIcon: "arrow.right.circle",
                    action: openAgents)
            }
            Section(L10n.t("For web pages (Chrome, Brave, Edge, Arc, Vivaldi)")) {
                SetupStep(
                    number: 4, done: browser ?? Preferences.shared.browserReady,
                    goal: L10n.t("To pick the exact element on a web page"),
                    example: L10n.t("You hover the Buy button on localhost:3000: your agent gets button.buy, its text and HTML, even the React file it comes from."),
                    permission: L10n.t("Allow JavaScript from Apple Events"),
                    why: L10n.t("In the browser's menu bar: View → Developer → Allow JavaScript from Apple Events. Then click Check and let Aki control the browser. No extension needed."),
                    action: L10n.t("Check"),
                    help: browser == false ? L10n.t("Not yet: turn it on in the browser's View → Developer menu, then check again.") : nil,
                    reopen: L10n.t("Check again"), reopenIcon: "arrow.clockwise"
                ) {
                    Task.detached {
                        let ok = BrowserProbe.canAskPages()
                        await MainActor.run {
                            browser = ok
                            // Kept: the ✓ stays after leaving the pane or restarting.
                            if let ok { Preferences.shared.browserReady = ok }
                        }
                    }
                }
                Link(L10n.t("Automation settings (if you said no to Aki controlling the browser)"),
                     destination: Self.pane("Privacy_Automation"))
                    .font(.caption)
            }
            Section(L10n.t("Try it")) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill").foregroundStyle(AkiPalette.red)
                    Text(L10n.t("Press {mark} anywhere, click something and write what should change. ⌘⏎ sends it to your agent."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Live: each step turns green as soon as it's given.
            // The agents' check runs their CLIs, so it goes every 10 s, not every 2.
            var tick = 0
            while !Task.isCancelled {
                screen = CGPreflightScreenCaptureAccess()
                access = AXIsProcessTrusted()
                if tick % 5 == 0, !agent {
                    let claude = await Setup.isConnected("claude")
                    let codex = claude ? false : await Setup.isConnected("codex")
                    agent = claude || codex
                }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Quits and opens Aki again (Screen Recording only applies to a fresh start).
    static func restart() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// One step, the way it reads best: what you get ("To see what you mark"), an
/// example, then the permission it takes and why, with the button that goes there.
private struct SetupStep: View {
    let number: Int
    let done: Bool
    let goal: String
    let example: String
    let permission: String
    let why: String
    let action: String
    var help: String? = nil
    /// Once given: where the button goes ("Open in System Settings ↗").
    var reopen: String = L10n.t("Open in System Settings")
    var reopenIcon: String = "arrow.up.forward.app"
    let perform: () -> Void

    init(number: Int, done: Bool, goal: String, example: String, permission: String, why: String,
         action: String, help: String? = nil, reopen: String? = nil, reopenIcon: String? = nil,
         action perform: @escaping () -> Void) {
        self.number = number
        self.done = done
        self.goal = goal
        self.example = example
        self.permission = permission
        self.why = why
        self.action = action
        self.help = help
        if let reopen { self.reopen = reopen }
        if let reopenIcon { self.reopenIcon = reopenIcon }
        self.perform = perform
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.85) : AkiPalette.red)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
            VStack(alignment: .leading, spacing: 6) {
                Text(goal)
                    .font(.system(size: 13.5, weight: .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L10n.t("Example")).font(.caption.weight(.semibold)).foregroundStyle(AkiPalette.red)
                    Text(example).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // What it takes, set apart: the permission and why.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(permission, systemImage: done ? "lock.open.fill" : "lock.fill")
                            .font(.caption.weight(.semibold))
                        Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    // Given: still one click away, to check it or take it back.
                    if done {
                        Button(action: perform) {
                            Label(reopen, systemImage: reopenIcon).font(.caption.weight(.medium))
                        }
                        .buttonStyle(.link)
                        .fixedSize()
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                if let help, !done {
                    Label(help, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if done {
                Label(L10n.t("Allowed"), systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
                    .fixedSize()
            } else {
                Button(action, action: perform)
            }
        }
        .padding(.vertical, 4)
    }
}
