// Visual language from Codenotch's NotchRootView, ProviderRing, SettingsHandle and
// TooltipCard (MIT, Copyright (c) 2026 Vinz, https://github.com/vinzdg/codenotch).

import AkiCore
import AppKit
import SwiftUI

enum AkiPalette {
    // The brand (brand/tokens.json): paper, ink and one red, #FF3B1F, only on what
    // marks something. No gradients, no neon. Night is the dark surface.
    /// The theme and accent in effect (read inside views, so they redraw on change).
    @MainActor private static var dark: Bool { Preferences.shared.isDark }
    @MainActor static var red: Color {
        let p = Preferences.shared
        _ = p.macAccentTick  // redraw when the Mac's accent changes
        return p.accent.color
    }
    static let redPress = Color(red: 226 / 255, green: 48 / 255, blue: 15 / 255)  // #E2300F
    static let paperFixed = Color(red: 243 / 255, green: 239 / 255, blue: 230 / 255)  // #F3EFE6
    static let inkFixed = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)       // #141414
    /// Text and icons on Aki's surfaces (paper on night, ink on paper).
    @MainActor static var fg: Color { dark ? paperFixed : inkFixed }
    /// Aki's surfaces (night, or paper in light).
    @MainActor static var bg: Color { dark ? Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255) : paperFixed }
    @MainActor static var paper: Color { fg }
    @MainActor static var night: Color { bg }
    @MainActor static var night2: Color { dark ? Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255) : Color(red: 234 / 255, green: 228 / 255, blue: 215 / 255) }
    @MainActor static var nightLine: Color { dark ? Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255) : Color(red: 221 / 255, green: 214 / 255, blue: 200 / 255) }
    @MainActor static var nightInk2: Color { dark ? Color(red: 163 / 255, green: 158 / 255, blue: 147 / 255) : Color(red: 94 / 255, green: 90 / 255, blue: 82 / 255) }

    @MainActor static var inkTop: Color { bg }
    @MainActor static var inkBottom: Color { bg }
    @MainActor static var ink: LinearGradient { LinearGradient(colors: [inkTop, inkBottom], startPoint: .top, endPoint: .bottom) }
    @MainActor static var card: Color { bg }
    /// Kept for places that want one flat colour (orb arc, hit-testable fills).
    @MainActor static var body: Color { bg }
    @MainActor static var ringTrack: Color { fg.opacity(dark ? 0.19 : 0.16) }
    @MainActor static var textPrimary: Color { fg }
    @MainActor static var textSecondary: Color { nightInk2 }
    @MainActor static var glassTextSecondary: Color { fg.opacity(0.76) }
    static let glassDim = Color.black.opacity(0.35)
    static let darkGlassDim = Color.black.opacity(0.6)
    /// Aki's accent: the brand red, flat. (Named "aurora" from the first look; every
    /// former gradient is now this one red, so nothing glows in neon any more.)
    @MainActor static var aurora: [Color] { [red, red, red, red] }
    @MainActor static var auroraLinear: Color { red }
    @MainActor static var auroraDiagonal: Color { red }
    @MainActor static var auroraAngular: Color { red }
    /// Aki's session colours: earthy tones that sit beside the paper, ink and the
    /// pointer's red without glowing (no neon). The red itself is kept for the
    /// selected one, so none of these is red.
    static let sessionHues: [Color] = [
        Color(red: 111 / 255, green: 147 / 255, blue: 189 / 255),  // slate #6F93BD
        Color(red: 217 / 255, green: 164 / 255, blue: 65 / 255),  // ochre #D9A441
        Color(red: 143 / 255, green: 174 / 255, blue: 134 / 255),  // sage #8FAE86
        Color(red: 165 / 255, green: 135 / 255, blue: 176 / 255),  // plum #A587B0
        Color(red: 201 / 255, green: 123 / 255, blue: 92 / 255),  // clay #C97B5C
        Color(red: 95 / 255, green: 163 / 255, blue: 160 / 255),  // teal #5FA3A0
        Color(red: 207 / 255, green: 142 / 255, blue: 152 / 255),  // rose #CF8E98
        Color(red: 169 / 255, green: 163 / 255, blue: 94 / 255),  // olive #A9A35E
        Color(red: 205 / 255, green: 185 / 255, blue: 143 / 255),  // sand #CDB98F
        Color(red: 140 / 255, green: 135 / 255, blue: 124 / 255),  // warm grey #8C877C
    ]
    /// One steady hue per project, from the same tones.
    static let projectHues: [Color] = sessionHues

    static func hue(number: Int?) -> Color {
        guard let number, number > 0 else { return Color.white.opacity(0.6) }
        return sessionHues[(number - 1) % sessionHues.count]
    }

    static func hue(for key: String) -> Color {
        // FNV-1a: stable across launches (Swift's hashValue is not).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return projectHues[Int(hash % UInt64(projectHues.count))]
    }
    /// A hairline rim on dark surfaces.
    @MainActor static var rim: Color { nightLine }
}

enum CardType {
    static let title = Font.system(size: 13.7, weight: .semibold)
    static let body = Font.system(size: 9.5, weight: .regular)
    static let bodyStrong = Font.system(size: 9.5, weight: .semibold)
}

/// Everything inside the fixed-size panel. Opening, closing, the card and the orb
/// are animated here; the window itself never moves on hover.
struct SidebarRoot: View {
    static let space = "akiPanel"
    static let debugTargets = ProcessInfo.processInfo.environment["AKI_DEBUG_TARGETS"] == "1"
    let model: SidebarModel
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferences: Preferences { model.preferences }

    /// Where each project's name goes along the bar, and how wide it may be: over
    /// its group, pushed apart from its neighbours when they'd touch, and cut short
    /// ("LEG…") only when the bar has no room at all.
    private func nameSpots(_ groups: [(first: Int, last: Int, label: String, key: String)], _ layout: SidebarLayout)
        -> [(center: CGFloat, width: CGFloat)]
    {
        let gap = 6 * layout.scale
        // The capsule's width: dot + letters (heavy, 11 pt, tracked) + padding.
        func natural(_ label: String) -> CGFloat { (CGFloat(label.count) * 8.2 + 34) * layout.scale }
        var spots = groups.map { g -> (center: CGFloat, width: CGFloat) in
            ((layout.cellAlongCenter(g.first) + layout.cellAlongCenter(g.last)) / 2,
             natural(model.projectLabel(g.key)))
        }
        // Push right where two would overlap…
        for i in spots.indices.dropFirst() {
            let minCenter = spots[i - 1].center + spots[i - 1].width / 2 + gap + spots[i].width / 2
            if spots[i].center < minCenter { spots[i].center = minCenter }
        }
        // …then back left from the bar's end, shrinking only if they still don't fit.
        if let lastGroup = groups.last {
            let end = layout.cellAlongCenter(lastGroup.last) + layout.step / 2 + 30 * layout.scale
            for i in spots.indices.reversed() {
                let maxCenter = (i == spots.count - 1 ? end : spots[i + 1].center - spots[i + 1].width / 2 - gap) - spots[i].width / 2
                if spots[i].center > maxCenter { spots[i].center = maxCenter }
            }
            for i in spots.indices.dropFirst() {
                let room = (spots[i].center - spots[i].width / 2) - (spots[i - 1].center + spots[i - 1].width / 2) - gap
                if room < 0 {
                    // Share the overlap: both get narrower around their centres.
                    spots[i - 1].width += room
                    spots[i].width += room
                    spots[i - 1].center += room / 2
                    spots[i].center -= room / 2
                }
            }
        }
        return spots
    }

    /// Runs of rings from one project (the +N ring and others left out).
    private func projectGroups(_ rings: [Ring]) -> [(first: Int, last: Int, label: String, key: String)] {
        var groups: [(first: Int, last: Int, key: String)] = []
        for (i, ring) in rings.enumerated() {
            guard case .terminal(let t) = ring else { continue }
            let key = model.projectKey(of: t)
            if let last = groups.last, last.key == key, last.last == i - 1 {
                groups[groups.count - 1].last = i
            } else {
                groups.append((i, i, key))
            }
        }
        return groups.map { ($0.first, $0.last, model.projectLabel($0.key), $0.key) }
    }

    /// From a ring's place back to the pill's middle (where it comes out of).
    private func emergeOffset(_ index: Int, _ layout: SidebarLayout, share: CGFloat = 0.9) -> CGSize {
        let pill = layout.bodyRect(expanded: false)
        let cell = layout.cellCenter(index)
        return CGSize(width: (pill.midX - cell.x) * share, height: (pill.midY - cell.y) * share)
    }

    private func cornerLabel(_ layout: SidebarLayout) -> (String, CGPoint)? {
        if model.markButtonHovered { return ("\(L10n.t("Mark the screen"))  \(L10n.mark)", layout.markOrbCenter) }
        if model.eyeHovered, let eye = model.targets["projects-eye"] {
            return (L10n.t(preferences.showProjects ? "Hide projects" : "Show projects"), CGPoint(x: eye.midX, y: eye.midY))
        }
        if model.historyButtonHovered { return ("\(L10n.t("History"))  \(L10n.history)", layout.historyOrbCenter) }
        if model.orbHovered { return (L10n.t("Settings"), layout.orbCenter) }
        if model.hideButtonHovered {
            return (L10n.t(preferences.visibility == .alwaysShow ? "Kept open · click to let go" : "Keep open"), layout.hideOrbCenter)
        }
        return nil
    }

