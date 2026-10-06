// Window, hit-testing and pointer handling adapted from Codenotch's NotchPanel,
// NotchHostingView and NotchWindowController (MIT, Copyright (c) 2026 Vinz,
// https://github.com/vinzdg/codenotch).

import AkiCore
import AppKit
import SwiftUI

/// Owns the sidebar window. The window has a fixed size for a given number of
/// rings, size and edge, and never moves on hover: the pointer is read from its
/// position on screen, not from enter/exit events, so opening can't close it again.
@MainActor
final class SidebarController {
    private let model: SidebarModel
    private var preferences: Preferences { model.preferences }
    private let panel: SidebarPanel
    private let hosting: InteractiveHostingView<SidebarRoot>
    private var layout: SidebarLayout
    private var monitors: [Any] = []
    private var timer: Timer?
    private var foldWork: DispatchWorkItem?
    private var lastClick: (index: Int, at: Date)?
    private var shownCursor: NSCursor?
    private var lastEdgeSwitch = Date.distantPast

    /// Codenotch's way: the window server only takes cursor changes from the
    /// frontmost app unless told otherwise (BackgroundCursor).
    /// Set directly, never pushed: a stack shared with marking and hover effects
    /// got unbalanced and could leave no visible cursor. While marking, the
    /// overlay owns the pointer and the sidebar leaves it alone.
    /// The diagonal resize cursor for the handle's corner (macOS 15 has the
    /// window's own; before that, a crosshair).
    static func resizeCursor(_ d: CGVector) -> NSCursor {
        let key = "\(d.dx > 0)\(d.dy < 0)"
        if let made = resizeCursors[key] { return made }
        let made = makeResizeCursor(d)
        resizeCursors[key] = made
        return made
    }
    private static var resizeCursors: [String: NSCursor] = [:]

