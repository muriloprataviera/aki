import AkiCore
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Runs a round of marking: freezes every screen under a dimmed layer, collects
/// points and areas with comments, and sends them to their conversations.
@MainActor
final class MarkingController {
    private let model: SidebarModel
    /// Where a conversation's ring is on screen (global, bottom-left origin).
    var ringLocation: (String?) -> NSPoint? = { _ in nil }
    /// Where the folded hint dot sits: beside the sidebar.
    var sidebarSpot: () -> NSPoint? = { nil }
    /// Called with the conversations that just received marks.
    var didSend: ([String]) -> Void = { _ in }

    private var panels: [MarkingPanel] = []
    private var session: MarkingSession?
    private var keyMonitor: Any?
    /// esc and ⌘⏎ as system-wide shortcuts while marking: they work even when the
    /// overlay hasn't got the keyboard (the app below would take them otherwise).
    private var modalKeys: [HotKey] = []
    /// The app you were in: it gets the focus back when marking ends.
    private var previousApp: NSRunningApplication?
    /// Aki's own windows (Settings, History) put aside while marking: activating
    /// Aki would otherwise bring them over the app being marked.
    private var setAside: [NSWindow] = []
    /// Marking's own overlays: the only Aki windows a capture leaves out, so the
    /// sidebar, its card and Settings can be marked like any app.
    private var overlayIDs: Set<CGWindowID> { Set(panels.map { CGWindowID($0.windowNumber) }) }
    /// Scrolling the page below: the wheel goes through to it, and the screens
    /// are captured again once it stops.
    private var scrollMonitors: [Any] = []
    private var scrollIdle: DispatchWorkItem?
    private var starting = false
    /// Marks saved but not sent, kept between rounds (the sidebar counts them, the History lists them).
    private var queued: [Mark] = [] {
        didSet {
                let pictures = Dictionary(uniqueKeysWithValues: model.queuedList.map { ($0.id, $0.image) })
            model.queuedList = queued.map { mark in
                QueuedMark(id: mark.id, number: mark.number, comment: mark.comment, text: mark.text,
                           destination: mark.destination,
                           image: session?.previewImage(of: mark) ?? pictures[mark.id] ?? nil)
            }
        }
    }
    private var cursorTimer: Timer?
    private var appObserver: Any?
    private var activeObserver: Any?

    var isActive: Bool { session != nil }

    /// Empties the waiting queue (from the History, with marking closed).
    func clearQueued() {
        if isActive { discard() } else { queued = [] }
    }

    /// Takes one waiting mark out of the queue (from the History).
    func removeQueued(_ id: UUID) {
        queued.removeAll { $0.id == id }
        for index in queued.indices { queued[index].number = index + 1 }
    }

    init(model: SidebarModel) {
        self.model = model
    }

    func toggle() {
        isActive ? close() : start()
    }