    var body: some View {
        let rings = model.rings
        // The controller's scale (shrunk to fit the screen), so what's drawn is what's clicked.
        let layout = SidebarLayout(count: rings.count, edge: preferences.edge,
                                   scale: model.layoutScale ?? preferences.size.scale * SidebarLayout.density(rings: rings.count),
                                   labeled: preferences.ringMode == .terminals)
        let size = layout.panelSize
        let shapeRect = layout.bodyRect(expanded: model.expanded)
        let surface = preferences.surface.effective
        let _ = preferences.language  // re-render when the language changes

        // One outline for the body and its colour, so both morph together. The card
        // stays a card all the way down (a hair off the edge), so nothing swaps mid-way.
        let outline = EdgeShape(
            edge: preferences.edge,
            cornerRadius: model.expanded ? layout.corner : SidebarLayout.pillDepth * layout.scale / 2,
            curlRadius: model.expanded ? layout.curl : 6 * layout.scale,
            floating: preferences.barShape == .card ? (model.expanded ? 6 * layout.scale : 0.01) : 0)

        ZStack(alignment: .topLeading) {
            SurfaceFill(shape: outline, surface: surface)
                .frame(width: shapeRect.width, height: shapeRect.height)
                .position(x: shapeRect.midX, y: shapeRect.midY)

            // Folded, the pill wears Aki's colours instead of black: gone at once
            // when it opens, back only once it has shrunk.
            outline
                .fill(LinearGradient(colors: AkiPalette.aurora,
                                     startPoint: preferences.edge.isVertical ? .top : .leading,
                                     endPoint: preferences.edge.isVertical ? .bottom : .trailing))
                .frame(width: shapeRect.width, height: shapeRect.height)
                .position(x: shapeRect.midX, y: shapeRect.midY)
                .opacity(model.expanded ? 0 : 1)
                .animation(model.expanded ? nil : .easeOut(duration: 0.2).delay(0.12), value: model.expanded)
                .allowsHitTesting(false)

            // Folded with marks saved in the queue: their count on the pill.
            if !model.expanded && model.queuedMarks > 0 {
                Text("\(model.queuedMarks)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(AkiPalette.bg)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Circle().fill(AkiPalette.fg))
                    .overlay(Circle().strokeBorder(AkiPalette.bg.opacity(0.6), lineWidth: 1))
                    .position(x: shapeRect.maxX - 4, y: shapeRect.minY + 2)
                    .help("\(model.queuedMarks) \(L10n.t("marks saved in the queue"))")
                    .transition(.scale.combined(with: .opacity))
            }

            // Folded: a sliver of aurora inside the pill when marks are waiting.
            if !model.expanded && rings.contains(where: { $0.pending > 0 }) {
                let vertical = preferences.edge.isVertical
                Capsule()
                    .fill(AkiPalette.fg)
                    .frame(width: vertical ? 3 : 34 * layout.scale, height: vertical ? 34 * layout.scale : 3)
                    .position(x: shapeRect.midX, y: shapeRect.midY)
                    .transition(.opacity)
            }

            if model.expanded {
                if rings.isEmpty && model.loaded {
                    EmptyCell(scale: layout.scale)
                        .position(layout.cellCenter(0))
                        .transition(.opacity)
                } else {
                    ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
                        let isDragged = model.dragging.map { "terminal:" + $0.id == ring.id } ?? false
                        let dragged = isDragged ? model.dragging?.offset ?? 0 : 0
                        RingCell(model: model, ring: ring, scale: layout.scale, hovered: model.hovered == index,
                                 pinned: model.pinned == index)
                            .scaleEffect(isDragged ? 1.12 : 1)
                            .shadow(color: .black.opacity(isDragged ? 0.5 : 0), radius: 8, y: 3)
                            .zIndex(isDragged ? 1 : 0)
                            // The others slide to make room as soon as you drag.
                            .position(layout.cellCenter(isDragged ? index : model.displayIndex(of: index, step: layout.step)))
                            .offset(x: preferences.edge.isVertical ? 0 : dragged,
                                    y: preferences.edge.isVertical ? dragged : 0)
                            .animation(isDragged ? nil : .spring(response: 0.28, dampingFraction: 0.82),
                                       value: model.displayIndex(of: index, step: layout.step))
                            // In: out of the pill, travelling with the body as it opens. Out:
                            // back toward the pill, quickly, before the body closes over them.
                            .transition(.asymmetric(
                                insertion: .modifier(
                                    active: Emerge(offset: emergeOffset(index, layout, share: 1), scale: 0.2, opacity: 0),
                                    identity: Emerge(offset: .zero, scale: 1, opacity: 1)),
                                removal: .modifier(
                                    active: Emerge(offset: .zero, scale: 0.8, opacity: 0),
                                    identity: Emerge(offset: .zero, scale: 1, opacity: 1))
                                    .animation(.easeIn(duration: 0.08))))
                            .animation(reduceMotion ? nil : Motion.fromMiddle(index, of: rings.count), value: model.expanded)
                    }
                }
            }

            // Mark the screen: the settings orb mirrored onto the start of the body.
            Group {
                if layout.card {
                    CardOrb(symbol: "viewfinder", hovered: model.markButtonHovered, spins: 0)
                } else {
                    SettingsOrb(isHovered: model.markButtonHovered, edge: layout.notchEdge,
                                arcRadius: NotchLayout.orbArcRadius, reversed: true, symbol: "viewfinder")
                }
            }
                .scaleEffect(layout.scale)
                .position(layout.markOrbCenter)
                .zIndex(6)
                .opacity(model.expanded && (!layout.card || model.cornerEnd == 0) ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: model.expanded)
                .animation(.easeOut(duration: 0.15), value: model.cornerEnd)
                .allowsHitTesting(false)

            // Projects: a name over each group of rings, a hairline between groups.
            if model.settled, preferences.showProjects {
                let groups = projectGroups(rings)
                if groups.count > 1 {
                    let spots = nameSpots(groups, layout)
                    ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                        ProjectName(model: model, key: g.key, label: g.label, scale: layout.scale, maxWidth: spots[i].width)
                            .clickTarget("project|" + g.key)
                            // High enough to clear the grip's dots when they rise.
                            .position(layout.alongPoint(spots[i].center, out: 30 * layout.scale))
                            .transition(.opacity)
                        if i > 0 {
                            let between = (layout.cellAlongCenter(g.first - 1) + layout.cellAlongCenter(g.first)) / 2
                            Capsule()
                                .fill(AkiPalette.fg.opacity(0.18))
                                .frame(width: preferences.edge.isVertical ? 26 * layout.scale : 1.5,
                                       height: preferences.edge.isVertical ? 1.5 : 26 * layout.scale)
                                .position(layout.midPoint(between))
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                }
            }

            // The eye over the bar's start, before the first name (the "+N" card
            // opens over the far end): projects' names on or off.
            if model.settled, rings.count > 1 {
                let along = layout.cellAlongCenter(0) - 40 * layout.scale
                // Small and quiet: just the eye with a thin rim in Aki's colours (the label
                // on hover says what it does). Off: eye crossed out, plain rim.
                Image(systemName: preferences.showProjects ? "eye" : "eye.slash")
                    .font(.system(size: 9 * layout.scale, weight: .bold))
                    .foregroundStyle(AkiPalette.fg.opacity(model.eyeHovered ? 1 : 0.75))
                    .frame(width: 20 * layout.scale, height: 20 * layout.scale)
                    .background(Circle().fill(AkiPalette.bg.opacity(0.9)))
                    .overlay(Circle().strokeBorder(preferences.showProjects || model.eyeHovered ? AnyShapeStyle(AkiPalette.auroraAngular)
                                                   : AnyShapeStyle(AkiPalette.fg.opacity(0.2)), lineWidth: 1))
                    .scaleEffect(model.eyeHovered ? 1.1 : 1)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: model.eyeHovered)
                    .clickTarget("projects-eye")
                    .position(layout.alongPoint(along, out: 30 * layout.scale))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // At rest each corner shows only a quarter arc, hugging it: there's a
            // button here. At that end, the arcs give way to the buttons.
            if layout.card {
                ForEach(0..<4, id: \.self) { i in
                    let start = i < 2, outer = i % 2 == 0
                    let corner = layout.cardCorner(start: start, outer: outer)
                    CornerArc(trimStart: CornerArc.trim(edge: preferences.edge, toward: layout.towardEdge, start: start, outer: outer),
                              // At that end: thicker and a little further out, besides the colour.
                              radius: corner.radius + (model.cornerEnd == (start ? 0 : 1) ? 7 : 5) * layout.scale,
                              width: (model.cornerEnd == (start ? 0 : 1) ? 5 : 3) * layout.scale,
                              lit: model.pointerInside)
                        .position(corner.center)
                        .opacity(model.settled ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: model.pointerInside)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: model.cornerEnd)
                        .animation(model.settled ? .easeOut(duration: 0.25) : nil, value: model.settled)
                        .allowsHitTesting(false)
                }
            }

            // The card's other two corners: History and Hide.
            if layout.card {
                CardOrb(symbol: "clock.arrow.circlepath", hovered: model.historyButtonHovered, spins: 0)
                    .scaleEffect(layout.scale)
                    .position(layout.historyOrbCenter)
                    .zIndex(6)
                    .opacity(model.expanded && model.cornerEnd == 0 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: model.cornerEnd)
                    .allowsHitTesting(false)
                PinOrb(pinned: preferences.visibility == .alwaysShow, hovered: model.hideButtonHovered)
                    .scaleEffect(layout.scale)
                    .position(layout.hideOrbCenter)
                    .zIndex(6)
                    .opacity(model.expanded && model.cornerEnd == 1 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: model.cornerEnd)
                    .allowsHitTesting(false)
            }

            // What a corner button does, beside it while hovered.
            if model.expanded, let (label, center) = cornerLabel(layout) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AkiPalette.fg)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(AkiPalette.bg.opacity(0.92)))
                    .overlay(Capsule().strokeBorder(AkiPalette.fg.opacity(0.18), lineWidth: 1))
                    .fixedSize()
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    // Beside the button, out past the end of the bar (above it on a side edge),
                    // so it never covers the other button of that end.
                    .frame(width: 220, alignment: preferences.edge.isVertical ? .center
                           : (center.x < layout.panelSize.width / 2 ? .trailing : .leading))
                    .position(preferences.edge.isVertical
                              ? CGPoint(x: center.x - layout.towardEdge.dx * 40 * layout.scale, y: center.y)
                              : CGPoint(x: center.x + (center.x < layout.panelSize.width / 2 ? -1 : 1) * (110 + 24 * layout.scale),
                                        y: center.y))
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }

            // A new version, announced like Orca does: click to see it and install.
            if let version = model.updateVersion {
                let hot = model.hoveredTarget == "update|now"
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 11 * layout.scale, weight: .bold))
                    Text("\(L10n.t("Update to")) \(version)").font(.system(size: 11 * layout.scale, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10 * layout.scale).frame(height: 24 * layout.scale)
                .background(Capsule().fill(AkiPalette.red.opacity(hot ? 1 : 0.92)))
                .shadow(color: AkiPalette.red.opacity(0.45), radius: hot ? 10 : 6)
                .scaleEffect(hot ? 1.05 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hot)
                .fixedSize()
                .clickTarget("update|now")
                .position(layout.updatePillCenter(expanded: model.expanded))
                .transition(.scale.combined(with: .opacity))
            }
            // The drag handle: dots along the bar's far side, inside the body.
            if model.expanded {
                // Under the pointer it rises out of the bar, like a tab, to be grabbed.
                let lift: CGFloat = model.gripHovered ? 14 * layout.scale : 0
                // Size, like a window: a handle in the far corner, shown with the pointer on the bar.
                if model.pointerInside || model.resizing {
                    let c = layout.resizeCenter
                    let lit = model.resizeHovered || model.resizing
                    Image(systemName: layout.resizeDirection.dx * layout.resizeDirection.dy < 0
                          ? "arrow.down.left.and.arrow.up.right" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11 * layout.scale, weight: .heavy))
                        .foregroundStyle(lit ? AkiPalette.bg : AkiPalette.paper)
                        .frame(width: 22 * layout.scale, height: 22 * layout.scale)
                        .background(Circle().fill(lit ? AkiPalette.paper : AkiPalette.night2))
                        .overlay(Circle().strokeBorder(lit ? Color.clear : AkiPalette.nightLine, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .scaleEffect(lit ? 1.1 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lit)
                        .position(c)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                GripDots(vertical: preferences.edge.isVertical, hovered: model.gripHovered, scale: layout.scale)
                    .position(x: layout.gripCenter.x - layout.towardEdge.dx * lift,
                              y: layout.gripCenter.y - layout.towardEdge.dy * lift)
                    .animation(.spring(response: 0.28, dampingFraction: 0.62), value: model.gripHovered)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            Group {
                if layout.card {
                    CardOrb(symbol: "gearshape.fill", hovered: model.orbHovered, spins: model.settingsSpins)
                } else {
                    SettingsOrb(isHovered: model.orbHovered, edge: layout.notchEdge,
                                arcRadius: NotchLayout.orbArcRadius, spins: model.settingsSpins)
                }
            }
                .scaleEffect(layout.scale)
                .position(layout.orbCenter)
                .zIndex(6)
                .opacity(model.expanded && (!layout.card || model.cornerEnd == 1) ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: model.expanded)
                .animation(.easeOut(duration: 0.15), value: model.cornerEnd)

            if model.settled, model.jumping == nil, let index = model.hovered ?? model.pinned, index < rings.count {
                let slot = layout.cardSlot(index)
                RingCard(model: model, ring: rings[index], direction: layout.tailDirection, surface: surface)
                    .clickTarget("card")
                    .frame(width: slot.width, height: slot.height, alignment: cardAlignment)
                    .position(x: slot.midX, y: slot.midY)
                    // Opens with a little grow; on folding it goes at once (no grey ghost).
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: unitAnchor)),
                        removal: .opacity.animation(model.expanded ? .easeOut(duration: 0.15) : .easeOut(duration: 0.06))))
                    .id(rings[index].id)
            }
            // Drawn last, over the card and everything else. "Opening in Orca…": a pill beside the launching ring, away from the
            // screen edge so it's never squeezed against it.
            if model.expanded, let jumping = model.jumping,
                let index = rings.firstIndex(where: { $0.id == "terminal:" + jumping.id })
            {
                let center = layout.cellCenter(index)
                let away = (layout.depth / 2 + 26) * 1
                let point = CGPoint(x: center.x - layout.towardEdge.dx * away, y: center.y - layout.towardEdge.dy * away)
                let hue: Color = {
                    if case .terminal(let t) = rings[index] { return model.hue(of: t) }
                    return .white
                }()
                HStack(spacing: 5) {
                    Circle().fill(hue).frame(width: 6, height: 6)
                    Text(L10n.t("Opening…"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AkiPalette.fg)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(AkiPalette.bg))
                .overlay(Capsule().strokeBorder(hue.opacity(0.8), lineWidth: 1))
                .shadow(color: hue.opacity(0.5), radius: 8)
                .position(point)
                .zIndex(10)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .overlay(alignment: .topLeading) {
            // `AKI_DEBUG_TARGETS=1` outlines what the controller thinks is clickable.
            if Self.debugTargets {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(model.targets.keys.sorted()), id: \.self) { key in
                        let r = model.targets[key]!
                        Rectangle().stroke(key.hasPrefix("eye") ? Color.red : Color.green, lineWidth: 1)
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                    if let r = model.targets["card"] {
                        Rectangle().stroke(Color.yellow, lineWidth: 1)
                            .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ClickTargetsKey.self) { targets in
            MainActor.assumeIsolated { model.targets = targets }
        }
        .animation(reduceMotion ? nil : (model.expanded ? Motion.unfold : Motion.fold), value: model.expanded)
        .animation(Motion.glide, value: model.hovered ?? model.pinned)
        .animation(Motion.hover, value: model.orbHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: model.jumping?.id)
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurfaceStyle, NotchSurfaceStyle(rawValue: preferences.surface.rawValue) ?? .solid)
    }

    static let gripDivide = Animation.timingCurve(0.35, 0, 0.25, 1, duration: 0.42).delay(0.02)
    static let gripHover = Animation.spring(response: 0.22, dampingFraction: 0.55)
    static let gripReturn = Animation.easeIn(duration: 0.2)

    /// The card hugs the side of its slot that faces the body.
    private var cardAlignment: Alignment {
        switch preferences.edge {
        case .right: .trailing
        case .left: .leading
        case .bottom: .bottom
        case .top: .top
        }
    }

    private var unitAnchor: UnitPoint {
        switch preferences.edge {
        case .right: .trailing
        case .left: .leading
        case .bottom: .bottom
        case .top: .top
        }
    }
}


/// Aki's ink, Liquid Glass tinted with it, or glass over a dark ink base,
/// clipped to a shape, with a faint aurora glow inside like the app icon.
struct SurfaceFill<S: Shape>: View {
    let shape: S
    let surface: SurfaceStyle

    var body: some View {
        ZStack {
            switch surface {
            case .solid:
                shape.fill(AkiPalette.ink)
            case .glass:
                if #available(macOS 26.0, *) {
                    // Glass morphs on its own clock and trails the opening; a dark
                    // layer under it follows the shape exactly.
                    shape.fill(AkiPalette.ink).opacity(0.85)
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(AkiPalette.ink)
                }
            case .darkGlass:
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.clear, in: shape).background(shape.fill(AkiPalette.darkGlassDim))
                } else {
                    shape.fill(AkiPalette.ink)
                }
            }
        }
    }
}

