import AkiCore
import AppKit
import SwiftUI

/// The frozen, dimmed screen you mark on. Click for a numbered point, drag for an
/// area; each mark takes the colour of the conversation it goes to.
struct MarkingView: View {
    let session: MarkingSession
    let screen: Int
    /// Where marks fly to when sent (the destination's ring), in this view's space.
    let target: (String?) -> CGPoint?
    /// Beside the sidebar, in this view's space (the folded hint dot goes there).
    let dockSpot: () -> CGPoint?
    let send: () -> Void
    /// Sends one mark and keeps the rest of the queue.
    let sendOnly: (UUID) -> Void
    let close: () -> Void
    /// Leaves and forgets the queue (its ×); `close` keeps it for next time.
    let discard: () -> Void
    /// ⇧-click: a plain click on the app below, at this global point (top-left origin).
    var passClick: (CGPoint) -> Void = { _ in }

    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    /// The comment card's measured height (placement keeps all of it on screen).
    @State private var cardHeight: CGFloat = 420
    @State private var queueHeight: CGFloat = 160
    /// The hint bar being dragged (added to where it was left).
    @State private var hintDrag: CGSize = .zero
    @State private var hintWidth: CGFloat = 900
    /// Where the queue was when you started editing from it: it stays put while you
    /// go through its marks, and moves again only for a new mark.
    @State private var queueAnchor: CGPoint?
    /// Where you dragged the queue to (on top of where it sits by itself).
    @State private var queueDrag: CGSize = .zero
    @State private var queueDragging: CGSize = .zero
    /// Where the queue was moved while the sessions list is open (gone when it closes).
    @State private var listQueueDrag: CGSize = .zero
    @State private var queueHandleHovered = false
    /// Words typed in the "+N" list to find a session.
    @State private var moreQuery = ""
    @FocusState private var moreSearchFocused: Bool
    /// Where you dragged the comment card to (on top of where it opens by itself).
    @State private var cardDrag: CGSize = .zero
    @State private var cardDragging: CGSize = .zero
    @State private var cardHandleHovered = false
    @State private var moreDrag: CGSize = .zero
    @State private var moreDragging: CGSize = .zero
    @State private var moreHandleHovered = false
    @FocusState private var fieldFocused: Bool

    private var grab: ScreenGrab { session.grabs[screen] }
    private var isMain: Bool { screen == 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: grab.image, scale: grab.scale)
                .resizable()
                .frame(width: grab.screen.frame.width, height: grab.screen.frame.height)
                // Live by default: the screen keeps running underneath (Settings can freeze it).
                .opacity(session.scrolling || session.live ? 0 : 1)
            // Barely dimmed: you need to see the screen as it is.
            Color.black.opacity(session.flying ? 0 : 0.06)
                .animation(.easeOut(duration: 0.3), value: session.flying)
            // A thin frame in Aki's own colours (not the session's) says you're marking.
            Rectangle()
                .strokeBorder(AkiPalette.auroraDiagonal, lineWidth: 2)
                .opacity(session.flying || session.scrolling ? 0 : 0.9)
                .allowsHitTesting(false)