    private static func makeResizeCursor(_ d: CGVector) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = d.dx > 0
                ? (d.dy < 0 ? .topRight : .bottomRight) : (d.dy < 0 ? .topLeft : .bottomLeft)
            return .frameResize(position: position, directions: .all)
        }
        return .crosshair
    }

    /// The project whose name is under this point (top-left origin), if names show.
    private func projectName(at point: CGPoint) -> String? {
        guard preferences.showProjects else { return nil }
        return model.targets.first { $0.key.hasPrefix("project|") && $0.value.insetBy(dx: -3, dy: -3).contains(point) }
            .map { String($0.key.dropFirst("project|".count)) }
    }

    func setCursor(_ wanted: NSCursor?) {
        guard !model.marking else { return }
        BackgroundCursor.enable()
        // Over something of the sidebar: set it again whenever it was changed under us (the
        // app below is in front and puts its arrow back), not only when it changes here —
        // that's how the resize corner sometimes showed no resize cursor.
        if let wanted {
            if NSCursor.current !== wanted || shownCursor !== wanted { wanted.set() }
            shownCursor = wanted
            return
        }
        guard shownCursor != nil else { return }
        NSCursor.arrow.set()
        shownCursor = nil
    }
    /// A card opened by a click lets go 3 s after the pointer leaves it.
    private var pinnedAwayWork: DispatchWorkItem?
    private var lastProjectClick: (key: String, at: Date)?
    private var resizeStart: (point: CGPoint, size: SidebarSize)?
    private var lastCardClick: (key: String, at: Date)?
    private var previousAppForEditing: NSRunningApplication?
    private var unhoverWork: DispatchWorkItem?

    var openHistory: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }

    /// Grace before folding after the pointer leaves, and before dropping the card.
    private static let foldGrace: TimeInterval = 0.8
    private static let hoverGrace: TimeInterval = 0.6

    var isVisible: Bool { panel.isVisible }

    init(model: SidebarModel) {
        self.model = model
        layout = SidebarLayout(count: 0, edge: model.preferences.edge, scale: model.preferences.size.scale)
        panel = SidebarPanel(contentRect: .zero)
        hosting = InteractiveHostingView(rootView: SidebarRoot(model: model, openSettings: {}))
        hosting.rootView = SidebarRoot(model: model, openSettings: { [weak self] in self?.openSettings() })
        let container = PassThroughContainerView()
        container.addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = container
        panel.ignoresMouseEvents = true

        panel.contextMenuProvider = { [weak self] point in self?.menu(at: point) }
        panel.onClick = { [weak self] point, count in self?.click(at: point, count: count) ?? false }
        panel.onDrag = { [weak self] dx, dy in self?.drag(dx: dx, dy: dy) }
        panel.onDragEnd = { [weak self] in
            self?.setCursor(.openHand)
            self?.relocate()
        }
        panel.pressReorders = { [weak self] windowPoint in
            guard let self, self.model.expanded else { return false }
            let point = CGPoint(x: windowPoint.x, y: self.panel.frame.height - windowPoint.y)
            if self.model.editingProject == nil, self.projectName(at: point) != nil { return true }
            guard let index = self.layout.cellIndex(at: point), index < self.model.rings.count,
                case .terminal = self.model.rings[index] else { return false }
            return true
        }
        panel.onReorderDrag = { [weak self] start, now in
            guard let self else { return }
            let a = CGPoint(x: start.x, y: self.panel.frame.height - start.y)
            let delta = self.preferences.edge.isVertical ? -(now.y - start.y) : now.x - start.x
            // A project's name carries all its sessions.
            if let key = self.model.draggingProject?.key ?? self.projectName(at: a) {
                self.model.draggingProject = (key, delta)
                self.setCursor(.closedHand)
                return
            }
            guard let index = self.layout.cellIndex(at: a), index < self.model.rings.count,
                case .terminal(let terminal) = self.model.rings[index] else { return }
            self.model.dragging = (terminal.id, delta)
            self.setCursor(.closedHand)
        }
        panel.onReorderEnd = { [weak self] _ in
            guard let self else { return }
            if self.model.draggingProject != nil {
                let order = self.model.proposedProjectOrder(step: self.layout.step)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    if let order { self.model.moveProjects(to: order) }
                    self.model.draggingProject = nil
                }
                self.setCursor(nil)
                return
            }
            guard let dragging = self.model.dragging else { return }
            let rings = self.model.rings
            if let to = self.model.proposedIndex(step: self.layout.step), case .terminal(let target) = rings[to] {
                let destination = self.model.visibleTerminals.firstIndex { $0.id == target.id } ?? 0
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    self.model.move(dragging.id, to: destination)
                    self.model.dragging = nil
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { self.model.dragging = nil }
            }
            self.setCursor(nil)
        }

        // The grip is held, not clicked: pressing on it starts the move, no ⌥ needed.
        panel.startsDrag = { [weak self] windowPoint in
            guard let self, self.model.gripHovered else { return false }
            let point = CGPoint(x: windowPoint.x, y: self.panel.frame.height - windowPoint.y)
            let carries = self.layout.gripRect.contains(point)
            if carries { self.setCursor(.closedHand) }
            return carries
        }

        // The corner handle, like a window's: dragging out of the corner grows the
        // sidebar a size at a time, back in shrinks it.
        panel.startsResize = { [weak self] _ in
            guard let self, self.model.expanded, self.model.resizeHovered else { return false }
            self.resizeStart = (NSEvent.mouseLocation, self.preferences.size)
            self.model.resizing = true
            return true
        }
        panel.onResize = { [weak self] screenPoint in
            guard let self, let start = self.resizeStart else { return }
            // Screen y runs up, the layout's down.
            let d = self.layout.resizeDirection
            let reach = (screenPoint.x - start.point.x) * d.dx - (screenPoint.y - start.point.y) * d.dy
            let all = SidebarSize.allCases
            let base = all.firstIndex(of: start.size) ?? 1
            let i = min(max(base + Int((reach / 26).rounded()), 0), all.count - 1)
            if all[i] != self.preferences.size {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.preferences.size = all[i] }
            }
        }
        panel.onResizeEnd = { [weak self] in
            guard let self else { return }
            self.resizeStart = nil
            self.model.resizing = false
            self.cursorMoved()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        observeLayoutInputs()
        model.onLoaded = { [weak self] in self?.applyVisibility() }
        model.onProjectEditEnded = { [weak self] in self?.finishEditingProject() }
        model.chooseMoveTarget = { [weak self] terminal in self?.showMoveMenu(for: terminal) }
    }

    /// Shows or hides the panel according to the visibility setting.
    func applyVisibility() {
        switch preferences.visibility {
        case .hidden:
            panel.orderOut(nil)
            stopWatchingCursor()
        case .alwaysShow, .onHover:
            relocate()
            panel.orderFrontRegardless()
            startWatchingCursor()
            setExpanded(preferences.visibility == .alwaysShow)
            selfTest()
        }
    }

    // MARK: Placement

    /// The only place the window's frame changes: when the screen, the number of
    /// rings, the size or the edge changes, and while it's being dragged.
    func relocate() {
        guard let screen = NSScreen.screens.first else { return }
        let full = screen.frame
        let visible = screen.visibleFrame
        let scale = preferences.size.scale * SidebarLayout.density(rings: model.rings.count)
        layout = SidebarLayout(count: model.rings.count, edge: preferences.edge, scale: scale,
                               labeled: preferences.ringMode == .terminals)
        // Too long for this screen (many rings, large size, down a side): shrink to fit.
        let room = (preferences.edge.isVertical ? visible.height : full.width) * 0.94
        if layout.bodyLength > room {
            layout = SidebarLayout(count: model.rings.count, edge: preferences.edge, scale: scale * room / layout.bodyLength,
                                   labeled: preferences.ringMode == .terminals)
        }
        if model.layoutScale != layout.scale { model.layoutScale = layout.scale }
        let size = layout.panelSize
        let bleed = SidebarLayout.bleed
        let half = layout.bodyLength / 2
        let frame: NSRect
        switch preferences.edge {
        case .left, .right:
            // Along a side, fraction 0 is the top.
            let span = Self.span(visible.minY + half, visible.maxY - half)
            let center = clamp(visible.maxY - visible.height * preferences.alongFraction, span)
            let x = preferences.edge == .right ? full.maxX - size.width + bleed : full.minX - bleed
            frame = NSRect(x: x, y: center - size.height / 2, width: size.width, height: size.height)
        case .top, .bottom:
            let span = Self.span(full.minX + half, full.maxX - half)
            let center = clamp(full.minX + full.width * preferences.alongFraction, span)
            // The bottom one sits on the screen's bottom edge; the top one right
            // below the menu bar.
            let y = preferences.edge == .bottom ? full.minY - bleed : visible.maxY - size.height + bleed
            frame = NSRect(x: center - size.width / 2, y: y, width: size.width, height: size.height)
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        updateInteractiveRects()
    }

    /// lo...hi, or just the middle when the bar is longer than the room (never a
    /// range with its ends swapped, which would crash).
    private static func span(_ lo: CGFloat, _ hi: CGFloat) -> ClosedRange<CGFloat> {
        lo <= hi ? lo...hi : ((lo + hi) / 2)...((lo + hi) / 2)
    }

    private func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// What the window's frame depends on. Anything else changing (terminals
    /// coming and going, one being hidden) must not touch the window.
    private struct LayoutInputs: Equatable {
        var rings: Int
        var edge: SidebarEdge
        var size: SidebarSize
        var visibility: SidebarVisibility
        var mode: RingMode
    }

    private var lastInputs: LayoutInputs?

    private func observeLayoutInputs() {
        let inputs = withObservationTracking {
            LayoutInputs(rings: model.rings.count, edge: preferences.edge,
                         size: preferences.size, visibility: preferences.visibility, mode: preferences.ringMode)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLayoutInputs() }
        }
        defer { lastInputs = inputs }
        guard let last = lastInputs, last != inputs else { return }
        if last.visibility != inputs.visibility {
            applyVisibility()
        } else {
            relocate()
        }
    }

    /// Follows the pointer around the screen: the sidebar sticks to the edge the
    /// pointer is closest to, so dragging past a corner carries it onto the next
    /// edge (all the way round), and it never leaves the screen.
    private func drag(dx: CGFloat, dy: CGFloat) {
        let mouse = NSEvent.mouseLocation
        // The bar lives on the main display (where relocate() puts it).
        guard let screen = NSScreen.screens.first
        else { return }
        let full = screen.frame
        let visible = screen.visibleFrame
        let distances: [(SidebarEdge, CGFloat)] = [
            (.left, mouse.x - full.minX), (.right, full.maxX - mouse.x),
            (.bottom, mouse.y - full.minY), (.top, full.maxY - mouse.y),
        ]
        var edge = distances.min { $0.1 < $1.1 }!.0
        // Near a corner two edges are almost equally close: only change edge when
        // the new one is clearly closer, and not twice in a blink.
        if edge != preferences.edge {
            let current = distances.first { $0.0 == preferences.edge }!.1
            let candidate = distances.first { $0.0 == edge }!.1
            if current - candidate < 60 || Date().timeIntervalSince(lastEdgeSwitch) < 0.35 {
                edge = preferences.edge
            } else {
                lastEdgeSwitch = Date()
            }
        }
        let fraction = edge.isVertical
            ? (visible.maxY - mouse.y) / visible.height
            : (mouse.x - full.minX) / full.width
        preferences.alongFraction = Double(min(max(fraction, 0), 1))
        if preferences.edge != edge {
            preferences.edge = edge  // the layout observer moves the panel over
        } else {
            relocate()
        }
    }

    // MARK: Pointer

    private func startWatchingCursor() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // A click anywhere else lets go of a pinned card.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.model.editingProject != nil {
                    self.model.commitProjectName()
                }
                // Only clicks off the sidebar's real parts (bar, card, buttons): the panel
                // window is much bigger than what you see, and a click in its empty
                // space is a click outside.
                guard let self, self.model.pinned != nil else { return }
                let point = self.localCursor
                guard !self.hosting.interactiveRects.contains(where: { $0.contains(point) }) else { return }
                self.model.pinned = nil
                self.model.hovered = nil
                self.cursorMoved()
            }
        }) { monitors.append(clicks) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.cursorMoved() }
            return event
        }) { monitors.append(local) }
        // Backstop for moments no event arrives (Spaces switching, the pointer warping).
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
    }

    private func stopWatchingCursor() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
    }

    /// `AKI_PIN_OPEN=1` keeps it open with the first card showing (for screenshots).
    private let pinnedOpen = ProcessInfo.processInfo.environment["AKI_PIN_OPEN"] == "1"

    /// Pointer in the panel's flipped coordinates (origin top-left).
    private var localCursor: CGPoint {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    /// The card as the view reports it, grown toward the body by the gap
    /// between them so the pointer can cross over without the card closing.
    private var cardRect: CGRect? {
        guard model.expanded, model.hovered ?? model.pinned != nil, let card = model.targets["card"] else { return nil }
        let reach = SidebarLayout.tailGap + 6
        switch preferences.edge {
        case .right: return CGRect(x: card.minX, y: card.minY, width: card.width + reach, height: card.height)
        case .left: return CGRect(x: card.minX - reach, y: card.minY, width: card.width + reach, height: card.height)
        case .bottom: return CGRect(x: card.minX, y: card.minY, width: card.width, height: card.height + reach)
        case .top: return CGRect(x: card.minX, y: card.minY - reach, width: card.width, height: card.height + reach)
        }
    }

    private func cursorMoved() {
        if pinnedOpen {
            if !model.expanded { setExpanded(true) }
            // `AKI_PIN_HOVER=orb|grip|resize|none` fakes the pointer on one part (screenshots).
            let fake = ProcessInfo.processInfo.environment["AKI_PIN_HOVER"]
            model.orbHovered = fake == "orb"
            model.gripHovered = fake == "grip"
            model.markButtonHovered = fake == "mark"
            model.resizeHovered = fake == "resize"
            model.pointerInside = fake == "resize" || model.pointerInside
            if fake == "jump", model.jumping == nil, case .terminal(let t)? = model.rings.first {
                model.jumping = (t.id, TerminalJump.destinationName(for: t))
            }
            if fake == "last", !model.rings.isEmpty {
                if model.hovered != model.rings.count - 1 { model.hovered = model.rings.count - 1 }
            } else if fake != "none", model.hovered == nil, !model.rings.isEmpty { model.hovered = 0 }
            updateInteractiveRects()
            return
        }
        let point = localCursor
        // The resize corner wins over a card: the last ring's card reaches down over it
        // (its pointer), and would leave the handle lit but dead.
        let overResize = model.expanded && layout.resizeRect.contains(point)
        let overCard = !overResize && (cardRect?.contains(point) ?? false)
        // The orb at one end, the grip at the other.
        let overOrb = model.expanded && layout.orbRect.contains(point)
        let overName = model.expanded ? model.targets.first { $0.key.hasPrefix("project|") && $0.value.insetBy(dx: -3, dy: -3).contains(point) }
            .map { String($0.key.dropFirst("project|".count)) } : nil
        // A project's name wins over the grip under it (the grip would rise over the name).
        if model.resizeHovered != overResize { model.resizeHovered = overResize }
        let overGrip = model.expanded && overName == nil && !overResize && layout.gripRect.contains(point)
        let overMark = model.expanded && !overCard && layout.markOrbRect.contains(point)
        if model.markButtonHovered != overMark { model.markButtonHovered = overMark }
        // The card's other two corners (4-corner shape only).
        let overHistory = model.expanded && layout.card && !overCard && layout.historyOrbRect.contains(point)
        let overHide = model.expanded && layout.card && !overCard && layout.hideOrbRect.contains(point)
        if model.historyButtonHovered != overHistory { model.historyButtonHovered = overHistory }
        if model.hoveredProject != overName { model.hoveredProject = overName }
        let overEye = model.expanded && (model.targets["projects-eye"]?.insetBy(dx: -3, dy: -3).contains(point) ?? false)
        if model.eyeHovered != overEye { model.eyeHovered = overEye }
        let end: Int? = !(model.expanded && layout.card) || overCard ? nil
            : layout.endZone(start: true).contains(point) ? 0 : layout.endZone(start: false).contains(point) ? 1 : nil
        if model.cornerEnd != end { model.cornerEnd = end }
        if model.hideButtonHovered != overHide { model.hideButtonHovered = overHide }
        // On the drag handle: no card, right away, so nothing gets in the way.
        // A card opened by a click stays: crossing the grip on the way to it
        // mustn't close it.
        if overGrip, model.pinned == nil, model.hovered != nil {
            unhoverWork?.cancel()
            unhoverWork = nil
            model.hovered = nil
        }
        if model.orbHovered != overOrb { model.orbHovered = overOrb }
        if model.gripHovered != overGrip { model.gripHovered = overGrip }
        let overUpdate = model.targets["update|now"]?.insetBy(dx: -3, dy: -3).contains(point) ?? false
        let target = overCard ? model.target(at: point).flatMap { $0 == "card" ? nil : $0 } : (overUpdate ? "update|now" : nil)
        if model.hoveredTarget != target { model.hoveredTarget = target }
        setCursor(overResize ? Self.resizeCursor(layout.resizeDirection) : overGrip ? .openHand
            : (overOrb || overMark || overHistory || overHide || overName != nil || overEye || target != nil) ? .pointingHand : nil)

        let keepOpen = preferences.visibility == .alwaysShow || model.pinned != nil || model.editingProject != nil
        let inside = model.expanded
            ? layout.bodyRect(expanded: true).insetBy(dx: -6, dy: -6).contains(point) || overCard || overOrb || overGrip || overResize
                || overMark || overHistory || overHide
                || model.targets.contains { ($0.key.hasPrefix("project|") || $0.key == "projects-eye") && $0.value.insetBy(dx: -4, dy: -4).contains(point) }
            : layout.wakeRect.contains(point)

        let lit = model.expanded && inside
        if model.pointerInside != lit { model.pointerInside = lit }
        // A card opened by a click: stays while you're around, goes 3 s after you leave.
        if model.pinned != nil, model.expanded, !inside {
            if pinnedAwayWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pinnedAwayWork = nil
                        self.model.pinned = nil
                        self.cursorMoved()
                    }
                }
                pinnedAwayWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            }
        } else if pinnedAwayWork != nil {
            pinnedAwayWork?.cancel()
            pinnedAwayWork = nil
        }

        if inside || keepOpen {
            foldWork?.cancel()
            foldWork = nil
            if !model.expanded { setExpanded(true) }
        } else if model.expanded, foldWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.foldWork = nil
                    self?.setExpanded(false)
                }
            }
            foldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.foldGrace, execute: work)
        }

        if model.expanded, model.jumping == nil {
            // On the drag handle or the shortcut, no card opens.
            let index = model.rings.isEmpty || overMark || overGrip || overHistory || overHide ? nil : layout.cellIndex(at: point)
            if let index {
                unhoverWork?.cancel()
                unhoverWork = nil
                if model.hovered != index {
                    if model.hovered == nil { TerminalJump.prefetch() }
                    model.hovered = index
                }
            } else if model.hovered != nil, !overCard, unhoverWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.unhoverWork = nil
                        self?.model.hovered = nil
                    }
                }
                unhoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverGrace, execute: work)
            }
        }
        updateInteractiveRects(cursor: point)
    }

    private func setExpanded(_ expanded: Bool) {
        // Until the sessions are in, it stays a pill (an empty open body looks broken).
        if expanded, !model.loaded { return }
        if model.expanded != expanded { model.expanded = expanded }
        if !expanded {
            model.pinned = nil
            model.hovered = nil
            model.orbHovered = false
            model.gripHovered = false
            model.markButtonHovered = false
            model.historyButtonHovered = false
            model.hideButtonHovered = false
            unhoverWork?.cancel()
            unhoverWork = nil
        }
        updateInteractiveRects()
    }

    /// Clicks land only on what's visible; everywhere else the panel is a hole.
    private func updateInteractiveRects(cursor: CGPoint? = nil) {
        var rects = [layout.bodyRect(expanded: model.expanded)]
        // The update pill shows folded or open: always clickable.
        if let pill = model.targets["update|now"] { rects.append(pill) }
        if model.expanded { rects.append(layout.orbRect) }
        if model.expanded { rects.append(layout.gripRect) }
        if model.expanded { rects.append(layout.markOrbRect) }
        if model.expanded, layout.card { rects += [layout.historyOrbRect, layout.hideOrbRect] }
        if model.expanded { rects.append(layout.resizeRect) }
        // Project names over the groups (double-click renames).
        if model.expanded {
            rects += model.targets.filter { $0.key.hasPrefix("project|") || $0.key == "projects-eye" || $0.key == "update|now" }.map(\.value)
        }
        if let cardRect { rects.append(cardRect) }
        hosting.interactiveRects = rects
        let point = cursor ?? localCursor
        let ignores = !rects.contains { $0.contains(point) }
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    // MARK: Marking

    /// Where a conversation's ring is on screen (global, bottom-left origin), so
    /// sent marks can fly to it. Falls back to the "+N" ring, then the body.
    func screenLocation(of terminalID: String?) -> NSPoint? {
        guard panel.isVisible else { return nil }
        let rings = model.rings
        let index = rings.firstIndex { if case .terminal(let t) = $0 { return t.id == terminalID } else { return false } }
            ?? rings.firstIndex { if case .more = $0 { return true } else { return false } }
        let local = index.map { layout.cellCenter($0) }
            ?? CGPoint(x: layout.bodyRect(expanded: false).midX, y: layout.bodyRect(expanded: false).midY)
        return NSPoint(x: panel.frame.minX + local.x, y: panel.frame.maxY - local.y)
    }

    /// Just past the bar's far end (screen coordinates): where marking's folded
    /// hint dot docks, so it's found next to Aki itself.
    func dockSpot() -> NSPoint? {
        guard panel.isVisible else { return nil }
        let body = layout.bodyRect(expanded: model.expanded)
        let local = preferences.edge.isVertical
            ? CGPoint(x: body.midX, y: body.maxY + 26 * layout.scale)
            : CGPoint(x: body.maxX + 30 * layout.scale, y: body.midY)
        return NSPoint(x: panel.frame.minX + local.x, y: panel.frame.maxY - local.y)
    }

    /// Opens for a moment to show the rings that just received marks, which pulse.
    func showDelivery(to terminalIDs: [String]) {
        guard preferences.visibility != .hidden else { return }
        model.flashed = Set(terminalIDs)
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.model.flashed = []
        }
        foldWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldWork = nil
                let point = self.localCursor
                let inside = self.layout.bodyRect(expanded: true).insetBy(dx: -6, dy: -6).contains(point)
                if !inside && self.preferences.visibility != .alwaysShow { self.setExpanded(false) }
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    // MARK: Clicks

    /// A click on a ring pins its card (or lets it go). Returns whether it was handled.
    /// `AKI_SELFTEST=eye` clicks the first terminal's eye through the real click path.
    func selfTest() {
        guard let kind = ProcessInfo.processInfo.environment["AKI_SELFTEST"] else { return }
        if kind == "jump" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                guard let t = model.terminals.first(where: { $0.name == "AKI APP" }) else { return log("no AKI APP") }
                TerminalJump.go(to: t)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            let rowKey = model.targets.keys.sorted().first { $0.hasPrefix("row|") }
            log("targets: \(model.targets.keys.sorted())")
            guard let rowKey, let row = model.targets[rowKey] else { return log("no rows") }
            model.hoveredTarget = rowKey  // shows the eye
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                let key = kind == "eye" ? "eye|" + rowKey.dropFirst(4) : rowKey
                guard let rect = model.targets[key] else { return log("no target \(key)") }
                let window = CGPoint(x: rect.midX, y: panel.frame.height - rect.midY)
                log("click \(key) -> \(click(at: window, count: 1)); hidden=\(preferences.hiddenWorktrees) selected=\(model.selected ?? "-") row=\(row)")
            }
        }
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("selftest: \(text)\n".utf8))
    }

    private func click(at windowPoint: CGPoint, count: Int = 1) -> Bool {
        let point = CGPoint(x: windowPoint.x, y: panel.frame.height - windowPoint.y)
        // Typing a project's name: a click anywhere else keeps it.
        if model.editingProject != nil,
            !model.targets.contains(where: { $0.key == "project|" + (model.editingProject ?? "") && $0.value.contains(point) })
        {
            model.commitProjectName()
        }
        guard model.expanded else { return false }
        if !(cardRect?.contains(point) ?? false), layout.markOrbRect.contains(point) {
            setExpanded(false)
            model.startMarking()
            return true
        }
        if layout.card, !(cardRect?.contains(point) ?? false) {
            if layout.historyOrbRect.contains(point) {
                openHistory()
                return true
            }
            if layout.hideOrbRect.contains(point) {
                // Keep open: the sidebar stays up instead of waiting for the pointer.
                preferences.visibility = preferences.visibility == .alwaysShow ? .onHover : .alwaysShow
                return true
            }
        }
        // The update pill: install what's waiting (it downloads right in the pill), or look again.
        if let pill = model.targets["update|now"], pill.insetBy(dx: -3, dy: -3).contains(point) {
            Updates.shared.tap()
            return true
        }
        // A project's name (the pencil shows on hover): one click and you type.
        if let name = model.targets.first(where: { $0.key.hasPrefix("project|") && $0.value.insetBy(dx: -3, dy: -3).contains(point) }) {
            if model.editingProject == nil { startEditingProject(String(name.key.dropFirst("project|".count))) }
            return true
        }
        // The eye: projects' names on or off.
        if let eye = model.targets["projects-eye"], eye.insetBy(dx: -3, dy: -3).contains(point) {
            withAnimation(.easeOut(duration: 0.2)) { preferences.showProjects.toggle() }
            return true
        }
        if layout.orbRect.contains(point) {
            model.settingsSpins += 1
            openSettings()
            return true
        }
        if let cardRect, cardRect.contains(point) {
            // A click in the card keeps it open, so you see what the click did.
            if model.pinned == nil { model.pinned = model.hovered }
            if let target = model.target(at: point) {
                // Twice on a session's line (in the +N list too): go to its terminal.
                let now = Date()
                let twice = target.hasPrefix("term|")
                    && (count >= 2 || (lastCardClick.map { $0.key == target && now.timeIntervalSince($0.at) < NSEvent.doubleClickInterval } ?? false))
                lastCardClick = twice ? nil : (target, now)
                if twice, let terminal = model.terminals.first(where: { "term|" + $0.id == target }) {
                    model.pinned = nil
                    model.hovered = nil
                    TerminalJump.go(to: terminal)
                    if preferences.visibility != .alwaysShow { setExpanded(false) }
                    return true
                }
                _ = model.perform(target)
            }
            return true  // a click on the card never falls through
        }
        guard let index = layout.cellIndex(at: point), index < model.rings.count else {
            // A click on the bar but off the card and the rings: the open card goes.
            if model.pinned != nil {
                model.pinned = nil
                model.hovered = nil
                return true
            }
            return false
        }
        // The panel never becomes active, so AppKit may not count a second click
        // as a double one: same ring again within the system's interval counts.
        let now = Date()
        let isDouble = count >= 2
            || (lastClick.map { $0.index == index && now.timeIntervalSince($0.at) < NSEvent.doubleClickInterval } ?? false)
        lastClick = isDouble ? nil : (index, now)
        if case .terminal(let terminal) = model.rings[index] {
            // Twice: go to it (its Orca tab, or the app it runs in).
            if isDouble {
                model.jumping = (terminal.id, TerminalJump.destinationName(for: terminal))
                model.pinned = nil
                model.hovered = nil
                TerminalJump.go(to: terminal)
                // The launch reads for a beat, then the sidebar gets out of the way.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self else { return }
                    self.model.jumping = nil
                    if self.preferences.visibility != .alwaysShow { self.setExpanded(false) }
                }
                return true
            }
            // Once: it's where new marks go, and its card stays open (a click
            // outside, or 3 s away from it, closes it).
            model.select(terminal)
            model.pinned = index
            model.hovered = index
            return true
        }
        model.pinned = model.pinned == index ? nil : index
        model.hovered = index
        return true
    }

    // MARK: Menu

    /// "Move marks to…" from a card: the other sessions, at the pointer.
    private func showMoveMenu(for terminal: AgentTerminal) {
        let menu = NSMenu()
        for other in model.allTerminals where other.id != terminal.id {
            let title = model.number(of: other.id).map { "\($0)  \(other.name)" }
                ?? "\(other.name) — \(URL(filePath: other.worktree).lastPathComponent)"
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.model.moveMarks(from: terminal, to: other) })
        }
        let mouse = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY), in: panel.contentView)
    }

    /// Turns a project's name into a field over its group: Enter keeps it, esc
    /// leaves it, a click elsewhere keeps it too. Empty brings back the automatic one.
    private func startEditingProject(_ key: String) {
        previousAppForEditing = NSWorkspace.shared.frontmostApplication
        model.projectDraft = model.projectLabel(key)
        model.editingProject = key
        panel.allowsKey = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func finishEditingProject() {
        panel.allowsKey = false
        panel.resignKey()
        if let app = previousAppForEditing, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
        previousAppForEditing = nil
    }

    private func menu(at windowPoint: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        // On a session's ring: what you can do with that session, first.
        let point = CGPoint(x: windowPoint.x, y: panel.frame.height - windowPoint.y)
        if model.expanded, let index = layout.cellIndex(at: point), index < model.rings.count,
            case .terminal(let terminal) = model.rings[index]
        {
            let title = NSMenuItem(title: terminal.name, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let send = ClosureMenuItem(L10n.t("Send marks here")) { [weak self] in self?.model.select(terminal) }
            send.state = model.selectedTerminal == terminal.id ? .on : .off
            menu.addItem(send)
            menu.addItem(ClosureMenuItem(L10n.t("Open in terminal")) { TerminalJump.go(to: terminal) })
            let projectKey = model.projectKey(of: terminal)
            menu.addItem(ClosureMenuItem("\(L10n.t("Rename project")) “\(model.projectLabel(projectKey))”…") { [weak self] in
                self?.startEditingProject(projectKey)
            })
            menu.addItem(ClosureMenuItem(L10n.t("Hide this session")) { [weak self] in
                self?.model.preferences.hiddenTerminals.insert(terminal.id)
            })
            menu.addItem(ClosureMenuItem(L10n.t("Open in Finder")) {
                NSWorkspace.shared.open(URL(filePath: terminal.worktree))
            })
            menu.addItem(ClosureMenuItem(L10n.t("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(terminal.worktree, forType: .string)
            })
            let others = model.allTerminals.filter { $0.id != terminal.id }
            if terminal.pending > 0, !others.isEmpty {
                // Its queue, handed to another session (numbered as on the rings).
                let item = NSMenuItem(
                    title: "\(L10n.t("Move marks to")) (\(terminal.pending))", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for (i, other) in others.enumerated() {
                    let number = model.number(of: other.id)
                    if number == nil, i > 0, model.number(of: others[i - 1].id) != nil { submenu.addItem(.separator()) }
                    let title = number.map { "\($0)  \(other.name)" }
                        ?? "\(other.name) — \(URL(filePath: other.worktree).lastPathComponent)"
                    submenu.addItem(ClosureMenuItem(title) { [weak self] in
                        self?.model.moveMarks(from: terminal, to: other)
                    })
                }
                item.submenu = submenu
                menu.addItem(item)
            }
            if terminal.pending > 0 {
                menu.addItem(ClosureMenuItem("\(L10n.t("Mark as Resolved")) (\(terminal.pending))") { [weak self] in
                    self?.model.resolveAll(in: terminal)
                })
            }
            menu.addItem(.separator())
        }
        if !model.preferences.hiddenTerminals.isEmpty {
            let hidden = model.terminals.filter { model.preferences.hiddenTerminals.contains($0.id) }
            if !hidden.isEmpty {
                let item = NSMenuItem(title: L10n.t("Hidden sessions"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for terminal in hidden {
                    submenu.addItem(ClosureMenuItem(terminal.name) { [weak self] in
                        self?.model.preferences.hiddenTerminals.remove(terminal.id)
                    })
                }
                submenu.addItem(.separator())
                submenu.addItem(ClosureMenuItem(L10n.t("Show all")) { [weak self] in
                    self?.model.preferences.hiddenTerminals.removeAll()
                })
                item.submenu = submenu
                menu.addItem(item)
                menu.addItem(.separator())
            }
        }
        let keepOpen = ClosureMenuItem(L10n.t("Keep open")) { [weak self] in
            guard let self else { return }
            self.preferences.visibility = self.preferences.visibility == .alwaysShow ? .onHover : .alwaysShow
        }
        keepOpen.state = preferences.visibility == .alwaysShow ? .on : .off
        menu.addItem(keepOpen)
        let projects = ClosureMenuItem(L10n.t("Show projects")) { [weak self] in
            self?.preferences.showProjects.toggle()
        }
        projects.state = preferences.showProjects ? .on : .off
        menu.addItem(projects)
        let hide = ClosureMenuItem(L10n.t("Hide the sidebar")) { [weak self] in
            self?.preferences.visibility = .hidden
        }
        hide.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        menu.addItem(hide)
        menu.addItem(.separator())
        let refresh = ClosureMenuItem(L10n.t("Refresh now")) { [weak self] in
            Task { await self?.model.refresh() }
        }
        refresh.keyEquivalent = "r"
        menu.addItem(refresh)
        menu.addItem(ClosureMenuItem("\(L10n.t("History"))   \(L10n.history)") { [weak self] in self?.openHistory() })
        menu.addItem(ClosureMenuItem(L10n.t("Check for Updates…")) { Updates.shared.checkForUpdates() })
        let settings = ClosureMenuItem(L10n.t("Settings…")) { [weak self] in self?.openSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = ClosureMenuItem(L10n.t("Quit Aki")) { [weak self] in self?.quit() }
        quit.keyEquivalent = "q"
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }
}

/// Borderless, non-activating panel above everything, on every Space. The
/// right-click menu is handled here because SwiftUI's subviews may swallow it;
/// ⌥-drag moves the sidebar along its edge. Plain clicks go to SwiftUI.
final class SidebarPanel: NSPanel {
    var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// Plain left click on the chrome (with its click count); true when handled.
    var onClick: ((CGPoint, Int) -> Bool)?
    /// Whether a press here carries the sidebar without ⌥ (the grip).
    var startsDrag: ((CGPoint) -> Bool)?
    /// Whether a press here is on a session's ring, which can be dragged to reorder.
    var pressReorders: ((CGPoint) -> Bool)?
    var onReorderDrag: ((CGPoint, CGPoint) -> Void)?
    var onReorderEnd: ((CGPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    /// The resize corner: whether a press there resizes, then the pointer on screen.
    var startsResize: ((CGPoint) -> Bool)?
    var onResize: ((CGPoint) -> Void)?
    var onResizeEnd: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        // Without this, AppKit sends no mouse-moved events while the pointer is
        // over the panel itself, and hover inside the card lags behind the pointer.
        acceptsMouseMovedEvents = true
    }

    /// Only while a project's name is being typed.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if SidebarRoot.debugTargets, [.leftMouseDown, .rightMouseDown].contains(event.type) {
            FileHandle.standardError.write(Data("event \(event.type.rawValue) at \(event.locationInWindow)\n".utf8))
        }
        if event.type == .rightMouseDown, let view = contentView,
            view.hitTest(event.locationInWindow) != nil,
            let menu = contextMenuProvider?(event.locationInWindow)
        {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        if event.type == .leftMouseDown, startsResize?(event.locationInWindow) == true {
            while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    onResizeEnd?()
                    return
                }
                onResize?(NSEvent.mouseLocation)
            }
            return
        }
        if event.type == .leftMouseDown, let view = contentView, view.hitTest(event.locationInWindow) != nil,
            event.modifierFlags.contains(.option) || startsDrag?(event.locationInWindow) == true
        {
            while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    onDragEnd?()
                    return
                }
                onDrag?(next.deltaX, next.deltaY)
            }
            return
        }
        if event.type == .leftMouseDown {
            if SidebarRoot.debugTargets {
                FileHandle.standardError.write(Data("click count=\(event.clickCount)\n".utf8))
            }
            // Pressed on a session's ring: a drag reorders, anything else is a click.
            if pressReorders?(event.locationInWindow) == true {
                let start = event.locationInWindow
                var moved = false
                while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    let point = next.locationInWindow
                    if next.type == .leftMouseUp {
                        if moved {
                            onReorderEnd?(point)
                        } else {
                            _ = onClick?(start, event.clickCount)
                        }
                        return
                    }
                    if !moved, hypot(point.x - start.x, point.y - start.y) > 4 { moved = true }
                    if moved { onReorderDrag?(start, point) }
                }
                return
            }
            if onClick?(event.locationInWindow, event.clickCount) == true { return }
        }
        super.sendEvent(event)
    }
}

/// Holds the hosting view so SwiftUI never sizes the window, and never claims
/// a point itself.
final class PassThroughContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

/// Answers hit tests only inside `interactiveRects` (flipped, top-left origin).
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

extension NSMenuItem {
    /// Sets its shortcut and returns it (for building menus inline).
    func with(key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> Self {
        keyEquivalent = key
        keyEquivalentModifierMask = modifiers
        return self
    }
}