// MARK: Cells

/// One cell: the ring, and for a terminal its name in small type under it.
struct RingCell: View {
    let model: SidebarModel
    let ring: Ring
    let scale: CGFloat
    let hovered: Bool
    let pinned: Bool

    var body: some View {
        VStack(spacing: SidebarLayout.labelGap * scale) {
            ringView
                .overlay(alignment: .topLeading) {
                    // The queue: crops of the marks still waiting, fanned beside the
                    // ring; they leave as the agent resolves them.
                    if case .terminal(let terminal) = ring, !terminal.pendingImages.isEmpty {
                        QueueStack(paths: terminal.pendingImages, scale: scale)
                            .offset(x: -10 * scale, y: -12 * scale)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if ring.pending > 0 {
                        Text("\(ring.pending)")
                            .font(.system(size: 8.5 * scale, weight: .bold).monospacedDigit())
                            .foregroundStyle(AkiPalette.fg)
                            .padding(.horizontal, 3.5 * scale)
                            .frame(minWidth: 14 * scale, minHeight: 14 * scale)
                            .background(Capsule().fill(AkiPalette.auroraDiagonal))
                            // A dark edge, and further out on the destination, so its glow doesn't swallow it.
                            .overlay(Capsule().strokeBorder(AkiPalette.bg, lineWidth: 1.5 * scale))
                            .offset(x: (isDestination ? 9 : 3) * scale, y: (isDestination ? -9 : -3) * scale)
                            .zIndex(2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .background {
                    if !isHiddenButton {
                        Circle()
                            .fill(AkiPalette.fg.opacity(hovered || pinned ? 0.10 : 0))
                            .padding(-6 * scale)
                    }
                }
                .overlay {
                    // Counting down to the send: an arc that runs out around the ring.
                    if case .terminal(let t) = ring, let wait = model.deliverAt[t.id] {
                        TimelineView(.animation) { context in
                            let total = max(wait.end.timeIntervalSince(wait.start), 0.1)
                            let left = min(max(wait.end.timeIntervalSince(context.date) / total, 0), 1)
                            Circle().trim(from: 0, to: left)
                                .stroke(AkiPalette.fg, style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(-10 * scale)
                        }
                        .allowsHitTesting(false)
                    }
                    // The agent finished every mark: a ✓ pops on the ring.
                    if case .terminal(let t) = ring, model.finished.contains(t.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18 * scale, weight: .bold))
                            .foregroundStyle(.white, Color.green)
                            .shadow(color: .green.opacity(0.7), radius: 8)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.5), value: model.finished)
                .overlay {
                    if isDestination {
                        // Where new marks go: Aki's own aurora, thick and glowing, so it
                        // can't be mistaken for a project's colour.
                        Circle().strokeBorder(AkiPalette.auroraAngular, lineWidth: 3 * scale)
                            .padding(-6 * scale)
                            .shadow(color: AkiPalette.aurora[2].opacity(0.8), radius: 8)
                    } else if pinned {
                        Circle().strokeBorder(AkiPalette.fg.opacity(0.4), lineWidth: 1).padding(-6 * scale)
                    }
                }
                .scaleEffect(launching ? 1.3 : justReceived ? 1.22 : hovered ? (isDestination ? 1.26 : 1.08) : isDestination ? 1.22 : 1)
                .shadow(color: justReceived || launching ? receivedGlow : .clear, radius: launching ? 16 : 10)
                .animation(.spring(response: 0.25, dampingFraction: 0.5), value: launching)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: hovered)
                .animation(.spring(response: 0.35, dampingFraction: 0.45), value: justReceived)
            if case .hidden = ring {
                Text(L10n.t("hidden sessions, short"))
                    .font(.system(size: SidebarLayout.labelFont * scale, weight: .semibold))
                    .foregroundStyle(AkiPalette.textSecondary)
                    .frame(width: (SidebarLayout.ring + 22) * scale, height: SidebarLayout.labelHeight * scale)
            }
            if case .more = ring {
                Text(L10n.t("more terminals"))
                    .font(.system(size: SidebarLayout.labelFont * scale, weight: .semibold))
                    .foregroundStyle(AkiPalette.textSecondary)
                    .lineLimit(1)
                    .frame(width: (SidebarLayout.ring + 22) * scale, height: SidebarLayout.labelHeight * scale)
            }
            if case .terminal(let terminal) = ring {
                // Its number first (⌘1–⌘9 picks it while marking), then the name.
                (Text(model.number(of: terminal.id).map { "\($0) " } ?? "")
                    .font(.system(size: SidebarLayout.labelFont * scale * (isDestination ? 1.15 : 1), weight: .heavy,
                                  design: .rounded).monospacedDigit())
                    .foregroundColor(isDestination ? .black : AkiPalette.textPrimary)
                    + Text(terminal.name))
                    .font(.system(size: SidebarLayout.labelFont * scale * (isDestination ? 1.15 : 1),
                                  weight: isDestination ? .bold : .semibold))
                    .foregroundStyle(hovered || isDestination ? AkiPalette.textPrimary : AkiPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, isDestination ? 5 * scale : 0)
                    .background {
                        if isDestination { Capsule().fill(AkiPalette.auroraDiagonal) }
                    }
                    .frame(width: (SidebarLayout.ring + 22) * scale, height: SidebarLayout.labelHeight * scale)
            }
        }
    }

    private var isDestination: Bool {
        if case .terminal(let terminal) = ring { return model.selectedTerminal == terminal.id }
        return false
    }

    private var launching: Bool {
        if case .terminal(let terminal) = ring { return model.jumping?.id == terminal.id }
        return false
    }

    private var isHiddenButton: Bool {
        if case .hidden = ring { return true }
        return false
    }

    private var justReceived: Bool {
        if case .terminal(let terminal) = ring { return model.flashed.contains(terminal.id) }
        return false
    }

    private var receivedGlow: Color {
        if case .terminal(let terminal) = ring {
            return model.hue(of: terminal).opacity(0.9)
        }
        return .clear
    }

    @ViewBuilder private var ringView: some View {
        switch ring {
        case .agent(let group):
            RingView(agent: group.agent, pending: group.pending, working: group.working, listening: group.listening,
                     dim: group.sessions.isEmpty && group.hidden.isEmpty, scale: scale)
        case .terminal(let terminal):
            RingView(agent: terminal.agent, pending: terminal.pending,
                     working: terminal.state == .working || terminal.state == .shell,
                     listening: terminal.state == .listening, dim: false, scale: scale,
                     monogram: model.monogram(for: terminal.name),
                     hue: model.hue(of: terminal),
                     waiting: terminal.state == .waiting, appIcon: model.appIcon(of: terminal))
        case .hidden(let sessions):
            // A small button, not a ring: it's the way back to hidden sessions.
            HStack(spacing: 4 * scale) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10 * scale, weight: .semibold))
                Text("\(sessions.count)")
                    .font(.system(size: 11 * scale, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(hovered || pinned ? AkiPalette.textPrimary : AkiPalette.textSecondary)
            .padding(.horizontal, 8 * scale)
            .frame(height: 22 * scale)
            .background(Capsule().fill(AkiPalette.fg.opacity(hovered || pinned ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(AkiPalette.ringTrack, lineWidth: 1))
            .frame(width: SidebarLayout.ring * scale, height: SidebarLayout.ring * scale)
        case .more(let sessions):
            ZStack {
                Circle().strokeBorder(AkiPalette.ringTrack, style: StrokeStyle(lineWidth: SidebarLayout.trackStroke * scale, dash: [2.5 * scale, 3 * scale]))
                // Something inside is going on: show it on the ring, too.
                RingView(agent: .claude, pending: 0,
                         working: sessions.contains { $0.state == .working || $0.state == .shell },
                         listening: false, dim: false, scale: scale, monogram: "",
                         hue: .clear, waiting: sessions.contains { $0.state == .waiting }, calm: true)
                Text("+\(sessions.count)")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AkiPalette.textPrimary)
            }
            .frame(width: SidebarLayout.ring * scale, height: SidebarLayout.ring * scale)
        }
    }
}

/// Six dots, the handle you drag the sidebar by: brighter and a little bigger
/// under the pointer.
struct GripDots: View {
    let vertical: Bool
    let hovered: Bool
    let scale: CGFloat

    var body: some View {
        let dot = 3.4 * scale * (hovered ? 1.2 : 1)
        let grid = Grid(horizontalSpacing: 4.5 * scale, verticalSpacing: 4 * scale) {
            ForEach(0..<(vertical ? 3 : 2), id: \.self) { _ in
                GridRow {
                    ForEach(0..<(vertical ? 2 : 3), id: \.self) { _ in
                        Circle().fill(AkiPalette.fg.opacity(hovered ? 1 : 0.5)).frame(width: dot, height: dot)
                    }
                }
            }
        }
        return grid
            .padding(.horizontal, 9 * scale)
            .padding(.vertical, 6 * scale)
            .background(Capsule().fill(hovered ? AkiPalette.bg : Color.clear))
            .overlay(Capsule().strokeBorder(AkiPalette.fg.opacity(hovered ? 0.35 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(hovered ? 0.5 : 0), radius: 6, y: 2)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovered)
    }
}

/// A key as it looks on the keyboard, for showing shortcuts at a glance.
struct Keycap: View {
    let key: String
    var size: CGFloat = 9.5

    var body: some View {
        Text(key)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(AkiPalette.fg.opacity(0.9))
            .padding(.horizontal, 4)
            .frame(minWidth: size + 8, minHeight: size + 6)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(AkiPalette.fg.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(AkiPalette.fg.opacity(0.18), lineWidth: 0.6))
    }
}

/// Up to three thumbnails of queued marks, fanned like cards in a hand.
struct QueueStack: View {
    let paths: [String]
    let scale: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(paths.prefix(3).enumerated().reversed()), id: \.element) { index, path in
                Group {
                    if let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        AkiPalette.fg.opacity(0.2)
                    }
                }
                .frame(width: 18 * scale, height: 14 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 2.5 * scale))
                .overlay(RoundedRectangle(cornerRadius: 2.5 * scale).strokeBorder(AkiPalette.fg.opacity(0.85), lineWidth: 1))
                .rotationEffect(.degrees(Double(index) * -9))
                .offset(x: CGFloat(index) * -3 * scale, y: CGFloat(index) * -2 * scale)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: paths)
    }
}