            // Clicks and drags land here, under the marks.
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard case .active(let location) = phase, dragStart == nil else { return }
                    // On the screen being marked (not a card or button): always the pin, whatever
                    // the system or the app below set meanwhile.
                    if session.shiftHeld {
                        if NSCursor.current !== NSCursor.arrow { NSCursor.arrow.set() }
                    } else if NSCursor.current !== AkiCursor.pin { AkiCursor.set(AkiCursor.pin) }
                    session.pointer[screen] = location
                    if session.optionHeld {
                        session.updateLineHover(screen: screen)
                    } else {
                        session.probe(at: globalPoint(location))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil { dragStart = value.startLocation }
                            dragNow = value.location
                        }
                        .onEnded { value in
                            let start = value.startLocation, end = value.location
                            let moved = hypot(end.x - start.x, end.y - start.y)
                            // The click that put a zoomed picture away: just that.
                            if ImageZoom.isOpen || Date().timeIntervalSince(ImageZoom.closedAt) < 0.4 {
                                dragStart = nil
                                dragNow = nil
                                return
                            }
                            let point = NSEvent.modifierFlags.contains(.command)
                            // ⇧-click: a normal click on what's below (another sheet, a link), no mark.
                            if moved < 5, NSEvent.modifierFlags.contains(.shift) {
                                dragStart = nil
                                dragNow = nil
                                passClick(globalPoint(start))
                                return
                            }
                            var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y))
                            var element: ProbedElement?
                            var text: String?
                            if NSEvent.modifierFlags.contains(.option), let screenText = session.texts[screen] {
                                // ⌥: whole lines of text — the one clicked, or every line dragged over.
                                let lines = moved < 5
                                    ? screenText.line(at: start).map { [$0] } ?? []
                                    : screenText.lines(in: rect.insetBy(dx: -2, dy: -2))
                                if let first = lines.first {
                                    rect = lines.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                                    text = lines.map(\.text).joined(separator: "\n")
                                }
                            } else if moved < 5, !point, let row = canvasRow(at: start) {
                                // A spreadsheet's row (a canvas has no elements): its cells' text.
                                rect = row.rect
                                text = row.text
                            } else if moved < 5 {
                                // A click: the outlined element, or a point with ⌘ (or nothing outlined).
                                if !point, let hovered = session.target, let local = localRect(hovered.frame) {
                                    rect = local
                                    element = hovered
                                } else {
                                    rect = CGRect(origin: start, size: .zero)
                                }
                            }
                            // Not while the marks fly off (it'd be left behind).
                            if !session.flying && !session.sending {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    session.add(screen: screen, rect: rect, element: element, anchor: end, text: text)
                                }
                            }
                            dragStart = nil
                            dragNow = nil
                            fieldFocused = true
                        })

            if let dragStart, let dragNow, hypot(dragNow.x - dragStart.x, dragNow.y - dragStart.y) >= 5 {
                let rect = CGRect(x: min(dragStart.x, dragNow.x), y: min(dragStart.y, dragNow.y),
                                  width: abs(dragNow.x - dragStart.x), height: abs(dragNow.y - dragStart.y))
                let hue = Color(session.hue(for: session.destination))
                Rectangle().fill(hue.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(hue, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }

            if session.optionHeld, dragStart == nil, session.editing == nil, !session.flying, let hovered = session.hoveredLine,
                hovered.screen == screen
            {
                let hue = Color(session.hue(for: session.destination))
                lineHighlight(hovered.line.rect, label: String(hovered.line.text.prefix(48)), hue: hue)
            }
            if session.optionHeld, let dragStart, let dragNow, let screenText = session.texts[screen] {
                let hue = Color(session.hue(for: session.destination))
                let area = CGRect(x: min(dragStart.x, dragNow.x), y: min(dragStart.y, dragNow.y),
                                  width: abs(dragNow.x - dragStart.x), height: abs(dragNow.y - dragStart.y))
                ForEach(Array(screenText.lines(in: area).enumerated()), id: \.offset) { _, line in
                    Rectangle().fill(hue.opacity(0.28))
                        .frame(width: line.rect.width, height: line.rect.height)
                        .offset(x: line.rect.minX, y: line.rect.minY)
                        .allowsHitTesting(false)
                }
            }
            // No outline while dragging an area or writing a comment: nothing gets
            // pre-selected under the pointer then.
            if let row = canvasRow {
                lineHighlight(row.rect, label: String(row.text.prefix(48)), hue: Color(session.hue(for: session.destination)))
            } else if let hovered = session.target, !session.optionHeld, !session.shiftHeld, dragStart == nil, session.editing == nil, !session.flying,
                let rect = localRect(hovered.frame)
            {
                let hue = Color(session.hue(for: session.destination))
                // As on the site: four corners around it (in the session's colour), and the selector on a
                // dark tag above (below when there's no room), gliding between elements.
                let above = rect.minY > 40
                // A touch outside the element, so the corners don't sit on its edge; but
                // never past the screen's edges (a whole page fills the screen: all four
                // sides must still show).
                let screenSize = grab.screen.frame.size
                let box = rect.insetBy(dx: -3, dy: -3)
                    .intersection(CGRect(origin: .zero, size: screenSize).insetBy(dx: 4, dy: 4))
                // No room above nor below: the tag goes inside, at the top.
                let tagInside = !above && box.maxY + 44 > screenSize.height
                ZStack(alignment: .topLeading) {
                    // A faint tint and a thin line show the whole box; the corners make
                    // it read at a glance, with a dark halo so they show on any page.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hue.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hue.opacity(0.7), lineWidth: 1.25))
                        .frame(width: max(box.width, 8), height: max(box.height, 8))
                    CornerBrackets(arm: 18)
                        .stroke(hue, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .frame(width: max(box.width, 8), height: max(box.height, 8))
                    PickTag(label: hovered.label, walks: true, above: above)
                        .fixedSize()
                        // About 26 pt tall, 8 pt off the frame (an offset leaves the frame where it is).
                        .offset(x: tagInside ? 10 : 0, y: above ? -36 : tagInside ? 10 : max(box.height, 8) + 8)
                }
                .offset(x: box.minX, y: box.minY)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: hovered)
            }

            ForEach(session.marks.filter { $0.screen == screen && $0.generation == session.generation[screen, default: 0] }) { mark in
                MarkShape(mark: mark, hue: Color(session.hue(for: mark.destination)), flying: session.flying,
                          target: target(mark.destination),
                          preview: mark.sendsImage ? session.previewImage(of: mark) : nil)
            }

            if let editing = session.editing, let mark = session.marks.first(where: { $0.id == editing }),
                mark.screen == screen, !session.flying
            {
                commentCard(for: mark)
                    // Its "+N" list hangs off it: over the queue while it's open.
                    .zIndex(session.listOpen ? 2 : 1)
            }

            // The queue, bottom-right of the main screen, once there's something in it.
            // The queue sits beside what you're doing: next to the comment card, or
            // the last mark — not off in a corner.
            if !session.flying, session.marks.contains(where: { $0.id != session.editing }), queueScreen == screen {
                // With the sessions list open the queue makes way, even when it was anchored.
                // (Where you dragged it is set aside meanwhile: it was beside the old spot.)
                let spot = session.listOpen ? queueSpot : (queueAnchor ?? queueSpot)
                let kept = session.listOpen ? listQueueDrag : queueDrag
                let drag = CGSize(width: kept.width + queueDragging.width, height: kept.height + queueDragging.height)
                queuePanel
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { queueHeight = $0 }
                    .offset(x: min(max(spot.x + drag.width, 12), grab.screen.frame.width - 242),
                            y: min(max(spot.y + drag.height, 12), grab.screen.frame.height - queueHeight - 12))
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: spot)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .onChange(of: session.marks.count) { old, new in if new > old { queueAnchor = nil } }
                    .onChange(of: session.listOpen) { listQueueDrag = .zero }
            }

            if isMain && !session.flying {
                // Folded, it docks beside the sidebar, where you'll look for Aki.
                if Preferences.shared.hintsFolded, let spot = dockSpot() {
                    // Whole on screen, even with the bar folded against the edge.
                    let size = grab.screen.frame.size
                    foldedDot.position(x: min(max(spot.x, 50), size.width - 50), y: min(max(spot.y, 26), size.height - 26))
                } else {
                    VStack {
                        Spacer()
                        hints
                    }
                    .frame(width: grab.screen.frame.width, height: grab.screen.frame.height)
                }
            }
        }
        .frame(width: grab.screen.frame.width, height: grab.screen.frame.height, alignment: .topLeading)
        // Another mark's card opens where it belongs, not where the last one was dragged
        // (watched here: the card's own view is gone between marks).
        .onChange(of: session.editing) { if session.editing != nil { cardDrag = .zero } }
        .environment(\.colorScheme, .dark)
    }

    /// Over a spreadsheet (or anything drawn as one canvas) there are no elements
    /// to point at: the row under the pointer, read from the screen, instead.
    private var canvasRow: ScreenText.Line? {
        guard dragStart == nil, session.editing == nil, let point = session.pointer[screen] else { return nil }
        return canvasRow(at: point)
    }

    private func canvasRow(at point: CGPoint) -> ScreenText.Line? {
        guard !session.optionHeld, !session.shiftHeld, !session.flying,
              let target = session.target, session.level == 0, target.label.lowercased().hasPrefix("canvas"),
              let bounds = localRect(target.frame), let text = session.texts[screen]
        else { return nil }
        return text.row(at: point, within: bounds)
    }

    private func lineHighlight(_ rect: CGRect, label: String, hue: Color) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(hue.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(hue, lineWidth: 1.5))
                .frame(width: rect.width, height: rect.height)
            HStack(spacing: 5) {
                Image(systemName: "text.cursor").font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(hue))
            .fixedSize()
            .offset(y: rect.minY > 22 ? -22 : rect.height + 2)
        }
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    // MARK: Coordinates

    /// Height of the main display: CoreGraphics' global space starts at its top.
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? grab.screen.frame.height }

    private func globalPoint(_ local: CGPoint) -> CGPoint {
        let frame = grab.screen.frame
        return CGPoint(x: frame.minX + local.x, y: primaryHeight - frame.maxY + local.y)
    }

    /// A global rect in this screen's view space, nil when it's on another screen.
    private func localRect(_ global: CGRect) -> CGRect? {
        let frame = grab.screen.frame
        let rect = global.offsetBy(dx: -frame.minX, dy: -(primaryHeight - frame.maxY))
        let bounds = CGRect(origin: .zero, size: frame.size)
        let clipped = rect.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    // MARK: Comment

    /// Where the "+N" list of other sessions opens beside the card: right; below when the
    /// card sits against the right edge; left only when neither fits.
    private enum ListSide { case right, below, left }

    private func listSide(card: CGRect) -> ListSide {
        let bounds = grab.screen.frame.size
        if card.maxX + 10 + 240 <= bounds.width - 12 { return .right }
        if card.maxY + 10 + 380 <= bounds.height - 12 { return .below }
        return .left
    }

    /// The card's box on its screen (top-left origin), as drawn.
    private func cardBox(for mark: Mark) -> CGRect {
        let width: CGFloat = 340
        let size = CGSize(width: width, height: max(cardHeight, 200))
        let origin: CGPoint = queueAnchor.map { q in
            let bounds = grab.screen.frame.size
            var x = q.x - 12 - width
            if x < 12 { x = q.x + 230 + 12 }
            return CGPoint(x: min(max(x, 12), bounds.width - width - 12),
                           y: min(max(q.y, 12), bounds.height - bottomReserve - size.height))
        } ?? placement(near: mark.anchor, size: size)
        let screenSize = grab.screen.frame.size
        let x = min(max(origin.x + cardDrag.width + cardDragging.width, 12), screenSize.width - width - 12)
        let y = min(max(origin.y + cardDrag.height + cardDragging.height, 12), screenSize.height - min(cardHeight, screenSize.height - 24) - 12)
        return CGRect(x: x, y: y, width: width, height: cardHeight)
    }

    private func commentCard(for mark: Mark) -> some View {
        let hue = Color(session.hue(for: mark.destination))
        let width: CGFloat = 340
        // Its real height (crop, text and field make it tall), so it never runs off the screen.
        let size = CGSize(width: width, height: max(cardHeight, 200))
        // Editing from the queue: the card opens right beside it (left, or right when
        // there's no room), level with it — neither moves while you go through the marks.
        let origin: CGPoint = queueAnchor.map { q in
            let bounds = grab.screen.frame.size
            var x = q.x - 12 - width
            if x < 12 { x = q.x + 230 + 12 }
            return CGPoint(x: min(max(x, 12), bounds.width - width - 12),
                           y: min(max(q.y, 12), bounds.height - bottomReserve - size.height))
        } ?? placement(near: mark.anchor, size: size)
        // Dragged, but never off its screen (each screen draws only its own card).
        let screenSize = grab.screen.frame.size
        let x = min(max(origin.x + cardDrag.width + cardDragging.width, 12), screenSize.width - width - 12)
        let y = min(max(origin.y + cardDrag.height + cardDragging.height, 12), screenSize.height - min(cardHeight, screenSize.height - 24) - 12)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(mark.number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(hue))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(L10n.t("Send to"))
                        if let terminal = session.terminal(mark.destination) {
                            SessionIdentityView(identity: SessionIdentity(terminal: terminal), size: 12)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    Text(session.terminal(mark.destination)?.name ?? L10n.t("No destination"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hue)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            terminalPicker
            if session.terminal(mark.destination) == nil {
                Label(L10n.t("This session closed. Choose another destination."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            selection(of: mark, hue: hue)
            TextField(L10n.t("What should change here?"), text: Binding(
                get: { session.draft }, set: { session.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(4...10)
                .frame(minHeight: 84, alignment: .topLeading)
                .focused($fieldFocused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                .onSubmit {
                    if session.draft.trimmingCharacters(in: .whitespaces).isEmpty {
                        send()
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { session.commitDraft() }
                    }
                }
            // Two rows so nothing runs past the card: where it goes and the keys, then the buttons.
            HStack(spacing: 8) {
                destinationMenu
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    KeyButton(key: "⇥", label: nil, help: L10n.t("Next session")) { session.cycleDestination() }
                    KeyButton(key: "esc", label: nil, help: L10n.t("Leave")) { close() }
                }
                .fixedSize()
                .help(L10n.t("⇥ next session · esc leave"))
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                buttons
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 20)
        .frame(width: width, alignment: .leading)
        // The grab handle: centred on the card's top edge, in its own strip.
        .overlay(alignment: .top) {
                // Its top is a handle: drag the card off what you want to see.
                // The same six dots as the sidebar's handle: every grab spot looks alike.
                GripDots(vertical: false, hovered: cardHandleHovered, scale: 0.85, tint: .white, backdrop: Color.white.opacity(0.08))
                    .padding(.top, 3)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            cardHandleHovered = true
                            AkiCursor.set(cardDragging == .zero ? NSCursor.openHand : NSCursor.closedHand)
                        case .ended:
                            cardHandleHovered = false
                            AkiCursor.set(AkiCursor.pin)
                        }
                    }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { cardDragging = $0.translation; AkiCursor.set(NSCursor.closedHand) }
                        .onEnded { value in
                            // Keep where it shows (stopped at the screen's edge), not where the pointer went.
                            cardDrag.width = min(max(origin.x + cardDrag.width + value.translation.width, 12), screenSize.width - width - 12) - origin.x
                            cardDrag.height = min(max(origin.y + cardDrag.height + value.translation.height, 12),
                                                  screenSize.height - min(cardHeight, screenSize.height - 24) - 12) - origin.y
                            cardDragging = .zero
                        })
                    .help(L10n.t("Drag to move"))
        }
        // Solid: nothing from the screen behind shows through the text.
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hue.opacity(0.6), lineWidth: 1))
        .shadow(color: hue.opacity(0.25), radius: 20, y: 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        // "+N": the other sessions to the card's right (below it, or left, when there's no room).
        .overlay(alignment: {
            switch listSide(card: CGRect(x: x, y: y, width: width, height: cardHeight)) {
            case .right: .topTrailing
            case .below: .bottomLeading
            case .left: .topLeading
            }
        }()) {
            if session.listOpen && !pickerRest.isEmpty {
                let side = listSide(card: CGRect(x: x, y: y, width: width, height: cardHeight))
                morePanel
                    .alignmentGuide(.bottom) { d in side == .below ? d[.top] - 10 : d[.bottom] }
                    .offset(x: (side == .right ? 250 : side == .left ? -250 : 0) + moreDrag.width + moreDragging.width,
                            y: moreDrag.height + moreDragging.height)
            }
        }
        .offset(x: x, y: y)
        .animation(.easeOut(duration: 0.15), value: cardHeight)
        .onAppear { focusField() }
        .onChange(of: session.editing) { focusField(); session.listOpen = false }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
    }

    /// Straight to the text: now and again once the window has taken the keyboard.
    private func focusField() {
        fieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fieldFocused = true }
    }

    /// What was selected — the element's CSS selector, the text or code it covers —
    /// and whether the crop and/or the text go to the agent.
    @ViewBuilder private func selection(of mark: Mark, hue: Color) -> some View {
        let text = session.text(of: mark)
        let image = session.previewImage(of: mark)
        VStack(alignment: .leading, spacing: 8) {
            if let element = mark.element {
                Text(element.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hue))
                    .help(L10n.t("The element's CSS selector: its tag and classes"))
            }
            // Why the crop is on or off: what was marked looks visual (picture, icon,
            // drawing) or reads as text.
            // Where it was made (the app, and the page or window), then why the crop
            // is on or off: what was marked looks visual or reads as text.
            HStack(spacing: 6) {
                let context = mark.context ?? session.context
                if let bundle = context.bundleID,
                   let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                // The app, clear; the page or window beside it, quieter.
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.appName ?? "")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let place = Self.place(of: context) {
                        Text(place)
                            .font(.system(size: 11, weight: .medium, design: context.url != nil ? .monospaced : .default))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(context.url ?? context.windowTitle ?? "")
                Spacer(minLength: 6)
                if session.copied == mark.id {
                    // The crop is on the clipboard: ⌘V pastes it anywhere.
                    Label(L10n.t("Copied · ⌘V pastes it"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Color.green.opacity(0.75)))
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale))
                } else {
                    Text(L10n.t(mark.sendsImage ? "Visual → picture" : "Text → text only"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.copied)
            // The crop first (what most marks are about), then the text read: both shown,
            // each ticked or not as Settings says (a click changes it).
            HStack(alignment: .top, spacing: 8) {
                if let image {
                    // The picture that goes to the agent; click to leave it out.
                    PreviewTile(title: L10n.t("Crop"), icon: "photo", on: mark.sendsImage, hue: hue) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 92)
                            .background(Color.black)
                    } toggle: {
                        session.toggle(mark.id, image: true)
                    } copy: {
                        MarkingSession.copy(image)
                    } zoom: {
                        ImageZoom.show(image)
                    }
                }
                if let text = text ?? (session.texts[mark.screen] == nil && !mark.isPoint ? L10n.t("Reading the text…") : nil) {
                    PreviewTile(title: L10n.t("Text read"), icon: "text.alignleft", on: mark.sendsText, hue: hue) {
                        ScrollView {
                            Text(text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 92)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.scrollAreas["text\(screen)"] = $0 }
                        .onDisappear { session.scrollAreas["text\(screen)"] = nil }
                        .padding(6)
                    } toggle: {
                        session.toggle(mark.id, image: false)
                    } copy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        session.copied = nil  // the clipboard holds the text now
                    }
                }
            }
        }
    }

    /// The screen the queue shows on: the one with the mark being written, else the last mark's.
    private var queueScreen: Int {
        if let editing = session.editing, let mark = session.marks.first(where: { $0.id == editing }) { return mark.screen }
        return session.marks.last(where: { $0.generation >= 0 })?.screen ?? 0
    }

    /// Top-left of the queue: right of the comment card (left when there's no
    /// room), level with it; with no card open, beside the last mark.
    private var queueSpot: CGPoint {
        let bounds = grab.screen.frame.size
        let width: CGFloat = 230, gap: CGFloat = 12
        var box: CGRect
        // The card being written, else the one written last (the queue stays where it
        // was when the card closes), else beside the last mark.
        let cardMark = session.editing.flatMap { id in session.marks.first { $0.id == id } }
            ?? session.lastEdited.flatMap { id in session.marks.first { $0.id == id && $0.screen == screen } }
        if let mark = cardMark {
            let origin = placement(near: mark.anchor, size: CGSize(width: 340, height: max(cardHeight, 200)))
            box = CGRect(origin: origin, size: CGSize(width: 340, height: max(cardHeight, 200)))
        } else if let last = session.marks.last(where: { $0.generation == session.generation[screen, default: 0] }) {
            box = CGRect(x: last.anchor.x, y: last.anchor.y, width: 1, height: 1)
        } else {
            box = CGRect(x: bounds.width - width - 20, y: bounds.height - queueHeight - 70, width: 0, height: 0)
        }
        // The sessions list open beside the card: the queue makes way (below the card,
        // past the list, or on the card's left — whichever fits).
        if session.listOpen, let mark = session.editing.flatMap({ id in session.marks.first { $0.id == id } }), mark.screen == screen {
            let card = cardBox(for: mark)
            let side = listSide(card: card)
            let list: CGRect = switch side {
            case .right: CGRect(x: card.maxX + 10, y: card.minY, width: 240, height: 380)
            case .below: CGRect(x: card.minX, y: card.maxY + 10, width: 240, height: 380)
            case .left: CGRect(x: card.minX - 250, y: card.minY, width: 240, height: 380)
            }
            let floor = bounds.height - bottomReserve
            if side != .below, card.maxY + gap + queueHeight <= floor {
                return CGPoint(x: card.minX, y: card.maxY + gap)
            }
            // Past both the card and the list (never on top of the card).
            let rightEdge = max(card.maxX, list.maxX) + gap
            if rightEdge + width <= bounds.width - 12 {
                return CGPoint(x: rightEdge, y: min(max(card.minY, 12), floor - queueHeight))
            }
            let leftEdge = min(card.minX, list.minX) - gap - width
            if leftEdge >= 12 {
                return CGPoint(x: leftEdge, y: min(max(card.minY, 12), floor - queueHeight))
            }
        }
        var x = box.maxX + gap
        if x + width > bounds.width - 12 { x = box.minX - gap - width }
        let y = min(max(box.minY, 12), bounds.height - bottomReserve - queueHeight)
        return CGPoint(x: min(max(x, 12), bounds.width - width - 12), y: y)
    }

    /// Top-left for a box of `size` next to the pointer: below-right of it, or
    /// flipped left / up when that would leave the screen.
    private func placement(near point: CGPoint, size: CGSize) -> CGPoint {
        let bounds = grab.screen.frame.size
        let floor = bounds.height - bottomReserve
        var x = point.x + 16
        var y = point.y + 16
        if x + size.width > bounds.width - 12 { x = point.x - 16 - size.width }
        if y + size.height > floor { y = point.y - 16 - size.height }
        return CGPoint(x: min(max(x, 12), bounds.width - size.width - 12),
                       y: min(max(y, 12), floor - size.height))
    }

    /// Room kept free at the bottom of the main screen for the hint bar (and the
    /// sidebar under it), so no card or queue ever hides behind it.
    private var bottomReserve: CGFloat {
        guard isMain else { return 12 }
        return (Preferences.shared.edge == .bottom ? 96 : 28) + 56
    }

    // MARK: Destination and actions

    /// The first four sessions in sidebar order (the chosen one always among them):
    /// picking one never moves its ring. The rest wait behind "+N", in a list beside the card.
    private var pickerShown: [AgentTerminal] {
        var shown = Array(session.terminals.prefix(4))
        if let chosen = session.terminal(session.destination), !shown.contains(chosen), !shown.isEmpty {
            shown[shown.count - 1] = chosen
        }
        return shown
    }

    private var pickerRest: [AgentTerminal] {
        let shown = pickerShown
        return session.terminals.filter { !shown.contains($0) }
    }

    /// The "+N" list: the sessions behind it, or — with words typed — every session that matches.
    private var moreList: [AgentTerminal] {
        let query = moreQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return pickerRest }
        return session.terminals.filter { terminal in
            [terminal.name, URL(filePath: terminal.worktree).lastPathComponent].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private func pickFromList(_ terminal: AgentTerminal) {
        withAnimation(.easeOut(duration: 0.15)) {
            session.setDestination(terminal.id)
            session.listOpen = false
        }
        moreQuery = ""
        focusField()
    }

    private var terminalPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(pickerShown) { terminal in pickerTile(terminal) }
                if !pickerRest.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { session.listOpen.toggle() }
                    } label: {
                        VStack(spacing: 3) {
                            Text("+\(pickerRest.count)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Color.white.opacity(session.listOpen ? 0.22 : 0.1)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                                .frame(width: 42, height: 42)
                            Text(L10n.t("More"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .frame(width: 44)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .modifier(PickHover())
                    .help(L10n.t("Other sessions"))
                }
            }
            .padding(.vertical, 4)
            if let terminal = session.terminal(session.destination) {
                // The chosen one in full: its name first, the AI after it, quieter.
                (Text(terminal.name).font(.system(size: 12, weight: .bold)).foregroundColor(Color(session.hue(for: terminal.id)))
                    + Text("  ·  \(terminal.agent.displayName)").font(.system(size: 10.5, weight: .medium)).foregroundColor(.white.opacity(0.5))
                    + Text("  ·  \(stateText(terminal.state))").font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(terminal.state == .waiting ? AkiPalette.red : .white.opacity(terminal.state == .idle ? 0.4 : 0.75)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pickerTile(_ terminal: AgentTerminal) -> some View {
        let selected = terminal.id == session.destination
        let hue = Color(session.hue(for: terminal.id))
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                session.setDestination(terminal.id)
            }
        } label: {
            VStack(spacing: 3) {
                // The AI as a big symbol in the ring; the name below is the session's.
                AgentGlyphView(agent: terminal.agent, size: selected ? 24 : 21)
                    .foregroundStyle(.white)
                    .frame(width: selected ? 36 : 32, height: selected ? 36 : 32)
                    .background(Circle().fill(hue.opacity(selected ? 0.9 : 0.25)))
                    .overlay {
                        if selected {
                            Circle().strokeBorder(AkiPalette.auroraAngular, lineWidth: 2.5).padding(-3)
                        } else {
                            Circle().strokeBorder(hue.opacity(0.6), lineWidth: 1)
                        }
                    }
                    .shadow(color: selected ? AkiPalette.aurora[2].opacity(0.7) : .clear, radius: 6)
                    .overlay(alignment: .bottomLeading) {
                        if let number = session.number(of: terminal.id) {
                            NumberBadge(number: number, size: 13).offset(x: -4, y: 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        TerminalAppIcon(bundleID: TerminalApp.owner(of: terminal.pid)?.bundleIdentifier, size: 12)
                            .offset(x: 3, y: -3)
                    }
                    // Running or not, as on its ring: spinning while it works, a pulse while it waits for you.
                    .overlay(alignment: .bottomTrailing) {
                        LiveDot(state: terminal.state, hue: terminal.state == .idle ? Color.white.opacity(0.5) : .white)
                            .padding(2)
                            .background(Circle().fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
                            .offset(x: 3, y: 3)
                    }
                    .frame(width: 42, height: 42)
                Text(terminal.name)
                    .font(.system(size: 10, weight: selected ? .bold : .semibold))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .modifier(PickHover())
        .help(pickerHelp(terminal))
    }

    private func pickerHelp(_ terminal: AgentTerminal) -> String {
        "\(terminal.agent.displayName) · \(terminal.name) · \(stateText(terminal.state)) · \(URL(filePath: terminal.worktree).lastPathComponent)"
            + (session.number(of: terminal.id).map { $0 <= 9 ? " · ⌘\($0)" : "" } ?? "")
    }

    private func stateText(_ state: AgentTerminal.State) -> String {
        switch state {
        case .waiting: L10n.t("waiting for you")
        case .working: L10n.t("working")
        case .shell: L10n.t("running a command")
        case .listening: L10n.t("listening")
        case .idle: L10n.t("idle")
        }
    }

    /// The sessions behind "+N": a list beside the card, one row each.
    private var morePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Its top is a handle (the grabber bar says so; the hand too): drag it anywhere.
            VStack(spacing: 6) {
                GripDots(vertical: false, hovered: moreHandleHovered, scale: 0.8, tint: .white, backdrop: Color.white.opacity(0.08))
                    .frame(maxWidth: .infinity)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(L10n.t("Other sessions"))
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(moreHandleHovered ? 0.8 : 0.5))
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
            // Again on every move: the marking overlay would put the pin back.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    moreHandleHovered = true
                    AkiCursor.set(moreDragging == .zero ? NSCursor.openHand : NSCursor.closedHand)
                case .ended:
                    moreHandleHovered = false
                    AkiCursor.set(AkiCursor.pin)
                }
            }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { moreDragging = $0.translation; AkiCursor.set(NSCursor.closedHand) }
                .onEnded { value in
                    moreDrag.width += value.translation.width
                    moreDrag.height += value.translation.height
                    moreDragging = .zero
                })
            // Type to find one: the name or the project, any case, accents or not; ⏎ takes the first.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                TextField(L10n.t("Find a session"), text: $moreQuery)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.white)
                    .focused($moreSearchFocused)
                    .onSubmit { if let first = moreList.first { pickFromList(first) } }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
            .padding(.horizontal, 6).padding(.bottom, 4)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(moreList) { terminal in
                        MoreRow(terminal: terminal, hue: Color(session.hue(for: terminal.id)),
                                number: session.number(of: terminal.id), help: pickerHelp(terminal)) {
                            pickFromList(terminal)
                        }
                    }
                    if moreList.isEmpty {
                        Text(L10n.t("No session with that name")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            .padding(8)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: moreList.count <= 8)
            // Where it is on screen: the wheel over it scrolls it, not the page below.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.scrollAreas["more\(screen)"] = $0 }
            .onDisappear { session.scrollAreas["more\(screen)"] = nil }
        }
        .frame(width: 240, alignment: .leading)
        .onAppear { moreQuery = ""; DispatchQueue.main.async { moreSearchFocused = true } }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .transition(.opacity)
    }

    /// Save puts the mark in the queue (and you go on marking); Send now sends
    /// it — with whatever is already queued — straight to its session.
    /// Where the mark goes, changeable right here.
    private var destinationMenu: some View {
        Menu {
            ForEach(session.terminals) { terminal in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { session.setDestination(terminal.id) }
                } label: {
                    SessionMenuLabel(terminal: terminal, title: "\(session.number(of: terminal.id).map { "\($0)  " } ?? "")\(terminal.agent.displayName) · \(terminal.name)")
                }
            }
        } label: {
            let terminal = session.terminal(session.destination)
            (Text("● ").foregroundColor(Color(session.hue(for: session.destination)))
                + Text(terminal.map { "\($0.agent.displayName) · \($0.name)" } ?? L10n.t("No destination")).foregroundColor(.white).bold()
                + Text("  ⌃⌄").foregroundColor(.white.opacity(0.6)))
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .focusable(false)
        .modifier(PickHover())
        .help(L10n.t("Where it goes"))
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            // Queue it and keep marking (more text, more pictures), or send the lot now.
            // Three buttons need shorter words to fit the card.
            let crowded = session.marks.contains { $0.id != session.editing }
            // Each button shows its key: ⏎ queues, ⌘⏎ sends.
            Button { withAnimation(.easeOut(duration: 0.15)) { session.commitDraft() } } label: {
                HStack(spacing: 5) {
                    Label(L10n.t(crowded ? "Queue it" : "Add to queue"), systemImage: "plus.square.on.square")
                    // Three buttons: no room for the keys (the tips still say them).
                    if !crowded { Keycap(key: "⏎", size: 8) }
                }
            }
            .buttonStyle(SettingsButtonStyle(compact: true))
            .focusable(false)
            .modifier(PickHover())
            .help(L10n.t("Put it in the queue and keep marking (⏎)"))
            // With other marks queued: this one alone, or all of them — never a guess.
            let others = session.marks.filter { $0.id != session.editing }.count
            if others > 0, let current = session.editing {
                Button { sendOnly(current) } label: {
                    Label(L10n.t("Only this one"), systemImage: "paperplane")
                }
                .buttonStyle(SettingsButtonStyle(compact: true))
                .disabled(session.marks.first(where: { $0.id == current }).map { session.terminal($0.destination) == nil } ?? true)
                .focusable(false)
                .modifier(PickHover())
                .help(L10n.t("Send just this mark; the rest stay in the queue"))
            }
            Button { send() } label: {
                HStack(spacing: 5) {
                    Label(others > 0 ? "\(L10n.t("Send all")) (\(others + 1))" : L10n.t("Send now"), systemImage: "paperplane.fill")
                    if !crowded { Keycap(key: "⌘⏎", size: 8) }
                }
            }
            .buttonStyle(SettingsButtonStyle(kind: .prominent, compact: true))
            .disabled(session.hasUnavailableDestinations)
            .focusable(false)
            .modifier(PickHover())
            .help(others > 0 ? L10n.t("Send this mark and the whole queue (⌘⏎)") : L10n.t("Send to the session now (⌘⏎)"))
        }
        .fixedSize()
    }

    /// The queue: every mark of this round, then one button that sends them all
    /// to the session (and its agent) you chose.
    /// Takes the ticked marks out of the queue (the button, or ⌫).
    private func removeSelected() {
        withAnimation(.easeOut(duration: 0.15)) { session.removeSelected() }
    }

    private var queuePanel: some View {
        let destinations = Set(session.marks.compactMap(\.destination))
        let terminal = session.terminal(session.marks.last?.destination ?? session.destination)
        let hue = Color(session.hue(for: terminal?.id))
        let count = session.marks.count
        let selected = session.queueSelected.intersection(session.marks.map(\.id))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L10n.t("Queue")).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                Text("· \(count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                if selected.isEmpty {
                    ClearQueueButton(action: discard)
                } else {
                    // The ticked ones out, the rest stays to send.
                    RemoveSelectedButton(count: selected.count) { removeSelected() }
                }
            }
            // Every mark (it scrolls past five), each with a tick to pick it.
            ScrollView(.vertical, showsIndicators: count > 5) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.marks) { mark in
                        QueueRow(mark: mark, image: session.previewImage(of: mark), terminal: session.terminal(mark.destination),
                                 hue: Color(session.hue(for: mark.destination)),
                                 editing: session.editing == mark.id,
                                 selected: selected.contains(mark.id),
                                 selecting: !selected.isEmpty,
                                 select: {
                                     if session.queueSelected.contains(mark.id) { session.queueSelected.remove(mark.id) } else { session.queueSelected.insert(mark.id) }
                                 },
                                 remove: { withAnimation(.easeOut(duration: 0.15)) { session.remove(mark.id) } },
                                 open: {
                                     if queueAnchor == nil { queueAnchor = queueSpot }
                                     withAnimation(.easeOut(duration: 0.15)) { session.edit(mark.id) }
                                 })
                    }
                }
            }
            .frame(maxHeight: count > 5 ? 230 : nil)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { session.scrollAreas["queue\(screen)"] = $0 }
            .onDisappear { session.scrollAreas["queue\(screen)"] = nil }
            .fixedSize(horizontal: false, vertical: count <= 5)
            // Where the whole queue goes, changeable here: a field that reads as one.
            Menu {
                ForEach(session.terminals) { t in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { session.setDestinationForAll(t.id) }
                    } label: {
                        SessionMenuLabel(terminal: t, title: "\(session.number(of: t.id).map { "\($0)  " } ?? "")\(t.agent.displayName) · \(t.name)")
                    }
                }
            } label: {
                DestinationField(terminal: destinations.count > 1 ? nil : terminal, hue: hue,
                                 several: destinations.count > 1 ? destinations.count : nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable(false)
            Button { send() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill").font(.system(size: 10, weight: .bold))
                    // A verb, not the session again (the chooser above says where): plainly the button.
                    Text(count == 1 ? L10n.t("Send") : "\(L10n.t("Send all")) (\(count))")
                        .font(.system(size: 11.5, weight: .bold))
                    Spacer(minLength: 2)
                    Keycap(key: "⌘⏎", size: 8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(hue.opacity(0.9)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.hasUnavailableDestinations)
            .focusable(false)
            // Lights up in place (a full-width button can't grow past the panel).
            .modifier(GlowHover())
            .help(terminal.map { "\(L10n.t("Send")) \(count) \(L10n.t("to")) \($0.agent.displayName) · \($0.name)" } ?? "")
        }
        .padding(.horizontal, 9).padding(.bottom, 9).padding(.top, 17)
        .frame(width: 230)
        // The grab handle: centred on the queue's top edge, as on the card.
        .overlay(alignment: .top) {
                // Its top is a handle: drag the queue out of the way.
                GripDots(vertical: false, hovered: queueHandleHovered, scale: 0.8, tint: .white, backdrop: Color.white.opacity(0.08))
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            queueHandleHovered = true
                            AkiCursor.set(queueDragging == .zero ? NSCursor.openHand : NSCursor.closedHand)
                        case .ended:
                            queueHandleHovered = false
                            AkiCursor.set(AkiCursor.pin)
                        }
                    }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { queueDragging = $0.translation; AkiCursor.set(NSCursor.closedHand) }
                        .onEnded { value in
                            // Keep where it shows (stopped at the screen's edge), not where the pointer went.
                            queueDragging = .zero
                            // Moved while the sessions list is open: only for as long as it is.
                            if session.listOpen {
                                let spot = queueSpot
                                listQueueDrag.width = min(max(spot.x + listQueueDrag.width + value.translation.width, 12),
                                                          grab.screen.frame.width - 242) - spot.x
                                listQueueDrag.height = min(max(spot.y + listQueueDrag.height + value.translation.height, 12),
                                                           grab.screen.frame.height - queueHeight - 12) - spot.y
                                return
                            }
                            let spot = queueAnchor ?? queueSpot
                            queueDrag.width = min(max(spot.x + queueDrag.width + value.translation.width, 12), grab.screen.frame.width - 242) - spot.x
                            queueDrag.height = min(max(spot.y + queueDrag.height + value.translation.height, 12),
                                                   grab.screen.frame.height - queueHeight - 12) - spot.y
                        })
                    .help(L10n.t("Drag to move"))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hue.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var hints: some View {
        VStack(spacing: 8) {
            if !ElementProbe.isTrusted {
                Button {
                    ElementProbe.askForAccess()
                } label: {
                    Label(L10n.t("Allow Accessibility to outline buttons and page elements"), systemImage: "cursorarrow.rays")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(SettingsButtonStyle(compact: true))
            }
            // Like the site's bar: a dot and where things stand, the keys in grey,
            // then Send and Exit.
            let prefs = Preferences.shared
            Group {
            if prefs.hintsFolded {
                foldedDot
            } else {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    // Grab here to move the bar anywhere.
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AkiPalette.paperFixed.opacity(0.35))
                        .help(L10n.t("Drag to move"))
                    Circle().fill(AkiPalette.red).frame(width: 8, height: 8)
                    Text(session.marks.isEmpty ? L10n.t("No marks yet")
                         : "\(session.marks.count) \(L10n.t("in the queue"))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AkiPalette.paperFixed)
                }
                HStack(spacing: 12) {
                    ForEach(Array(Self.hintItems.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 4) {
                            Text(item.keys).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(AkiPalette.paperFixed.opacity(0.85))
                            Text(item.label).font(.system(size: 12))
                                .foregroundStyle(Color(red: 163 / 255, green: 158 / 255, blue: 147 / 255))
                        }
                    }
                }
                HStack(spacing: 6) {
                    BarButton(title: L10n.t("Send"), keys: "⌘⏎", primary: true, enabled: !session.marks.isEmpty && !session.hasUnavailableDestinations, action: send)
                    BarButton(title: L10n.t("Exit"), keys: "esc", primary: false, enabled: true, action: close)
                    // Fold it away (a dot stays, to open it again).
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { prefs.hintsFolded = true } } label: {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AkiPalette.paperFixed.opacity(0.6))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Hide the tips"))
                }
            }
            .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 6)
            .background(Capsule().fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hintWidth = $0 }
            .offset(x: prefs.hintsOffset.width + hintDrag.width, y: prefs.hintsOffset.height + hintDrag.height)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { hintDrag = $0.translation }
                    .onEnded { value in
                        // Kept on screen, whatever the drag.
                        let size = grab.screen.frame.size
                        let w = prefs.hintsOffset.width + value.translation.width
                        let h = prefs.hintsOffset.height + value.translation.height
                        // The whole bar stays in view (its real width, buttons included).
                        let side = max(size.width / 2 - hintWidth / 2 - 12, 0)
                        prefs.hintsOffset = CGSize(width: min(max(w, -side), side),
                                                   height: min(max(h, -(size.height - 160)), 20))
                        hintDrag = .zero
                    })
        }
        // Clear of the sidebar when it sits at the bottom.
        .padding(.bottom, Preferences.shared.edge == .bottom ? 96 : 28)
    }

    /// "Google Chrome · localhost:4321/features", or the app and its window's title.
    /// Where in the app: the page ("localhost:4321/features") or the window's
    /// title; nil when that only repeats the app's name.
    static func place(of context: MarkContext) -> String? {
        if let text = context.url, let url = URL(string: text), let host = url.host() {
            let port = url.port.map { ":\($0)" } ?? ""
            let path = url.path() == "/" ? "" : url.path()
            return host + port + path
        }
        guard let title = context.windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              title.caseInsensitiveCompare(context.appName ?? "") != .orderedSame else { return nil }
        return title
    }

    /// The hint bar folded away: a dot with the count; click to open it again.
    private var foldedDot: some View {
        // Folded: just the dot and the count; click to open it again.
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { Preferences.shared.hintsFolded = false } } label: {
            HStack(spacing: 6) {
                Circle().fill(AkiPalette.red).frame(width: 8, height: 8)
                if !session.marks.isEmpty {
                    Text("\(session.marks.count)").font(.system(size: 12, weight: .bold)).foregroundStyle(AkiPalette.paperFixed)
                }
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(AkiPalette.paperFixed.opacity(0.6))
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .help(L10n.t("Show the tips"))
    }

    /// The hint line, split into key + what it does ("Click: element", "↑↓ bigger/smaller");
    /// sending has its own button.
    static var hintItems: [(keys: String, label: String)] {
        allHintItems.filter { $0.keys != "⌘⏎" }
    }

    private static var allHintItems: [(keys: String, label: String)] {
        L10n.t("Click: element · Arrows: move · ⇧↑↓: bigger/smaller · ⌥: lines of text · ⌘ click: point · ⇧ click: normal click · Drag: area · ⌘⏎: send")
            .components(separatedBy: " · ").map { part in
                if let colon = part.firstIndex(of: ":") {
                    return (String(part[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                }
                let words = part.split(separator: " ", maxSplits: 1)
                return (String(words.first ?? ""), words.count > 1 ? String(words[1]) : "")
            }
    }
}

/// A button on the hint bar: Send in Aki's red, Exit in grey, each with its key.
struct BarButton: View {
    let title: String
    let keys: String
    let primary: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(keys).font(.system(size: 10.5, weight: .semibold, design: .rounded)).opacity(0.65)
            }
            .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.45))
            .padding(.horizontal, 14).frame(height: 30)
            .background(Capsule().fill(primary
                ? AkiPalette.red.opacity(enabled ? (hovered ? 1 : 0.9) : 0.3)
                : Color.white.opacity(hovered ? 0.16 : 0.09)))
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!enabled)
        .onHover { inside in
            hovered = inside && enabled
            if inside && enabled { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
        }
    }
}