    func start() {
        guard !isActive, !starting else { return }
        starting = true
        previousApp = NSWorkspace.shared.frontmostApplication
        let context = MarkContext.current()
        // The pin pointer at once, while the screen is being captured (Aki may be in
        // the background still: it may set the cursor anyway).
        model.marking = true
        // Unless you were in Aki itself (then its window is what you're marking).
        let fromAki = previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        setAside = fromAki ? [] : NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        setAside.forEach { $0.orderOut(nil) }
        BackgroundCursor.enable()
        // Aki to the front right away: the app below (Chrome…) would keep setting its
        // own cursor otherwise. It gets the focus back when marking ends.
        NSApp.activate(ignoringOtherApps: true)
        AkiCursor.pin.set()
        holdCursor()
        Task {
            defer { starting = false }
            // The page's session (by its localhost port) is looked up while the screens
            // are captured; the sidebar's list is fresh enough to start with.
            let terminals = model.markableTerminals
            async let byPort = Self.sessionServing(context.url, among: terminals, selected: model.markingDestination)
            let grabs0 = await ScreenGrab.captureAll(excluding: overlayIDs)
            guard let grabs = grabs0, !grabs.isEmpty else {
                model.marking = false
                NSCursor.arrow.set()
                // Undo what start() set up: windows back, focus back to where you were.
                cursorTimer?.invalidate()
                cursorTimer = nil
                setAside.forEach { $0.orderBack(nil) }
                setAside = []
                AppWindows.refresh()
                previousApp?.activate()
                previousApp = nil
                askForScreenRecording()
                return
            }
            let byPortID = await byPort
            let session = MarkingSession(
                grabs: grabs, context: context, terminals: terminals, destination: byPortID ?? model.markingDestination)
            session.hues = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, model.hue(of: $0)) })
            session.projects = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, model.projectKey(of: $0)) })
            // Marks saved in an earlier round (esc keeps them): back in the queue.
            if !queued.isEmpty { session.resume(queued) }
            queued = []
            self.session = session
            followTerminals(session)
            session.live = !model.preferences.freezeScreen
            session.markAdded = { [weak session, weak self] mark in
                guard let session, session.live else { return }
                let overlays = self?.overlayIDs ?? []
                // The overlay is transparent: the capture leaves Aki's windows out.
                session.capturing += 1
                Task {
                    defer { session.capturing -= 1 }
                    guard let grabs = await ScreenGrab.captureAll(excluding: overlays), mark.screen < grabs.count else { return }
                    let grab = grabs[mark.screen]
                    let text = mark.isPoint ? nil : await ScreenText.read(grab)
                    session.refreshPicture(of: mark.id, grab: grab, text: text)
                }
            }
            session.focusScreen = { [weak self] index in
                guard let self, index < self.panels.count else { return }
                // The panel takes the keyboard without bringing Aki forward, so the
                // comment field gets what you type (not the app underneath).
                self.panels[index].makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.panels[index].makeKey()
            }
            for (index, grab) in grabs.enumerated() {
                let panel = MarkingPanel(screen: grab.screen)
                var view = MarkingView(
                    session: session, screen: index,
                    target: { [weak self] id in self?.target(for: id, on: grab.screen) },
                    dockSpot: { [weak self] in
                        guard let point = self?.sidebarSpot(), grab.screen.frame.contains(point) else { return nil }
                        return CGPoint(x: point.x - grab.screen.frame.minX, y: grab.screen.frame.maxY - point.y)
                    },
                    send: { [weak self] in self?.send() },
                    sendOnly: { [weak self] id in self?.send(only: id) },
                    close: { [weak self] in self?.close() },
                    discard: { [weak self] in self?.discard() })
                view.passClick = { [weak self] point in self?.passClick(at: point) }
                let hosting = FirstClickHostingView(rootView: view)
                panel.contentView = hosting
                panel.orderFrontRegardless()
                panels.append(panel)
            }
            // The agent may just have changed in Orca: a fresh look, after the overlay is up
            // (it takes about half a second; followTerminals brings the result in).
            Task { await model.refresh() }
            // The panel under the pointer takes the keyboard.
            let mouse = NSEvent.mouseLocation
            (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
            AkiCursor.pin.set()
            holdCursor()
            watchKeys()
            watchScroll()
            followFrontApp()
            modalKeys = [
                HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.escape() },
                HotKey(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey)) { [weak self] in self?.send() },
            ]
            // Read the text on each screen in the background, for ⌥ and for marks.
            for (index, grab) in grabs.enumerated() {
                Task { [weak session] in
                    let text = await ScreenText.read(grab)
                    session?.texts[index] = text
                }
            }
        }
    }

    /// Follow the sidebar's live session list while a mark's card is open.
    private func followTerminals(_ session: MarkingSession) {
        guard self.session === session else { return }
        let terminals = model.markableTerminals
        session.updateTerminals(terminals)
        session.hues = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, model.hue(of: $0)) })
        session.projects = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, model.projectKey(of: $0)) })
        withObservationTracking {
            _ = model.markableTerminals
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                self.followTerminals(session)
            }
        }
    }

    /// On a localhost page, the session whose folder runs that port: the one you
    /// picked if it's among them, else one named with the port ("CORES LOGO 3000"),
    /// else the most recently active.
    private static func sessionServing(_ url: String?, among terminals: [AgentTerminal], selected: String?) async -> String? {
        guard let url, let parts = URL(string: url), let port = parts.port,
            ["localhost", "127.0.0.1", "0.0.0.0"].contains(parts.host() ?? "")
        else { return nil }
        guard let worktree = await Task.detached(operation: { Worktree.forPort(port) }).value else { return nil }
        let here = terminals.filter { $0.worktree == worktree }
        if let selected, here.contains(where: { $0.id == selected }) { return selected }
        if let named = here.first(where: { $0.name.contains(String(port)) }) { return named.id }
        return here.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }?.id
    }

    /// esc: drops the mark being written (or clears it), else leaves.
    private func escape() {
        // A picture opened bigger: esc puts it away first.
        if ImageZoom.isOpen {
            ImageZoom.close()
            let mouse = NSEvent.mouseLocation
            (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
            return
        }
        // Mid-send (saving, or the marks in flight): it finishes by itself.
        guard let session, !session.sending, !session.flying else { return }
        if session.editing != nil && session.draft.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { session.cancelEditing() }
        } else if session.editing != nil {
            session.draft = ""
        } else {
            close()
        }
    }

    /// ⌘Tab while marking: the marks go on in the app you switched to (its page,
    /// its elements first under the pointer).
    private func followFrontApp() {
        guard appObserver == nil else { return }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let session = self.session,
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                else { return }
                session.context = MarkContext.current()
                self.previousApp = app
                session.hovered = nil
                // A frozen screen shows the app you just switched to (live ones already do).
                if !session.live { session.scrolling = true; self.scrollStopped() }
                // The overlay stays over everything, with the pin.
                self.panels.forEach { $0.orderFrontRegardless() }
                AkiCursor.pin.set()
            }
        }
    }

    /// The first press used to lose the pin: switching apps puts the arrow back a
    /// moment after. So it's set again for the first second, and when Aki has
    /// become the active app.
    private func holdCursor() {
        cursorTimer?.invalidate()
        var ticks = 0
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                ticks += 1
                guard let self, self.isActive || self.starting else { timer.invalidate(); return }
                // ⇧ as it really is: after a ⇧-click the app below is in front and
                // Aki hears no keys, so letting go of ⇧ is only seen here.
                self.followShift(NSEvent.modifierFlags.contains(.shift))
                if ImageZoom.isOpen {
                    // Its own window, its own pointer.
                } else if self.session?.shiftHeld == true {
                    // ⇧ held: the arrow, whatever a button or a text field set meanwhile.
                    if NSCursor.current !== NSCursor.arrow { NSCursor.arrow.set() }
                } else if ticks < 24 {
                    AkiCursor.pin.set()  // the first second: always
                } else if ticks % 2 == 0, NSCursor.current === NSCursor.arrow || NSCursor.current === AkiCursor.pin {
                    // After that, every 0.1 s: the pin again unless a button's hand or the
                    // text cursor is up (what's on screen may have drifted to the arrow).
                    AkiCursor.pin.set()
                }
            }
        }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive || self.starting else { return }
                    AkiCursor.pin.set()
                }
            }
        }
    }

    /// Leaving keeps the queue for the next round (send it then, or throw it away).
    func close() {
        // Mid-send (saving, marks in flight): it closes by itself when done.
        if let session, session.sending { return }
        if let session, !session.flying { queued = session.carried() }
        model.queuedMarks = queued.count
        teardown()
    }

    /// The queue's ×: leaves and forgets the marks.
    func discard() {
        queued = []
        session?.marks.removeAll()
        teardown()
    }

    private func teardown() {
        AkiCursor.passThrough = false
        model.marking = false
        setAside.forEach { $0.orderBack(nil) }
        setAside = []
        AppWindows.refresh()
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        modalKeys.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors.removeAll()
        scrollIdle?.cancel()
        scrollIdle = nil
        if session != nil { NSCursor.arrow.set() }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        session = nil
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// Sends the whole queue, or just one mark (`only`): the others stay queued.
    private func send(only id: UUID? = nil) {
        guard let session, !session.flying, !session.sending else { return }
        session.commitDraft()
        let requested = session.marks.filter { id == nil || $0.id == id }
        guard !requested.contains(where: { session.terminal($0.destination) == nil }) else {
            NSSound.beep()
            return
        }
        var keep: [Mark] = []
        if let id, session.marks.contains(where: { $0.id == id }) {
            keep = session.carried().filter { $0.id != id }
            session.marks.removeAll { $0.id != id }
        }
        guard !session.marks.isEmpty else { return close() }
        session.sending = true
        // The marks of this send; any made while it saves stay for the next one.
        // The marks of this send, fixed now: one made while it waits isn't part of it.
        let batch = Set(session.marks.map(\.id))
        Task {
            // Each mark's own picture (live screen) first: a send right after a mark
            // waits a moment for it, up to 1.5 s.
            for _ in 0..<30 where session.capturing > 0 { try? await Task.sleep(for: .milliseconds(50)) }
            let snapshot = session.marks.filter { batch.contains($0.id) }
            let (sentTo, failed) = await session.save(snapshot, into: model.store)
            session.sending = false
            keep += session.carried().filter { !batch.contains($0.id) }
            if !failed.isEmpty {
                // What was saved leaves the queue; what wasn't stays, to send again.
                session.marks.removeAll { batch.contains($0.id) && !failed.contains($0.id) }
                // "Only this one" had set the rest aside: they come back to the queue.
                session.marks += keep.filter { kept in !session.marks.contains { $0.id == kept.id } }
                session.renumber()
                NSSound.beep()
                if !sentTo.isEmpty { didSend(sentTo) }
                return
            }
            session.flying = true
            // The tags' flight (0.72 s) plus their stagger, then the ring lights up.
            let stagger = Double(min(session.marks.count - 1, 6)) * 0.07
            try? await Task.sleep(for: .seconds(0.78 + stagger))
            close()
            if !keep.isEmpty {
                queued = keep
            }
            if let destination = session.marks.last?.destination {
                model.selectedTerminal = destination
            }
            await model.refresh()
            didSend(sentTo)
        }
    }

    /// Esc leaves (or drops the mark being written), Tab changes the destination,
    /// ⌘⏎ sends. Typing itself goes to the comment field.
    private func watchKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let session = self.session else { return event }
            if event.type == .flagsChanged {
                // ⌥ switches between UI elements and lines of text, right away.
                let held = event.modifierFlags.contains(.option)
                if held != session.optionHeld {
                    session.optionHeld = held
                    for screen in session.pointer.keys { session.updateLineHover(screen: screen) }
                }
                self.followShift(event.modifierFlags.contains(.shift))
                return event
            }
            switch event.keyCode {
            case 53:  // esc (also a system shortcut while marking; whichever comes first)
                self.escape()
                return nil
            // On a web page the arrows walk its elements; elsewhere ↑ / ↓ go out and back in.
            case 126 where session.editing == nil:  // ↑: the container around it
                if session.hovered?.fromBrowser == true { session.step(.up) } else { session.widen() }
                return nil
            case 125 where session.editing == nil:  // ↓: inside it
                if session.hovered?.fromBrowser == true { session.step(.down) } else { session.narrow() }
                return nil
            case 123 where session.editing == nil && session.hovered?.fromBrowser == true:  // ←: the one before
                session.step(.previous)
                return nil
            case 124 where session.editing == nil && session.hovered?.fromBrowser == true:  // →: the one after
                session.step(.next)
                return nil
            case 48:  // tab
                session.cycleDestination(by: event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            // ⌘1–⌘9: that session (plain digits are typed into the comment).
            case 18 where event.modifierFlags.contains(.command), 19 where event.modifierFlags.contains(.command),
                 20 where event.modifierFlags.contains(.command), 21 where event.modifierFlags.contains(.command),
                 23 where event.modifierFlags.contains(.command), 22 where event.modifierFlags.contains(.command),
                 26 where event.modifierFlags.contains(.command), 28 where event.modifierFlags.contains(.command),
                 25 where event.modifierFlags.contains(.command):
                let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                if let n = digits[event.keyCode], n <= session.terminals.count {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        session.setDestination(session.terminals[n - 1].id)
                    }
                }
                return nil
            // ⌘+ / ⌘− / ⌘0: the page's own zoom, on the app below; the screen is captured again.
            case 24 where event.modifierFlags.contains(.command) && session.editing == nil,
                 27 where event.modifierFlags.contains(.command) && session.editing == nil,
                 29 where event.modifierFlags.contains(.command) && session.editing == nil,
                 69 where event.modifierFlags.contains(.command) && session.editing == nil,
                 78 where event.modifierFlags.contains(.command) && session.editing == nil:
                self.passKey(event)
                return nil
            case 51 where session.editing == nil && !session.queueSelected.isEmpty:  // ⌫: the ticked marks out
                withAnimation(.easeOut(duration: 0.15)) { session.removeSelected() }
                return nil
            case 36 where event.modifierFlags.contains(.command):  // ⌘⏎
                self.send()
                return nil
            default:
                return event
            }
        }
    }

    /// The wheel scrolls the page below, as if Aki weren't there: the overlays let
    /// the pointer through and hide the frozen picture while it moves; when it
    /// stops, the screens are captured again (marks already made keep theirs).
    private func watchScroll() {
        let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let session = self.session, !session.flying else { return event }
            if !session.scrolling {
                session.scrolling = true
                self.panels.forEach { $0.ignoresMouseEvents = true }
                // This first tick lands on the page below; the next ones go there by themselves.
                if let copy = event.cgEvent?.copy() {
                    DispatchQueue.main.async { copy.post(tap: .cghidEventTap) }
                }
            }
            self.scrollMoved()
            return nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session?.scrolling == true else { return }
                self.scrollMoved()
            }
        }
        scrollMonitors = [local, global].compactMap { $0 }
    }

    /// Keys meant for the app below (⌘+ zooms its page): it comes forward, gets the key,
    /// and once it has redrawn the screens are captured again and Aki takes the keys back.
    private func passKey(_ event: NSEvent) {
        guard let session, !session.flying, !session.sending, let key = event.cgEvent?.copy() else { return }
        let point = NSEvent.mouseLocation
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let owner = Self.appOwningWindow(at: CGPoint(x: point.x, y: primary - point.y)) ?? previousApp
        session.scrolling = true
        panels.forEach { $0.ignoresMouseEvents = true }
        reactivateAfterCapture = true
        owner?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            key.post(tap: .cghidEventTap)
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(event.keyCode), keyDown: false) {
                up.flags = key.flags
                up.post(tap: .cghidEventTap)
            }
            self?.scrollMoved()
        }
    }

    /// After a key passed to the app below: Aki takes the keyboard back once captured.
    private var reactivateAfterCapture = false

    /// ⇧: the computer's own arrow, so it's clear the click goes through; let go, the pin.
    private func followShift(_ held: Bool) {
        guard let session, held != session.shiftHeld else { return }
        session.shiftHeld = held
        AkiCursor.passThrough = held
        (held ? NSCursor.arrow : AkiCursor.pin).set()
    }

    /// ⇧-click: the overlays step aside as when scrolling, a plain click (no ⇧) lands
    /// on the app below, and the screens are captured again once it settles.
    private func passClick(at point: CGPoint) {
        guard let session, !session.flying, !session.sending else { return }
        session.scrolling = true
        panels.forEach { $0.ignoresMouseEvents = true }
        // The app under the point comes forward first: Chrome (and others) take a click
        // on an inactive window as "activate me" only, and the page never gets it.
        let owner = Self.appOwningWindow(at: point)
        let needsActivation = owner.map { !$0.isActive } ?? false
        owner?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsActivation ? 0.2 : 0.05)) { [weak self] in
            let source = CGEventSource(stateID: .privateState)
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.flags = []
                if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
                event?.post(tap: .cghidEventTap)
                if type == .leftMouseDown { usleep(30_000) }
            }
            self?.scrollMoved()
        }
    }

    /// The app whose window is under a global point (top-left origin), Aki's own left out.
    private static func appOwningWindow(at point: CGPoint) -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point)
            else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    private func scrollMoved() {
        scrollIdle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scrollStopped() }
        scrollIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func scrollStopped() {
        guard let session, session.scrolling else { return }
        Task {
            if let grabs = await ScreenGrab.captureAll(excluding: overlayIDs) {
                for (index, grab) in grabs.enumerated() where index < session.grabs.count {
                    session.replace(grab, on: index)
                    Task { [weak session] in
                        let text = await ScreenText.read(grab)
                        session?.texts[index] = text
                    }
                }
            }
            session.scrolling = false
            self.panels.forEach { $0.ignoresMouseEvents = false }
            if self.reactivateAfterCapture {
                self.reactivateAfterCapture = false
                NSApp.activate(ignoringOtherApps: true)
            }
            let mouse = NSEvent.mouseLocation
            (self.panels.first { $0.frame.contains(mouse) } ?? self.panels.first)?.makeKey()
        }
    }

    /// The ring's position in an overlay's own coordinates (top-left origin).
    private func target(for id: String?, on screen: NSScreen) -> CGPoint? {
        guard let point = ringLocation(id) else { return nil }
        let frame = screen.frame
        guard frame.insetBy(dx: -2, dy: -2).contains(point) else {
            // The ring is on another display: fly toward the edge nearest to it.
            return CGPoint(x: min(max(point.x - frame.minX, 0), frame.width), y: frame.height)
        }
        return CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    private func askForScreenRecording() {
        let alert = NSAlert()
        alert.messageText = L10n.t("Aki needs Screen Recording")
        alert.informativeText = L10n.t(
            "To crop what you mark, allow Aki in System Settings → Privacy & Security → Screen Recording, then press {mark} again.")
        alert.addButton(withTitle: L10n.t("Open System Settings"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A borderless panel over a whole screen, above everything, that takes the
/// keyboard without bringing Aki forward (the app you marked stays in front).
final class MarkingPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pin everywhere on the frozen screen (SwiftUI would put the arrow back).
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: AkiCursor.pin)
    }

    override func cursorUpdate(with event: NSEvent) { AkiCursor.set(AkiCursor.pin) }
}
