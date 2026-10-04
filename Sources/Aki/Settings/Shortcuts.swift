import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key and its modifiers, as Carbon wants them (`kVK_*` code, Carbon flags).
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let mark = KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey | cmdKey))
    static let history = KeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(shiftKey | cmdKey))

    /// "code:modifiers" in the defaults.
    init?(stored: String?) {
        let parts = stored?.split(separator: ":").compactMap { UInt32($0) } ?? []
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key press while recording; nil when it can't be a global shortcut
    /// (no ⌘, ⌃ or ⌥, unless it's a function key).
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let strong = carbon & UInt32(cmdKey | optionKey | controlKey) != 0
        guard strong || Self.functionKeys[code] != nil else { return nil }
        self.init(keyCode: code, modifiers: carbon)
    }

    var stored: String { "\(keyCode):\(modifiers)" }

    /// For a menu item: its key and modifiers (so the shortcut also works while
    /// the menu is open, when global shortcuts don't).
    var menuKey: (key: String, flags: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        let name = Self.keyName(keyCode)
        return (name.count == 1 ? name.lowercased() : "", flags)
    }

    /// The Mac way: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Return): "⏎", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "esc", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_ForwardDelete): "⌦",
    ]

    /// The key's letter on this Mac's keyboard layout.
    static func keyName(_ code: UInt32) -> String {
        if let name = functionKeys[code] ?? specialKeys[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Aki's system-wide shortcuts, from Settings. Re-registered when they change;
/// paused while one is being recorded, so pressing it doesn't fire it.
@MainActor
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()

    var onMark: () -> Void = {}
    var onHistory: () -> Void = {}
    private var keys: [HotKey] = []
    /// Shortcuts another app already holds (shown in Settings).
    private(set) var taken: Set<String> = []

    func apply() {
        keys = []
        let p = Preferences.shared
        let mark = HotKey(keyCode: p.markShortcut.keyCode, modifiers: p.markShortcut.modifiers) { [weak self] in self?.onMark() }
        let history = HotKey(keyCode: p.historyShortcut.keyCode, modifiers: p.historyShortcut.modifiers) { [weak self] in self?.onHistory() }
        taken = Set([mark.registered ? nil : "mark", history.registered ? nil : "history"].compactMap { $0 })
        keys = [mark, history]
        p.shortcutTick += 1
    }

    func pause() { keys = [] }
}

/// Click, then press the new shortcut. esc cancels; the arrow puts the default back.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    let fallback: KeyCombo
    let taken: Bool
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            if taken && !recording {
                Label(L10n.t("Another app uses it"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { recording ? stop() : start() } label: {
                Text(recording ? L10n.t("Press the keys…") : combo.display)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(recording ? AkiPalette.red : .primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(minWidth: 84)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovered || recording ? 0.12 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? AkiPalette.red : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            if combo != fallback && !recording {
                Button { combo = fallback; GlobalShortcuts.shared.apply() } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L10n.t("Back to") + " " + fallback.display)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        GlobalShortcuts.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if let new = KeyCombo(event: event) {
                combo = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        GlobalShortcuts.shared.apply()
    }
}

/// A link with a copy button beside it.
struct CopyLink: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
            }
            .buttonStyle(.plain).foregroundStyle(copied ? AkiPalette.red : .secondary)
            .help(L10n.t("Copy"))
        }
    }
}

/// Raycast script commands for Aki, written to ~/.aki/raycast (a folder that
/// stays put across updates) and shown in Finder, to add once in Raycast.
enum RaycastCommands {
    static let commands: [(file: String, title: String, about: String, link: String)] = [
        ("aki-mark.sh", "Mark the Screen", "Start marking with Aki.", "mark"),
        ("aki-history.sh", "Aki History", "Everything you've marked.", "history"),
        ("aki-settings.sh", "Aki Settings", "Open Aki's settings.", "settings"),
        ("aki-sidebar.sh", "Toggle Aki Sidebar", "Keep the sidebar open, or let it hide.", "sidebar"),
    ]

    static func install() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aki/raycast")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for command in commands {
            let script = """
            #!/bin/bash

            # @raycast.schemaVersion 1
            # @raycast.title \(command.title)
            # @raycast.mode silent
            # @raycast.packageName Aki
            # @raycast.icon 📍
            # @raycast.description \(command.about)

            open -g "aki://\(command.link)"

            """
            let url = folder.appendingPathComponent(command.file)
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
