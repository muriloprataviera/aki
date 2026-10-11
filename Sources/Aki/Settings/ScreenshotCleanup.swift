import AkiCore
import AppKit
import SwiftUI

/// The Mac's own screenshots piling up: how many and how much room, and the old
/// ones to the Trash in one click. Looks only when asked (macOS asks the first
/// time for the Desktop and Downloads), then each time the pane opens.
struct ScreenshotCleanup: View {
    /// Storage: look again by itself once you've checked before.
    var checkOnAppear = false

    @AppStorage("screenshotsChecked") private var checked = false
    @AppStorage("screenshotsDays") private var days = 30
    @State private var found: Screenshots?
    @State private var looking = false
    @State private var moved: (count: Int, bytes: Int64)?

    var body: some View {
        Section(L10n.t("Screenshots piling up")) {
            Text(L10n.t("Every screenshot you took to show someone, or an agent, is still on your Mac. Aki looks on the Desktop, in Downloads and in your screenshot folder, and moves the old ones to the Trash (you can still get them back from there)."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let found {
                let old = found.older(than: days)
                LabeledContent(L10n.t("Found")) {
                    Text("\(found.files.count) · \(Bytes.text(found.bytes))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Picker(L10n.t("Older than"), selection: $days) {
                    Text("7 \(L10n.t("days"))").tag(7)
                    Text("30 \(L10n.t("days"))").tag(30)
                    Text("90 \(L10n.t("days"))").tag(90)
                }
                LabeledContent(L10n.t("Old ones")) {
                    HStack(spacing: 8) {
                        Text("\(old.count) · \(Bytes.text(old.reduce(0) { $0 + $1.bytes }))")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button(L10n.t("Move to Trash")) { trash(old) }
                            .disabled(old.isEmpty || looking)
                    }
                }
                if let moved {
                    Label(String(format: L10n.t("%d moved to the Trash · %@ freed"), moved.count, Bytes.text(moved.bytes)),
                          systemImage: "trash")
                        .font(.caption).foregroundStyle(.green)
                }
                HStack {
                    if let folder = found.mainFolder {
                        Button(L10n.t("Show in Finder")) { NSWorkspace.shared.open(folder) }
                    }
                    Button(L10n.t("Check again")) { look() }.disabled(looking)
                }
            } else {
                HStack {
                    Text(L10n.t("macOS may ask once to let Aki see the Desktop and Downloads."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(looking ? L10n.t("Looking…") : L10n.t("Check")) { look() }.disabled(looking)
                }
            }
            Label(L10n.t("With Aki you don't need screenshots for your agent: mark it and send."), systemImage: "scope")
                .font(.caption).foregroundStyle(AkiPalette.red)
        }
        .task {
            if checkOnAppear, checked, found == nil { look() }
        }
    }

    private func look() {
        looking = true
        Task.detached(priority: .userInitiated) {
            let result = Screenshots.scan()
            await MainActor.run {
                found = result
                looking = false
                checked = true
            }
        }
    }

    private func trash(_ files: [Screenshots.File]) {
        looking = true
        Task.detached(priority: .userInitiated) {
            let done = Screenshots.trash(files)
            let result = Screenshots.scan()
            await MainActor.run {
                moved = done
                found = result
                looking = false
            }
        }
    }
}