/// Codenotch's ring with Aki's meaning: the aurora arc fills when marks are
/// waiting, spins while the agent works, breathes while `aki wait` listens.
struct RingView: View {
    let agent: AgentSession.Agent
    let pending: Int
    let working: Bool
    let listening: Bool
    let dim: Bool
    let scale: CGFloat
    /// For a terminal: its initials in the middle, its project hue on the track,
    /// and the agent as a small badge instead of the big mark.
    var monogram: String? = nil
    var hue: Color? = nil
    /// The agent is asking you something: the ring breathes in amber.
    var waiting = false
    /// The app the conversation runs in (Orca, Warp…), as a tiny badge.
    var appIcon: NSImage? = nil
    /// Shows the state without moving (the +N ring: it shouldn't blink).
    var calm = false
    @State private var turning = false
    @State private var breathing = false

    private var progress: CGFloat { SidebarLayout.progressStroke * scale }
    private var track: CGFloat { SidebarLayout.trackStroke * scale }

    var body: some View {
        ZStack {
            Circle().strokeBorder(hue.map { $0.opacity(0.6) } ?? AkiPalette.ringTrack, lineWidth: track)

            if waiting {
                Circle()
                    .inset(by: track / 2)
                    .stroke(AkiPalette.aurora[0], style: StrokeStyle(lineWidth: progress + 1, lineCap: .round))
                    .opacity(calm ? 0.7 : (breathing ? 1 : 0.5))
            } else if pending > 0 {
                Circle()
                    .inset(by: track / 2)
                    .stroke(AkiPalette.auroraAngular, style: StrokeStyle(lineWidth: progress, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else if working {
                // Working: an arc going round slowly (one turn in ~3.5 s) — clearly
                // running, calm enough to have on screen all day.
                Circle()
                    .inset(by: track / 2)
                    .trim(from: 0, to: 0.3)
                    .stroke(AkiPalette.auroraAngular, style: StrokeStyle(lineWidth: progress, lineCap: .round))
                    .rotationEffect(.degrees(calm ? -90 : (turning ? 270 : -90)))
            } else if listening {
                Circle()
                    .inset(by: track / 2)
                    .stroke(AkiPalette.auroraAngular, style: StrokeStyle(lineWidth: progress, lineCap: .round))
                    .opacity(breathing ? 0.9 : 0.25)
            }

            if let monogram {
                // An empty monogram draws only the ring's state (the +N ring uses it).
                Text(monogram)
                    .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(AkiPalette.fg)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 6 * scale)
            } else {
                AgentGlyphView(agent: agent, size: SidebarLayout.glyph * scale)
                    .foregroundStyle(AkiPalette.fg)
                    // No terminal open for this agent: still there, but quiet.
                    .opacity(dim ? 0.35 : 1)
            }
        }
        .frame(width: SidebarLayout.ring * scale, height: SidebarLayout.ring * scale)
        // Which agent runs here, in its own colours (Claude's orange ✳…), big enough to read.
        .overlay(alignment: .bottomTrailing) {
            if monogram?.isEmpty == false {
                AgentGlyphView(agent: agent, size: 11 * scale)
                    .foregroundStyle(agent.brand.glyph)
                    .frame(width: 18 * scale, height: 18 * scale)
                    .background(Circle().fill(agent.brand.fill))
                    .overlay(Circle().strokeBorder(AkiPalette.bg, lineWidth: 1.5 * scale))
                    .offset(x: 3 * scale, y: 3 * scale)
            }
        }
        .onAppear(perform: animate)
        .onChange(of: working) { animate() }
        .onChange(of: listening) { animate() }
        .onChange(of: waiting) { animate() }
    }

    private func animate() {
        turning = false
        breathing = false
        if calm { return }
        if waiting {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
        } else if working {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { turning = true }
        } else if listening {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

struct EmptyCell: View {
    let scale: CGFloat

    var body: some View {
        Circle().strokeBorder(AkiPalette.ringTrack, lineWidth: SidebarLayout.trackStroke * scale)
            .overlay(Image(systemName: "sparkle").font(.system(size: 13 * scale, weight: .bold)).foregroundStyle(AkiPalette.textSecondary))
            .frame(width: SidebarLayout.ring * scale, height: SidebarLayout.ring * scale)
            .help(L10n.t("No agents running"))
    }
}

// MARK: Card

/// The card for whichever kind of ring is hovered.
struct RingCard: View {
    let model: SidebarModel
    let ring: Ring
    let direction: TailDirection
    let surface: SurfaceStyle

    var body: some View {
        switch ring {
        case .agent(let group): GroupCard(model: model, group: group, direction: direction, surface: surface)
        case .terminal(let terminal): TerminalCard(model: model, terminal: terminal, direction: direction, surface: surface)
        case .more(let terminals): MoreCard(model: model, terminals: terminals, direction: direction, surface: surface)
        case .hidden(let terminals):
            MoreCard(model: model, terminals: terminals, direction: direction, surface: surface, hidden: true)
        }
    }
}

/// The card behind the "+N" ring: the conversations that didn't get a ring.
struct MoreCard: View {
    let model: SidebarModel
    let terminals: [AgentTerminal]
    let direction: TailDirection
    let surface: SurfaceStyle
    /// Listing the hidden ones: the eye brings each back.
    var hidden = false

    private var secondary: Color { surface == .solid ? AkiPalette.textSecondary : AkiPalette.glassTextSecondary }

    var body: some View {
        TooltipShell(direction: direction, surface: surface) {
            VStack(alignment: .leading, spacing: 7.5) {
                Text(hidden
                     ? "\(terminals.count) \(L10n.t(terminals.count == 1 ? "hidden session" : "hidden sessions"))"
                     : "\(terminals.count) \(L10n.t("more terminals"))")
                    .font(CardType.title).foregroundStyle(AkiPalette.textPrimary)
                if hidden {
                    Text(L10n.t("They're out of the sidebar. Show one to bring its ring back."))
                        .font(CardType.body).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(terminals) { terminal in
                        SessionLine(model: model, terminal: terminal, secondary: secondary,
                                    hidden: hidden || model.preferences.hiddenTerminals.contains(terminal.id))
                    }
                }
                if hidden && terminals.count > 1 {
                    let key = "unhideall|all"
                    Text(L10n.t("Show all"))
                        .font(CardType.bodyStrong)
                        .foregroundStyle(model.hoveredTarget == key ? AkiPalette.textPrimary : secondary)
                        .padding(.horizontal, 4).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(AkiPalette.fg.opacity(model.hoveredTarget == key ? 0.08 : 0)))
                        .clickTarget(key)
                }
            }
        }
    }
}

/// A session's state in a list, like its ring in small: a spinning arc while it
/// works, an amber pulse while it waits for you, an outline while `aki wait`
/// listens, a quiet dot when idle.
struct LiveDot: View {
    let state: AgentTerminal.State
    let hue: Color
    @State private var turning = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch state {
            case .working, .shell:
                Circle().strokeBorder(hue.opacity(0.3), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(hue, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 360 : 0))
            case .waiting:
                Circle()
                    .fill(AkiPalette.aurora[0].opacity(0.5))
                    .scaleEffect(pulse ? 2 : 0.7)
                    .opacity(pulse ? 0 : 1)
                Circle().fill(AkiPalette.aurora[0]).padding(2)
            case .listening:
                Circle().strokeBorder(hue, lineWidth: 1.5).padding(1)
            case .idle:
                Circle().fill(hue.opacity(0.55)).padding(2)
            }
        }
        .frame(width: 10, height: 10)
        .onAppear(perform: animate)
        .onChange(of: state) { animate() }
    }

    private func animate() {
        turning = false
        pulse = false
        switch state {
        case .working, .shell:
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        case .waiting:
            withAnimation(.easeOut(duration: 0.8).repeatForever(autoreverses: false)) { pulse = true }
        default:
            break
        }
    }
}

/// One conversation in a list: its state, name and project. Click sends marks
/// there; the eye hides it from the sidebar.
struct SessionLine: View {
    let model: SidebarModel
    let terminal: AgentTerminal
    let secondary: Color
    var hidden = false

    private var rowKey: String { "term|" + terminal.id }
    private var eyeKey: String { "hide|" + terminal.id }

    /// The state worth reading at a glance; idle says nothing.
    private var activeState: String? {
        switch terminal.state {
        case .waiting: L10n.t("waiting for you")
        case .working: L10n.t("working")
        case .shell: L10n.t("running a command")
        case .listening, .idle: nil
        }
    }
    private var hovered: Bool { model.hoveredTarget == rowKey || model.hoveredTarget == eyeKey }
    private var selected: Bool { model.selectedTerminal == terminal.id }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                AgentGlyphView(agent: terminal.agent, size: 15)
                    .foregroundStyle(AkiPalette.textPrimary)
                LiveDot(state: terminal.state, hue: model.hue(of: terminal))
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.name)
                    .font(selected ? CardType.bodyStrong : CardType.body)
                    .foregroundStyle(AkiPalette.textPrimary)
                    .lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                SessionIdentityView(identity: SessionIdentity(terminal: terminal), size: 10)
                    .font(CardType.body).foregroundStyle(secondary)
                if let state = activeState {
                    Text(state).font(CardType.body)
                        .foregroundStyle(terminal.state == .waiting ? AkiPalette.aurora[0] : secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hidden {
                HStack(spacing: 3) {
                    Image(systemName: "eye").font(.system(size: 8, weight: .semibold))
                    Text(L10n.t("Show")).font(CardType.bodyStrong)
                }
                .foregroundStyle(model.hoveredTarget == eyeKey ? AkiPalette.bg : AkiPalette.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(AkiPalette.fg.opacity(model.hoveredTarget == eyeKey ? 0.95 : 0.14)))
                .fixedSize()
                .clickTarget(eyeKey)
            } else if hovered {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(model.hoveredTarget == eyeKey ? AkiPalette.textPrimary : secondary)
                    .frame(width: 24, height: 20)
                    .background(Capsule().fill(AkiPalette.fg.opacity(model.hoveredTarget == eyeKey ? 0.16 : 0)))
                    .clickTarget(eyeKey)
            }
            if selected {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(AkiPalette.fg)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(AkiPalette.fg.opacity(hovered ? 0.08 : 0)))
        .animation(.easeOut(duration: 0.12), value: hovered)
        .clickTarget(rowKey)
    }
}

/// The card beside a conversation's ring, like Orca's session list: what it's
/// called, where it runs, what it's doing, what the agent said last.
struct TerminalCard: View {
    let model: SidebarModel
    let terminal: AgentTerminal
    let direction: TailDirection
    let surface: SurfaceStyle

    private var secondary: Color { surface == .solid ? AkiPalette.textSecondary : AkiPalette.glassTextSecondary }
    private var sendKey: String { "term|" + terminal.id }
    private var hideKey: String { "hide|" + terminal.id }
    private var isDestination: Bool { model.selectedTerminal == terminal.id }

    var body: some View {
        let counts = model.counts(for: [terminal.worktree])

        TooltipShell(direction: direction, surface: surface) {
            VStack(alignment: .leading, spacing: 7.5) {
                if actionsFirst {
                    actions
                    Hairline()
                }
                HStack(alignment: .center, spacing: 6.4) {
                    // The agent in its own colours, as on the ring.
                    AgentGlyphView(agent: terminal.agent, size: 17)
                        .foregroundStyle(terminal.agent.brand.glyph)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(terminal.agent.brand.fill))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(terminal.name).font(CardType.title).foregroundStyle(AkiPalette.textPrimary)
                            .lineLimit(2)
                        Text(terminal.agent.displayName).font(CardType.bodyStrong)
                            .foregroundStyle(terminal.agent.brand.fill == .white ? secondary : terminal.agent.brand.fill)
                        Text([model.project(of: terminal), terminal.branch,
                              model.appName(of: terminal).map { "\(L10n.t("in")) \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(CardType.body).foregroundStyle(secondary).lineLimit(1)
                    }
                }
                Hairline()
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 6, height: 6)
                    Text(stateText).font(CardType.bodyStrong).foregroundStyle(AkiPalette.textPrimary)
                    Spacer(minLength: 0)
                    if let updated = terminal.updatedAt {
                        Text(updated, style: .relative).font(CardType.body).foregroundStyle(secondary)
                    }
                }
                // How much this session has been sent (pictures and data).
                if let sent = model.sentBySession[terminal.id], sent.marks > 0 {
                    SplitRow(L10n.t("Sent"), "\(ByteCountFormatter.string(fromByteCount: Int64(sent.bytes), countStyle: .file)) · \(sent.marks) \(L10n.t(sent.marks == 1 ? "mark" : "marks"))", secondary)
                }
                // Claude Code's own numbers: this session's context, the account's limits.
                if let status = model.claudeStatus[terminal.id], let context = status.contextPercent {
                    UsageRow(title: L10n.t("Context"), percent: context, detail: status.model?.replacingOccurrences(of: "Claude ", with: ""), secondary: secondary)
                }
                if let limits = model.accountLimits, terminal.agent == .claude {
                    if let five = limits.fiveHour {
                        UsageRow(title: "5h", percent: five.percent, detail: five.resets.map(Self.renews), secondary: secondary)
                    }
                    if let week = limits.week {
                        UsageRow(title: L10n.t("Week"), percent: week.percent, detail: week.resets.map(Self.renews), secondary: secondary)
                    }
                }
                if let message = terminal.lastMessage {
                    Text(message.replacingOccurrences(of: "**", with: ""))
                        .font(CardType.body)
                        .foregroundStyle(secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !terminal.pendingComments.isEmpty, terminal.undelivered == 0,
                    model.delivery[terminal.id] == nil
                {
                    // Already with the agent: one line; the pointer on it shows what went.
                    Hairline()
                    queueLine
                } else if !terminal.pendingComments.isEmpty {
                    Hairline()
                    VStack(alignment: .leading, spacing: 4) {
                        SplitRow(L10n.t("Pending"), "\(terminal.pending)", secondary)
                        ForEach(Array(terminal.pendingComments.enumerated()), id: \.offset) { _, comment in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(AkiPalette.auroraLinear).frame(width: 5, height: 5)
                                Text(comment).font(CardType.body).foregroundStyle(AkiPalette.textPrimary).lineLimit(2)
                            }
                        }
                        deliverButton
                    }
                }
                if model.preferences.cardDetail == .full {
                    Hairline()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(L10n.t("Today")) · \(model.project(of: terminal))").font(CardType.bodyStrong).foregroundStyle(AkiPalette.textPrimary)
                        SplitRow(L10n.t("Marks sent"), "\(counts.today.marks)", secondary)
                        SplitRow(L10n.t("Screenshots"), "\(counts.today.images)", secondary)
                        SplitRow(L10n.t("Resolved"), "\(counts.today.resolved)", secondary)
                        SplitRow(L10n.t("Pictures on disk"),
                                 ByteCountFormatter.string(fromByteCount: model.diskUsage.imageBytes, countStyle: .file), secondary)
                    }
                    Hairline()
                    VStack(alignment: .leading, spacing: 5) {
                        SplitRow(L10n.t("30 days"), "\(counts.daily.reduce(0, +)) \(L10n.t("marks"))", secondary)
                        DailyBars(values: counts.daily)
                    }
                }
                if !actionsFirst {
                    Hairline()
                    actions
                }
            }
        }
    }

    /// The actions go on the side of the card nearest its ring: first when the card
    /// hangs below the bar (top edge), last otherwise.
    /// "↻ 2h40" within a day, "↻ Tue 3 AM" later (short, so the bars have room).
    static func renews(_ date: Date) -> String {
        let left = max(0, Int(date.timeIntervalSinceNow / 60))
        if left < 24 * 60 {
            // Within a day: how long ("↻ 2h40").
            return "↻ " + (left >= 60 ? "\(left / 60)h\(String(format: "%02d", left % 60))" : "\(left) min")
        }
        return "↻ " + date.formatted(.dateTime.weekday(.abbreviated).hour())
    }

    private var actionsFirst: Bool { direction == .down }

    /// "3 with the agent": the marks already handed over, listed while hovered.
    private var queueLine: some View {
        let key = "queue|" + terminal.id
        let open = model.hoveredTarget == key
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill").font(.system(size: 10, weight: .bold)).frame(width: 12)
                Text("\(terminal.pending) \(L10n.t("with the agent"))").font(CardType.bodyStrong)
                Spacer(minLength: 0)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(AkiPalette.textPrimary)
            if open {
                ForEach(Array(terminal.pendingComments.enumerated()), id: \.offset) { _, comment in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(model.hue(of: terminal)).frame(width: 5, height: 5)
                        Text(comment).font(CardType.body).foregroundStyle(secondary).lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(AkiPalette.fg.opacity(open ? 0.08 : 0.04)))
        .animation(.easeOut(duration: 0.15), value: open)
        .clickTarget(key)
    }

    /// Types the request into the session's tab, so the agent starts on the marks.
    private var deliverButton: some View {
        let key = "deliver|" + terminal.id
        let hovered = model.hoveredTarget == key
        let state = model.delivery[terminal.id]
        let hue = model.hue(of: terminal)
        return HStack(spacing: 6) {
            Group {
                switch state {
                case .sending: ProgressView().controlSize(.mini)
                case .sent: Image(systemName: "checkmark.circle.fill")
                case .failed: Image(systemName: "exclamationmark.triangle.fill")
                case nil: Image(systemName: "paperplane.fill")
                }
            }
            .font(.system(size: 10, weight: .bold))
            .frame(width: 12)
            Text(L10n.t(state == nil && model.deliverAt[terminal.id] != nil ? "Sending to the terminal in" : state == .sending ? "Sending…" : state == .sent ? "Sent to the terminal"
                        : state == .failed ? "Couldn't find its tab" : "Send to the terminal now"))
                .font(CardType.bodyStrong)
            Spacer(minLength: 0)
            if state == nil, let wait = model.deliverAt[terminal.id] {
                // Counting down to the send: the seconds left, live.
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let left = Int(wait.end.timeIntervalSince(context.date).rounded(.up))
                    // Past zero it waits for the agent to be free: dots instead of "0 s".
                    Text(left > 0 ? "\(left) s" : "…")
                        .font(CardType.bodyStrong).monospacedDigit()
                }
            } else if state == nil, model.preferences.autoDeliver {
                Text("\(model.preferences.waitIdleSeconds) s").font(CardType.body).opacity(0.8)
            }
        }
        .foregroundStyle(AkiPalette.fg)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(hue.opacity(hovered ? 1 : 0.8)))
        // The bar empties as the send gets closer.
        .overlay(alignment: .leading) {
            if state == nil, let wait = model.deliverAt[terminal.id] {
                TimelineView(.animation) { context in
                    let total = max(wait.end.timeIntervalSince(wait.start), 0.1)
                    let left = min(max(wait.end.timeIntervalSince(context.date) / total, 0), 1)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 6).fill(AkiPalette.fg.opacity(0.18))
                            .frame(width: g.size.width * left)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .padding(.top, 3)
        .clickTarget(key)
        .help(model.preferences.autoDeliver
              ? "\(L10n.t("Send to the terminal by itself")): \(model.preferences.waitIdleSeconds) s" : "")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 3) {
            action("mark|" + terminal.id, icon: "viewfinder", title: L10n.t("Mark the screen for this"), keys: L10n.mark)
            action(sendKey, icon: isDestination ? "checkmark.circle.fill" : "scope",
                   title: L10n.t(isDestination ? "Marks go here" : "Send marks here"))
            action("history|" + terminal.id, icon: "clock.arrow.circlepath", title: L10n.t("History of this session"), keys: L10n.history)
            if terminal.pending > 0 {
                action("move|" + terminal.id, icon: "arrow.left.arrow.right", title: "\(L10n.t("Move marks to")) (\(terminal.pending))…")
            }
            action(hideKey, icon: "eye.slash", title: L10n.t("Hide this session"))
        }
    }

    private var stateText: String {
        switch terminal.state {
        case .waiting: L10n.t("waiting for you")
        case .working: L10n.t("working")
        case .shell: L10n.t("running a command")
        case .listening: L10n.t("listening")
        case .idle: L10n.t("idle")
        }
    }

    private var stateColor: Color {
        switch terminal.state {
        case .waiting: AkiPalette.red          // needs you: the one red
        case .working, .shell: AkiPalette.paper
        case .listening: AkiPalette.nightInk2
        case .idle: AkiPalette.ringTrack
        }
    }

    /// A clickable line in the card (handled by the controller, see `clickTarget`).
    private func action(_ key: String, icon: String, title: String, keys: String? = nil) -> some View {
        let hovered = model.hoveredTarget == key
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold)).frame(width: 12)
            Text(title).font(CardType.body)
            Spacer(minLength: 0)
            if let keys { Keycap(key: keys, size: 8.5) }
        }
        .foregroundStyle(hovered || (key == sendKey && isDestination) ? AkiPalette.textPrimary : secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(AkiPalette.fg.opacity(hovered ? 0.08 : 0)))
        .animation(.easeOut(duration: 0.12), value: hovered)
        .clickTarget(key)
    }
}