/// Four rounded corners of a box, like the site's selection frame.
struct CornerBrackets: Shape {
    var arm: CGFloat = 16
    var radius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let a = min(arm, rect.width / 2, rect.height / 2), r = min(radius, a)
        var p = Path()
        // top left, top right, bottom right, bottom left: from one arm's end round to the other's
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0), (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x, y: corner.y + dy * a))
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * r))
            p.addQuadCurve(to: CGPoint(x: corner.x + dx * r, y: corner.y), control: corner)
            p.addLine(to: CGPoint(x: corner.x + dx * a, y: corner.y))
        }
        return p
    }
}

/// The hovered element's tag: its selector in the site's light red, mono, then
/// its text; ↑↓ when the arrows can walk the page.
struct PickTag: View {
    let label: String
    let walks: Bool
    let above: Bool

    var body: some View {
        let quote = label.range(of: " “")
        let code = quote.map { String(label[..<$0.lowerBound]) } ?? label
        let text = quote.map { String(label[$0.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "”")) }
        HStack(spacing: 6) {
            Text(code).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 138 / 255, blue: 115 / 255))
            if let text, !text.isEmpty {
                Text(text).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(AkiPalette.paperFixed)
                    .truncationMode(.tail).frame(maxWidth: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            // Said in words: ↑ takes what holds it (a block, the whole terminal, the window), ↓ comes back.
            if walks {
                Text(L10n.t("↑↓←→ move · ⇧↑ bigger · ⇧↓ smaller"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AkiPalette.paperFixed.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(tagShape.fill(AkiPalette.inkFixed))
        .overlay(tagShape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    private var tagShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: above ? 9 : 2, bottomLeadingRadius: above ? 2 : 9,
                               bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous)
    }
}

/// One mark in the queue: its number, crop, comment; × takes it out.
struct QueueRow: View {
    let mark: Mark
    let image: NSImage?
    let terminal: AgentTerminal?
    let hue: Color
    let editing: Bool
    /// Ticked to be taken out with others; once one is, every row shows its tick.
    var selected = false
    var selecting = false
    var select: () -> Void = {}
    let remove: () -> Void
    /// A click on the row: write (or change) its comment.
    var open: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Its number; under the pointer (or while picking) a tick to select it.
            Button(action: select) {
                Group {
                    if hovered || selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? AkiPalette.red : Color.white.opacity(0.7))
                    } else {
                        Text("\(mark.number)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(hue))
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { inside in AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin) }
            .help(L10n.t(selected ? "Unselect" : "Select to remove"))
            Group {
                if let image {
                    // Click: see it bigger.
                    Button { ImageZoom.show(image) } label: {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 30, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { inside in AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin) }
                    .help(L10n.t("See it bigger"))
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 30, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(editing ? L10n.t("writing…") : (mark.comment.isEmpty ? L10n.t("(no comment)") : mark.comment))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(mark.comment.isEmpty || editing ? 0.5 : 0.9))
                    .lineLimit(1)
                if let terminal {
                    HStack(spacing: 3) {
                        SessionIdentityView(identity: SessionIdentity(terminal: terminal), size: 8, showAppName: false)
                        Text(terminal.name).lineLimit(1)
                    }
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .help("\(terminal.agent.displayName) · \(terminal.name)")
                } else {
                    Label(L10n.t("No destination"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
            if hovered {
                // Write / change its comment, or take it out of the queue.
                RowIconButton(symbol: "pencil", danger: false, action: open)
                    .help(L10n.t("Edit comment"))
                RowIconButton(symbol: "xmark", danger: true, action: remove)
                    .help(L10n.t("Remove from the queue"))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? AkiPalette.red.opacity(0.18) : Color.white.opacity(hovered || editing ? 0.08 : 0.03)))
        .onHover { hovered = $0 }
    }
}

/// A queue row's small round button: paper on hover (red for the one that removes).
struct RowIconButton: View {
    let symbol: String
    let danger: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovered ? (danger ? Color.white : AkiPalette.inkFixed) : Color.white.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovered ? (danger ? AkiPalette.red : AkiPalette.paperFixed) : Color.white.opacity(0.14)))
                .scaleEffect(hovered ? 1.12 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovered)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            hovered = inside
            if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
        }
    }
}

/// "Clear": empties the queue (and leaves marking).
/// "Remove N": the ticked marks out of the queue.
struct RemoveSelectedButton: View {
    let count: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "trash").font(.system(size: 9, weight: .bold))
                Text("\(L10n.t("Remove")) \(count)").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(AkiPalette.red.opacity(hovered ? 1 : 0.85)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.t("Remove the selected marks (⌫)"))
        .onHover { inside in
            hovered = inside
            AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin)
        }
    }
}

