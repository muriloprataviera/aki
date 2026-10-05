import AkiCore
import AppKit
import Carbon.HIToolbox

enum AppMain {
    @MainActor static func run() -> Never {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(Preferences.shared.presence.activationPolicy)
        app.run()
        exit(0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let home = AkiHome.default
    private let preferences = Preferences.shared
    private var model: SidebarModel!
    private var sidebar: SidebarController!
    private var settings: SettingsWindowController!
    private var marking: MarkingController!
    private var statusItem: NSStatusItem?
    private var history: HistoryWindowController!
    private var server: HTTPServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This build's icon, not one the Mac cached from an older version.
        NSApp.applicationIconImage = AkiBrand.appIcon
        let store = AnnotationStore(directory: home.url)
        model = SidebarModel(store: store, preferences: preferences)
        sidebar = SidebarController(model: model)
        settings = SettingsWindowController(preferences: preferences, model: model)
        sidebar.openSettings = { [weak self] in self?.settings.toggle() }
        sidebar.openHistory = { [weak self] in self?.history.show() }
        model.openHistory = { [weak self] session in self?.history.show(session: session) }
        settings.recentre = { [weak self] in self?.sidebar.relocate() }
        marking = MarkingController(model: model)
        marking.sidebarSpot = { [weak self] in self?.sidebar.dockSpot() }
        marking.ringLocation = { [weak self] id in self?.sidebar.screenLocation(of: id) }
        marking.didSend = { [weak self] ids in
            self?.sidebar.showDelivery(to: ids)
            self?.model.deliverLater(to: ids, now: true)
        }
        history = HistoryWindowController(model: model)
        GlobalShortcuts.shared.onMark = { [weak self] in self?.marking.toggle() }
        GlobalShortcuts.shared.onHistory = { [weak self] in self?.history.toggle() }
        GlobalShortcuts.shared.apply()
        model.startMarking = { [weak self] in self?.marking.start() }
        installMainMenu()
        Updates.shared.onAvailable = { [weak self] version in
            self?.model.updateVersion = version
            self?.markStatusItem(version != nil)
        }
        Updates.shared.start()
        // `AKI_FAKE_UPDATE=0.9.9` shows the update pill and dot (design work and screenshots).
        if let fake = ProcessInfo.processInfo.environment["AKI_FAKE_UPDATE"] {
            model.updateVersion = fake
            DispatchQueue.main.async { self.markStatusItem(true) }
        }
        followMacAppearance()
        startServer(store: store)
        model.startRefreshing()
        Task { await model.resumeDeliveries() }
        sidebar.applyVisibility()
        applyPresence()
        observePresence()
        // `AKI_OPEN_SETTINGS=1` opens Settings on launch (design work and screenshots).
        if ProcessInfo.processInfo.environment["AKI_OPEN_SETTINGS"] == "1" { settings.show() }
        // First launch: Get started, so the permissions are given before the first mark.
        if !preferences.onboarded {
            settings.show()
            preferences.onboarded = true
        }
    }

    /// Opening Aki again from Finder or Spotlight shows Settings: with no Dock icon
    /// and no menu bar item, that's the way back in.
    /// Light / dark and the accent colour follow the Mac live (for "Automatic"
    /// and "Mac's accent").
    private func followMacAppearance() {
        let update = { [weak self] in
            guard self != nil else { return }
            Preferences.shared.macIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Preferences.shared.macAccentTick += 1
        }
        update()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            // The new appearance settles a moment after the notice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { update() } }
        }
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    /// Opening Aki again (Raycast, Spotlight, Finder): a hidden sidebar comes
    /// back kept open; if it's already showing, Settings opens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if preferences.visibility == .hidden {
            preferences.visibility = .onHover
        } else {
            settings.show()
        }
        return false
    }

    /// `aki://mark`, `aki://history`, `aki://settings`: for Raycast, Alfred,
    /// Shortcuts (and Spotlight through Shortcuts), or a link anywhere.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "aki" {
            switch url.host ?? url.path {
            case "mark": marking.start()
            case "history": history.show()
            case "settings": settings.show()
            case "sidebar": preferences.visibility = preferences.visibility == .alwaysShow ? .onHover : .alwaysShow
            default: break
            }
        }
    }

    private func startServer(store: AnnotationStore) {
        do {
            let api = AkiAPI(store: store, token: try home.token())
            let server = HTTPServer(port: Aki.defaultPort) { await api.handle($0) }
            self.server = server
            Task {
                do {
                    _ = try await server.start()
                    model.serverStatus = .listening(Aki.defaultPort)
                } catch {
                    // Another Aki (or `aki serve`) already owns the port: keep working as its client.
                    model.serverStatus = .portBusy(Aki.defaultPort)
                }
            }
        } catch {
            model.serverStatus = .failed("\(error)")
        }
    }

    // MARK: Dock and menu bar

    private func observePresence() {
        withObservationTracking {
            _ = preferences.presence
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyPresence()
                self?.observePresence()
            }
        }
    }

    private func applyPresence() {
        AppWindows.refresh()
        if preferences.presence.wantsStatusItem {
            if statusItem == nil { setUpStatusItem() }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// The menu that makes ⌘Q, ⌘W, ⌘, and copy/paste work in Aki's windows
    /// (it doesn't show: Aki has no menu bar of its own).
    private func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu(title: "Aki")
        app.addItem(ClosureMenuItem(L10n.t("Settings…")) { [weak self] in self?.settings.show() }.with(key: ","))
        app.addItem(ClosureMenuItem(L10n.t("Check for Updates…")) { Updates.shared.checkForUpdates() })
        app.addItem(ClosureMenuItem("\(L10n.t("History"))   \(L10n.history)") { [weak self] in self?.history.show() })
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: L10n.t("Hide Aki"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: L10n.t("Quit Aki"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(withTitle: "Aki", action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: L10n.t("File"))
        file.addItem(NSMenuItem(title: L10n.t("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(withTitle: L10n.t("File"), action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: L10n.t("Edit"))
        edit.addItem(NSMenuItem(title: L10n.t("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L10n.t("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L10n.t("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L10n.t("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L10n.t("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L10n.t("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(withTitle: L10n.t("Edit"), action: nil, keyEquivalent: "").submenu = edit

        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = AkiBrand.pin(size: 17)
        item.button?.setAccessibilityLabel("Aki")
        let menu = NSMenu()
        // Built each time it opens: it shows how things are right now.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The pin with a small red dot while an update waits.
    private func markStatusItem(_ waiting: Bool) {
        statusItem?.button?.image = waiting ? AkiBrand.pinWithDot(size: 17) : AkiBrand.pin(size: 17)
    }

    /// The menu bar pin's menu, as things are now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        if let version = Updates.shared.available {
            let update = ClosureMenuItem("\(L10n.t("Update to")) \(version)…") { Updates.shared.checkForUpdates() }
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
            menu.addItem(.separator())
        }
        func shortcut(_ item: NSMenuItem, _ combo: KeyCombo) -> NSMenuItem {
            let key = combo.menuKey
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.flags
            return item
        }
        // Marking starts once the menu has closed, so it isn't in the picture.
        let mark = ClosureMenuItem(L10n.t("Mark the screen")) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.marking.start() }
        }
        mark.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        menu.addItem(shortcut(mark, preferences.markShortcut))
        let history = ClosureMenuItem(L10n.t("History")) { [weak self] in self?.history.show() }
        history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        menu.addItem(shortcut(history, preferences.historyShortcut))
        menu.addItem(.separator())
        // The sidebar, as it is: bring it back, or keep it open (✓) / let it hide.
        if preferences.visibility == .hidden {
            menu.addItem(ClosureMenuItem(L10n.t("Show the sidebar")) { Preferences.shared.visibility = .onHover })
        } else {
            let keep = ClosureMenuItem(L10n.t("Keep the sidebar open")) {
                let p = Preferences.shared
                p.visibility = p.visibility == .alwaysShow ? .onHover : .alwaysShow
            }
            keep.state = preferences.visibility == .alwaysShow ? .on : .off
            menu.addItem(keep)
            menu.addItem(ClosureMenuItem(L10n.t("Hide the sidebar")) { Preferences.shared.visibility = .hidden })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L10n.t("Settings…")) { [weak self] in self?.settings.show() }.with(key: ","))
        menu.addItem(ClosureMenuItem(L10n.t("Check for Updates…")) { Updates.shared.checkForUpdates() })
        menu.addItem(.separator())
        let quit = ClosureMenuItem(L10n.t("Quit Aki")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }
}