/// The card beside a hovered ring: the agent, its terminals (click one to send
/// new marks there) and how much you've used Aki with them.
struct GroupCard: View {
    let model: SidebarModel
    let group: AgentGroup
    let direction: TailDirection
    let surface: SurfaceStyle

    private var secondary: Color { surface == .solid ? AkiPalette.textSecondary : AkiPalette.glassTextSecondary }

    var body: some View {
        let worktrees = Set(group.sessions.map(\.worktree))
        let counts = model.counts(for: worktrees)

        TooltipShell(direction: direction, surface: surface) {
            VStack(alignment: .leading, spacing: 7.5) {
                header
                Hairline()
                VStack(alignment: .leading, spacing: 3) {
                    if group.sessions.isEmpty && group.hidden.isEmpty {
                        Text(L10n.t("No terminals open right now.")).font(CardType.body).foregroundStyle(secondary)
                    }
                    ForEach(group.sessions.prefix(10)) { session in
                        TerminalRow(model: model, label: model.label(for: session), session: session,
                                    hidden: false, secondary: secondary)
                    }
                    if !group.hidden.isEmpty {
                        Text(L10n.t("Hidden terminals"))
                            .font(CardType.bodyStrong)
                            .foregroundStyle(secondary)
                            .padding(.top, 4)
                            .padding(.horizontal, 4)
                        ForEach(group.hidden) { session in
                            TerminalRow(model: model, label: model.label(for: session), session: session,
                                        hidden: true, secondary: secondary)
                        }
                    }
                }
                .animation(.snappy(duration: 0.25), value: group.hidden.map(\.worktree))
                if model.preferences.cardDetail == .full {
                    Hairline()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("Today")).font(CardType.bodyStrong).foregroundStyle(AkiPalette.textPrimary)
                        SplitRow(L10n.t("Marks sent"), "\(counts.today.marks)", secondary)
                        SplitRow(L10n.t("Screenshots"), "\(counts.today.images)", secondary)
                        SplitRow(L10n.t("Resolved"), "\(counts.today.resolved)", secondary)
                    }
                    Hairline()
                    VStack(alignment: .leading, spacing: 5) {
                        SplitRow(L10n.t("30 days"), "\(counts.daily.reduce(0, +)) \(L10n.t("marks"))", secondary)
                        DailyBars(values: counts.daily)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6.4) {
            AgentGlyphView(agent: group.agent, size: 22).foregroundStyle(AkiPalette.fg)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(group.agent.displayName).font(CardType.title).foregroundStyle(AkiPalette.textPrimary)
                    Spacer(minLength: 8)
                    if group.pending > 0 {
                        Text("\(group.pending) \(L10n.t("pending"))")
                            .font(CardType.bodyStrong)
                            .foregroundStyle(AkiPalette.auroraLinear)
                    }
                }
                let count = group.sessions.count
                Text("\(count) \(L10n.t(count == 1 ? "terminal" : "terminals"))")
                    .font(CardType.body)
                    .foregroundStyle(secondary)
            }
        }
    }
}