struct ClearQueueButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "trash").font(.system(size: 9, weight: .bold))
                Text(L10n.t("Clear")).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(hovered ? Color.white : Color.white.opacity(0.7))
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(hovered ? AkiPalette.red : Color.white.opacity(0.1)))
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.t("Clear the queue"))
        .onHover { inside in
            hovered = inside
            if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
        }
    }
}

/// Hover for wide buttons: brighter and a soft ring, no growing.
struct GlowHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .brightness(hovered ? 0.1 : 0)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(hovered ? 0.5 : 0), lineWidth: 1.2))
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { inside in
                hovered = inside
                if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
            }
    }
}

/// One thing a mark sends (the crop, the text), labelled, with a ✓ in the corner:
/// click it to leave it out (it dims) or put it back.
struct PreviewTile<Content: View>: View {
    let title: String
    let icon: String
    let on: Bool
    let hue: Color
    @ViewBuilder let content: Content
    let toggle: () -> Void
    /// Copies what the tile shows (the crop, the text) to the clipboard.
    var copy: (() -> Void)? = nil
    /// Opens what the tile shows bigger (the crop).
    var zoom: (() -> Void)? = nil
    @State private var hovered = false
    @State private var copied = false
    @State private var copyHovered = false
    @State private var zoomHovered = false

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 9, weight: .bold))
                    Text(title).font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(on ? 0.9 : 0.45))
                content
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? hue : Color.white.opacity(0.2), lineWidth: on ? 1.5 : 1))
                    .overlay(alignment: .topTrailing) {
                        // Sticks out of the corner: its own button, so the hand shows on it too.
                        Button(action: toggle) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(on ? hue : Color.white.opacity(0.6))
                                .background(Circle().fill(Color.black).padding(1))
                                .padding(3)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .onHover { inside in AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin) }
                        .offset(x: 8, y: -8)
                    }
                    .opacity(on ? 1 : 0.4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                    .overlay(alignment: .bottomTrailing) {
                        if let copy {
                            Button {
                                copy()
                                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .bold))
                                    Text(L10n.t(copied ? "Copied" : "Copy")).font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(copyHovered ? Color.black : Color.white)
                                .padding(.horizontal, 6).frame(height: 18)
                                // Under the pointer it lights up: this is the button that copies.
                                .background(Capsule().fill(copyHovered ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.75))))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(copyHovered ? 0 : 0.25), lineWidth: 0.5))
                                .scaleEffect(copyHovered ? 1.08 : 1)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .onHover { inside in
                                withAnimation(.easeOut(duration: 0.12)) { copyHovered = inside }
                                if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
                            }
                            .padding(5)
                            .opacity(hovered || copied ? 1 : 0)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let zoom {
                            Button(action: zoom) {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus.magnifyingglass").font(.system(size: 9, weight: .bold))
                                    Text(L10n.t("Zoom")).font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(zoomHovered ? Color.black : Color.white)
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(Capsule().fill(zoomHovered ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.75))))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(zoomHovered ? 0 : 0.25), lineWidth: 0.5))
                                .scaleEffect(zoomHovered ? 1.08 : 1)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .onHover { inside in
                                withAnimation(.easeOut(duration: 0.12)) { zoomHovered = inside }
                                if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
                            }
                            .help(L10n.t("See it bigger"))
                            .padding(5)
                            .opacity(hovered ? 1 : 0)
                        }
                    }
            }
            .scaleEffect(hovered ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
            AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin)
        }
        .help(on ? L10n.t("Click to leave it out") : L10n.t("Click to send it"))
    }
}