/// One terminal in the card. The panel never takes focus, so SwiftUI buttons and
/// hover don't fire here: the controller reads the pointer itself and these rows
/// only report where they are (`clickTarget`) and draw the hover it tells them.
struct TerminalRow: View {
    let model: SidebarModel
    let label: String
    let session: AgentSession
    let hidden: Bool
    let secondary: Color

    private var rowKey: String { "row|" + session.worktree }
    private var eyeKey: String { "eye|" + session.worktree }
    private var hovered: Bool { model.hoveredTarget == rowKey || model.hoveredTarget == eyeKey }
    private var selected: Bool { !hidden && model.selected == session.worktree }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(session: session)
            Text(label)
                .font(selected ? CardType.bodyStrong : CardType.body)
                .foregroundStyle(hidden ? secondary : AkiPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if hovered || hidden {
                Image(systemName: hidden ? "eye" : "eye.slash")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(model.hoveredTarget == eyeKey ? AkiPalette.textPrimary : secondary)
                    .frame(width: 24, height: 16)
                    .background(Capsule().fill(AkiPalette.fg.opacity(model.hoveredTarget == eyeKey ? 0.16 : 0)))
                    .contentShape(Rectangle())
                    .clickTarget(eyeKey)
            } else {
                Text(status)
                    .font(CardType.body)
                    .foregroundStyle(session.pending > 0 ? AnyShapeStyle(AkiPalette.auroraLinear) : AnyShapeStyle(secondary))
                    .lineLimit(1)
            }
            if selected {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(AkiPalette.fg)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(AkiPalette.fg.opacity(hovered && !hidden ? 0.08 : 0)))
        .animation(.easeOut(duration: 0.12), value: hovered)
        .clickTarget(rowKey)
    }