/// An on/off chip: what goes to the agent for a mark.
struct ToggleChip: View {
    let title: String
    let icon: String
    let on: Bool
    let hue: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark" : icon).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(on ? hue.opacity(0.85) : Color.white.opacity(hovered ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.white.opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A shortcut you can also click: the key, an optional word, a hover highlight.
struct KeyButton: View {
    let key: String
    let label: String?
    var help: String? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Keycap(key: key)
                if let label {
                    Text(label).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.55))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered ? 0.12 : 0)))
            .scaleEffect(hovered ? 1.04 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
            AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin)
        }
        .help(help ?? label ?? key)
    }
}

/// A point (numbered pin) or an area (outlined box with its number), in its
/// conversation's colour. When sent, it shrinks and flies to that ring.
struct MarkShape: View {
    let mark: Mark
    let hue: Color
    let flying: Bool
    let target: CGPoint?
    var preview: NSImage? = nil
    @State private var launched = false

    /// Marks leave one after another, not all at once.
    private var stagger: Double { Double(min(mark.number - 1, 6)) * 0.07 }

    var body: some View {
        let center = CGPoint(x: mark.rect.midX, y: mark.rect.midY)
        ZStack {
            outline
                .frame(width: max(mark.rect.width, 1), height: max(mark.rect.height, 1), alignment: .topLeading)
                // On send the box gathers itself into the tag that flies off.
                .scaleEffect(flying ? 0.9 : 1, anchor: .center)
                .opacity(flying ? 0 : 1)
                .position(center)
                .animation(.easeOut(duration: 0.18).delay(stagger), value: flying)
            if flying, let target {
                let path = FlightPath.Path(from: center, to: target)
                // A short trail of dots behind the tag, like a comet's.
                ForEach(1..<4, id: \.self) { i in
                    Circle().fill(hue)
                        .frame(width: CGFloat(10 - i * 2), height: CGFloat(10 - i * 2))
                        .opacity(0.55 - Double(i) * 0.12)
                        .modifier(FlightPath(progress: launched ? 1 : 0, path: path, shrink: 0.2))
                        .animation(Self.flight.delay(stagger + Double(i) * 0.045), value: launched)
                }
                tag
                    .modifier(FlightPath(progress: launched ? 1 : 0, path: path, shrink: 0.7))
                    .animation(Self.flight.delay(stagger), value: launched)
                    .onAppear { launched = true }
            }
        }
        .allowsHitTesting(false)
    }

    /// Slow out of the box, fast across, easing into the ring.
    static let flight = Animation.timingCurve(0.5, 0, 0.25, 1, duration: 0.72)

    private var outline: some View {
        ZStack(alignment: .topLeading) {
            if !mark.isPoint {
                Rectangle()
                    .fill(hue.opacity(0.14))
                    .overlay(Rectangle().strokeBorder(hue, lineWidth: 2))
                    .frame(width: mark.rect.width, height: mark.rect.height)
            }
            // The number sits on the corner, but never past the screen's edge.
            pin
                .offset(x: mark.isPoint ? -13 : max(-11, 2 - mark.rect.minX),
                        y: mark.isPoint ? -13 : max(-11, 2 - mark.rect.minY))
        }
    }

    /// What travels: number, a peek of the crop, the comment.
    private var tag: some View {
        HStack(spacing: 7) {
            pin.scaleEffect(0.85).frame(width: 22, height: 22)
            if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 22).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            let words = mark.comment.isEmpty ? (mark.text ?? mark.element?.label ?? "") : mark.comment
            if !words.isEmpty {
                Text(words).font(.system(size: 12, weight: .semibold)).foregroundStyle(AkiPalette.paperFixed)
                    .lineLimit(1).frame(maxWidth: 170, alignment: .leading)
            }
        }
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
        .background(Capsule().fill(AkiPalette.inkFixed))
        .overlay(Capsule().strokeBorder(hue.opacity(0.9), lineWidth: 1.5))
        .shadow(color: hue.opacity(0.45), radius: 10)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        .fixedSize()
    }

    private var pin: some View {
        Text("\(mark.number)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(hue))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }
}

/// Moves a view along a curve (a quadratic Bézier that arcs up and over), shrinking
/// as it goes and fading at the very end, as it drops into the ring.
struct FlightPath: ViewModifier, Animatable {
    struct Path {
        let from: CGPoint, control: CGPoint, to: CGPoint
        init(from: CGPoint, to: CGPoint) {
            self.from = from
            self.to = to
            let distance = hypot(to.x - from.x, to.y - from.y)
            // Up and a little back: the tag rises before it dives.
            control = CGPoint(x: from.x + (to.x - from.x) * 0.3,
                              y: min(from.y, to.y) - min(distance * 0.35, 260))
        }
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                           y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
        }
    }

    var progress: CGFloat
    let path: Path
    /// How much smaller it is on arrival (0.7 = 30 % of its size).
    let shrink: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let spot = path.at(p)
        // A pop as it leaves, then smaller and smaller on the way in.
        let pop = p < 0.15 ? 1 + 0.12 * sin(p / 0.15 * CGFloat.pi) : 1
        content
            .scaleEffect((1 - shrink * p) * pop)
            .rotationEffect(.degrees(-7 * sin(p * CGFloat.pi)))
            .opacity(p > 0.82 ? Double((1 - p) / 0.18) : 1)
            .position(spot)
    }
}