    private var status: String {
        if session.pending > 0 { return "\(session.pending) \(L10n.t("pending"))" }
        if session.working { return L10n.t("working") }
        if session.listening { return L10n.t("listening") }
        return session.branch ?? L10n.t("idle")
    }
}

/// Where clickable parts of the panel are, in the panel's own coordinates.
struct ClickTargetsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame as a click/hover target named `key`.
    func clickTarget(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ClickTargetsKey.self, value: [key: proxy.frame(in: .named(SidebarRoot.space))])
        })
    }
}

struct StatusDot: View {
    let session: AgentSession

    var body: some View {
        Group {
            if session.pending > 0 {
                Circle().fill(AkiPalette.auroraLinear)
            } else if session.working || session.listening {
                Circle().strokeBorder(AkiPalette.auroraLinear, lineWidth: 1.5)
            } else {
                Circle().fill(AkiPalette.ringTrack)
            }
        }
        .frame(width: 6, height: 6)
    }
}

struct SplitRow: View {
    let leading: String
    let trailing: String
    let secondary: Color

    init(_ leading: String, _ trailing: String, _ secondary: Color) {
        self.leading = leading
        self.trailing = trailing
        self.secondary = secondary
    }

    var body: some View {
        HStack(spacing: 7.5) {
            Text(leading).foregroundStyle(AkiPalette.textPrimary)
            Spacer(minLength: 0)
            Text(trailing).foregroundStyle(secondary)
        }
        .font(CardType.body)
        .lineLimit(1)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(AkiPalette.ringTrack).frame(height: 0.94)
    }
}

/// Marks per day, oldest on the left, like Codenotch's 30-day token chart.
struct DailyBars: View {
    let values: [Int]

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1)
                    .fill(value > 0 ? AnyShapeStyle(AkiPalette.auroraLinear) : AnyShapeStyle(AkiPalette.ringTrack))
                    .frame(height: value > 0 ? max(3, 34 * CGFloat(value) / CGFloat(peak)) : 1.5)
            }
        }
        .frame(height: 34, alignment: .bottom)
    }
}

// MARK: Card chrome

/// Codenotch's speech-bubble tail: shoulders leave the card tangent to its edge,
/// so card and tail read as one moulded silhouette.
struct TooltipTail: Shape {
    let direction: TailDirection

    func path(in rect: CGRect) -> Path {
        let (tip, a, b, aShoulder, aTip, bTip, bShoulder):
            (CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint, CGPoint)
        switch direction {
        case .leading:  // card on the left, tip to the right
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.maxX - rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.25)
        case .trailing:  // card on the right, tip to the left
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25)
            aTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY - rect.height * 0.12)
            bTip = CGPoint(x: rect.minX + rect.width * 0.42, y: rect.midY + rect.height * 0.12)
            bShoulder = CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25)
        case .down:  // card below, tip upward
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY)
        case .up:  // card above, tip downward
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            aShoulder = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY)
            aTip = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bTip = CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY - rect.height * 0.42)
            bShoulder = CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY)
        }
        var path = Path()
        path.move(to: a)
        path.addCurve(to: tip, control1: aShoulder, control2: aTip)
        path.addCurve(to: b, control1: bTip, control2: bShoulder)
        path.closeSubpath()
        return path
    }

    static func size(for direction: TailDirection) -> CGSize {
        switch direction {
        case .leading, .trailing: CGSize(width: SidebarLayout.tailLength, height: SidebarLayout.tailWidth)
        case .up, .down: CGSize(width: SidebarLayout.tailWidth, height: SidebarLayout.tailLength)
        }
    }
}

/// Card and tail as one outline, so glass gets a single rim with no seam.
struct TooltipSilhouette: Shape {
    let direction: TailDirection