/// A destination under the pointer grows and brightens, with the hand cursor.
struct PickHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered ? 1.1 : 1)
            .brightness(hovered ? 0.12 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovered)
            .onHover { inside in
                hovered = inside
                if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
            }
    }
}

/// One session in the "+N" list: its AI in its colour, number, name and project.
private struct MoreRow: View {
    let terminal: AgentTerminal
    let hue: Color
    let number: Int?
    let help: String
    let pick: () -> Void
    @State private var hovered = false

    /// Said only when it's doing something; idle says nothing.
    private var state: String? {
        switch terminal.state {
        case .waiting: L10n.t("waiting for you")
        case .working: L10n.t("working")
        case .shell: L10n.t("running a command")
        case .listening, .idle: nil
        }
    }

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                AgentGlyphView(agent: terminal.agent, size: 15)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(hue.opacity(0.5)))
                    .overlay(alignment: .bottomLeading) {
                        if let number { NumberBadge(number: number, size: 11).offset(x: -3, y: 3) }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(terminal.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        LiveDot(state: terminal.state, hue: terminal.state == .idle ? Color.white.opacity(0.5) : .white)
                        if let state {
                            Text(state).foregroundStyle(terminal.state == .waiting ? AkiPalette.red : .white.opacity(0.75))
                            Text("·").foregroundStyle(.white.opacity(0.35))
                        }
                        Text(URL(filePath: terminal.worktree).lastPathComponent)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .font(.system(size: 10))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                TerminalAppIcon(bundleID: TerminalApp.owner(of: terminal.pid)?.bundleIdentifier, size: 14)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovered ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .onHover { inside in
            hovered = inside
            if inside { AkiCursor.set(NSCursor.pointingHand) } else { AkiCursor.set(AkiCursor.pin) }
        }
    }
}

/// The queue's destination as a field you can click: the AI, its app, the session's
/// whole name, and the up-down arrows every Mac menu has; it lights up under the pointer.
struct DestinationField: View {
    let terminal: AgentTerminal?
    let hue: Color
    /// Marks going to more than one session.
    let several: Int?
    @State private var hovered = false

    var body: some View {
        // A chooser, not a button: only an outline, "To" before the name, the menu arrows.
        HStack(spacing: 6) {
            Text(L10n.t("To")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            Circle().fill(hue).frame(width: 6, height: 6)
            if let terminal {
                AgentGlyphView(agent: terminal.agent, size: 10).foregroundStyle(.white.opacity(0.85))
                Text(terminal.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            } else if let several {
                Text("\(several) \(L10n.t("sessions"))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            } else {
                Text(L10n.t("No destination")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 4)
            Text(L10n.t("Change")).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(hovered ? 0.9 : 0.5))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.5))
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovered ? 0.06 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(hovered ? 0.45 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside }
            AkiCursor.set(inside ? NSCursor.pointingHand : AkiCursor.pin)
        }
        .help(terminal.map { "\($0.agent.displayName) · \($0.name)" } ?? "")
    }
}