    func path(in rect: CGRect) -> Path {
        let tail = TooltipTail.size(for: direction)
        let card: CGRect
        let tailRect: CGRect
        switch direction {
        case .leading:
            card = CGRect(x: rect.minX, y: rect.minY, width: rect.width - tail.width, height: rect.height)
            tailRect = CGRect(x: card.maxX, y: rect.midY - tail.height / 2, width: tail.width, height: tail.height)
        case .trailing:
            tailRect = CGRect(x: rect.minX, y: rect.midY - tail.height / 2, width: tail.width, height: tail.height)
            card = CGRect(x: rect.minX + tail.width, y: rect.minY, width: rect.width - tail.width, height: rect.height)
        case .down:
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: rect.minY, width: tail.width, height: tail.height)
            card = CGRect(x: rect.minX, y: rect.minY + tail.height, width: rect.width, height: rect.height - tail.height)
        case .up:
            card = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail.height)
            tailRect = CGRect(x: rect.midX - tail.width / 2, y: card.maxY, width: tail.width, height: tail.height)
        }
        return RoundedRectangle(cornerRadius: SidebarLayout.cardRadius, style: .circular).path(in: card)
            .union(TooltipTail(direction: direction).path(in: tailRect))
    }
}

/// Fixed-width card with Codenotch's padding and corner, the tail welded on.
struct TooltipShell<Content: View>: View {
    let direction: TailDirection
    let surface: SurfaceStyle
    @ViewBuilder let content: Content

    var body: some View {
        let tail = TooltipTail.size(for: direction)
        stack(tail: tail)
            .background {
                let silhouette = TooltipSilhouette(direction: direction)
                switch surface {
                case .solid:
                    silhouette.fill(AkiPalette.card)
                case .glass, .darkGlass:
                    SurfaceFill(shape: silhouette, surface: surface)
                        .background(silhouette.fill(surface == .glass ? AkiPalette.glassDim : AkiPalette.darkGlassDim))
                }
            }
    }

    @ViewBuilder private func stack(tail: CGSize) -> some View {
        let card = content
            .padding(SidebarLayout.cardPadding)
            .frame(width: SidebarLayout.cardWidth, alignment: .topLeading)
        let spacer = Color.clear.frame(width: tail.width, height: tail.height)
        switch direction {
        case .leading: HStack(spacing: 0) { card; spacer }
        case .trailing: HStack(spacing: 0) { spacer; card }
        case .down: VStack(spacing: 0) { spacer; card }
        case .up: VStack(spacing: 0) { card; spacer }
        }
    }
}

/// A session's number on its ring and in the marking picker.
struct NumberBadge: View {
    let number: Int
    let size: CGFloat

    var body: some View {
        Text("\(number)")
            .font(.system(size: size * 0.66, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(AkiPalette.bg)
            .frame(minWidth: size, minHeight: size)
            .background(Circle().fill(AkiPalette.fg))
            .overlay(Circle().strokeBorder(AkiPalette.bg.opacity(0.5), lineWidth: 0.5))
    }
}

/// The end buttons of the 4-corner card: a small dark disc with its symbol,
/// lit in Aki's colours under the pointer.
struct CardOrb: View {
    let symbol: String
    let hovered: Bool
    let spins: Int
    /// On (Keep open): drawn in Aki's colours even at rest.
    var lit = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(AkiPalette.fg.opacity(hovered || lit ? 1 : 0.85))
            .rotationEffect(.degrees(Double(spins) * 90))
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: spins)
            .frame(width: 36, height: 36)
            // Under the pointer it fills with Aki's colours.
            .background(Circle().fill(hovered ? AnyShapeStyle(AkiPalette.auroraDiagonal) : AnyShapeStyle(AkiPalette.bg.opacity(0.92))))
            .overlay(Circle().strokeBorder(lit && !hovered ? AnyShapeStyle(AkiPalette.auroraAngular) : AnyShapeStyle(AkiPalette.fg.opacity(hovered ? 0.35 : 0.18)),
                                           lineWidth: lit && !hovered ? 2 : 1))
            .shadow(color: hovered ? AkiPalette.aurora[2].opacity(0.8) : .clear, radius: 9)
            .scaleEffect(hovered ? 1.18 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hovered)
    }
}

/// Keep open. Pinned: the pin stands up, filled, on Aki's red. Loose: it lies
/// tilted and hollow on the bar's colour. Under the pointer it previews the click
/// (a slashed pin to let go, a standing one to pin).
struct PinOrb: View {
    let pinned: Bool
    let hovered: Bool

    var body: some View {
        let symbol = hovered ? (pinned ? "pin.slash" : "pin.fill") : (pinned ? "pin.fill" : "pin")
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(pinned ? AkiPalette.paperFixed : AkiPalette.fg.opacity(hovered ? 1 : 0.7))
            .rotationEffect(.degrees(pinned || hovered ? 0 : 45))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 36, height: 36)
            .background(Circle().fill(pinned ? AnyShapeStyle(AkiPalette.red) : AnyShapeStyle(AkiPalette.bg.opacity(0.92))))
            .overlay(Circle().strokeBorder(pinned ? AnyShapeStyle(Color.clear)
                                           : AnyShapeStyle(AkiPalette.fg.opacity(hovered ? 0.5 : 0.22)),
                                           style: StrokeStyle(lineWidth: 1.2, dash: pinned ? [] : [3, 3])))
            .shadow(color: pinned ? AkiPalette.red.opacity(0.55) : .clear, radius: 8)
            .scaleEffect(hovered ? 1.15 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: pinned)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hovered)
    }
}

/// A quarter of a circle hugging one of the card's corners: the hint that a
/// button lives there.
struct CornerArc: View {
    let trimStart: CGFloat
    var radius: CGFloat = 9
    var width: CGFloat = 2.5
    var lit = false

    var body: some View {
        Circle()
            .trim(from: trimStart, to: trimStart + 0.25)
            .stroke(lit ? AnyShapeStyle(AkiPalette.auroraDiagonal) : AnyShapeStyle(AkiPalette.bg),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: 2 * radius, height: 2 * radius)
    }

    /// Which quarter faces the corner: away along the bar at its end, and away
    /// from (outer) or toward (inner) the screen edge. Trim 0 is three o'clock,
    /// running clockwise with y down.
    static func trim(edge: SidebarEdge, toward: CGVector, start: Bool, outer: Bool) -> CGFloat {
        let along = edge.isVertical ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0)
        let a: CGFloat = start ? -1 : 1, d: CGFloat = outer ? -1 : 1
        let dx = along.dx * a + toward.dx * d, dy = along.dy * a + toward.dy * d
        switch (dx > 0, dy > 0) {
        case (true, true): return 0
        case (false, true): return 0.25
        case (false, false): return 0.5
        case (true, false): return 0.75
        }
    }
}

/// Where a ring is on its way out of (or back into) the pill.
struct Emerge: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.scaleEffect(scale).offset(offset).opacity(opacity)
    }
}

/// One usage line in a session's card: name, a thin bar in Aki's colours, the
/// percentage and a note (model, when it renews).
struct UsageRow: View {
    let title: String
    let percent: Int
    let detail: String?
    let secondary: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(CardType.body).foregroundStyle(secondary).frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AkiPalette.fg.opacity(0.1))
                    Capsule().fill(percent >= 85 ? AnyShapeStyle(AkiPalette.aurora[0]) : AnyShapeStyle(AkiPalette.auroraDiagonal))
                        .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            }
            .frame(height: 4)
            Text("\(percent)%").font(CardType.bodyStrong).foregroundStyle(AkiPalette.textPrimary).monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            // Same width on every row, so the bars line up.
            Text(detail ?? "").font(CardType.body).foregroundStyle(secondary).lineLimit(1)
                .frame(width: 58, alignment: .leading)
        }
    }
}

/// A project's name over its rings: hover shows a pencil (it can be renamed),
/// double-click turns it into a field right there.
struct ProjectName: View {
    @Bindable var model: SidebarModel
    let key: String
    let label: String
    let scale: CGFloat
    /// No wider than this (the name gets "…"), so neighbours never overlap.
    var maxWidth: CGFloat = .infinity
    @FocusState private var focused: Bool

    private var hovered: Bool { model.hoveredProject == key }
    private var editing: Bool { model.editingProject == key }

    var body: some View {
        HStack(spacing: 4 * scale) {
            if editing {
                TextField("", text: $model.projectDraft)
                    .textFieldStyle(.plain)
                    // Bigger while you type, so the name is easy to read and edit.
                    .font(.system(size: 15 * scale, weight: .heavy))
                    .foregroundStyle(AkiPalette.fg)
                    .frame(width: max(110, CGFloat(model.projectDraft.count) * 11.5) * scale)
                    .focused($focused)
                    .onSubmit { model.commitProjectName() }
                    .onExitCommand { model.editingProject = nil }
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
            } else {
                Circle().fill(model.projectHue(key)).frame(width: 6 * scale, height: 6 * scale)
                Text(label)
                    .font(.system(size: 11 * scale, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(AkiPalette.fg.opacity(hovered ? 1 : 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if hovered {
                    Image(systemName: "pencil").font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(AkiPalette.fg.opacity(0.8))
                        .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .padding(.horizontal, (editing ? 12 : 8) * scale).frame(height: (editing ? 30 : 20) * scale)
        .frame(maxWidth: editing ? nil : max(maxWidth, 30 * scale))
        .background(Capsule().fill(AkiPalette.bg.opacity(0.9)))
        .overlay(Capsule().strokeBorder(editing || hovered ? AnyShapeStyle(AkiPalette.auroraDiagonal) : AnyShapeStyle(model.projectHue(key)),
                                        lineWidth: editing || hovered ? 1.2 : 1))
        .fixedSize(horizontal: editing || maxWidth == .infinity, vertical: true)
        .help(L10n.t("Click to rename"))
        .shadow(color: editing ? AkiPalette.aurora[2].opacity(0.5) : .clear, radius: 10)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: editing)
    }
}
