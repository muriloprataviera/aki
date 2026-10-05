// Measurements from Codenotch's NotchLayout (MIT, Copyright (c) 2026 Vinz,
// https://github.com/vinzdg/codenotch), at its medium size; `scale` gives small
// (0.8) and large (1.25). The hover card is never scaled, as in Codenotch.

import CoreGraphics

/// Every position in the sidebar, in the panel's own flipped coordinates (origin
/// top-left). Worked out along the edge ("along") and inward from the screen
/// edge ("depth"), then mapped onto whichever edge it docks to. The view draws
/// from it and the controller hit-tests with it, so the two never disagree.
struct SidebarLayout: Equatable {
    // Body (medium)
    static let sideDepth: CGFloat = 70
    static let cornerRadius: CGFloat = 29.6
    static let curlRadius: CGFloat = 38.7
    static let padTop: CGFloat = 26.1
    static let padBottom: CGFloat = 18.8
    static let cellSpacing: CGFloat = 31.4
    static let ringMargin: CGFloat = 13
    // Folded pill
    static let pillDepth: CGFloat = 9.8
    static let pillLength: CGFloat = 79
    /// How far from the edge the pointer wakes the sidebar (not scaled).
    static let wakeDepth: CGFloat = 33.8
    // Ring cell
    static let ring: CGFloat = 44
    static let trackStroke: CGFloat = 5.8
    static let progressStroke: CGFloat = 3
    static let glyph: CGFloat = 17.3
    // Settings orb: centred on the end flare's centre. At rest a quarter arc
    // parallel to the flare, `orbGap` inside it; under the pointer a disc.
    static let orbDisc: CGFloat = 46.6
    static let orbStroke: CGFloat = 6.77
    static let orbGap: CGFloat = 10.15
    static let orbHotZone: CGFloat = 57
    // Hover card (fixed size)
    static let cardWidth: CGFloat = 225.6
    static let cardMaxHeight: CGFloat = 520
    static let cardRadius: CGFloat = 18.6
    static let cardPadding: CGFloat = 12
    static let tailLength: CGFloat = 28.2
    static let tailWidth: CGFloat = 32.7
    static let tailGap: CGFloat = 10.5
    /// The shape runs this far past the screen edge so no hairline shows.
    static let bleed: CGFloat = 2

    // Tiny name under a terminal's ring
    static let labelGap: CGFloat = 5
    static let labelHeight: CGFloat = 13
    static let labelFont: CGFloat = 10

    let count: Int
    let edge: SidebarEdge
    let scale: CGFloat
    /// Rings carry a name under them (terminal mode).
    let labeled: Bool

    init(count: Int, edge: SidebarEdge, scale: CGFloat, labeled: Bool = false) {
        self.count = max(count, 1)
        self.edge = edge
        self.scale = scale
        self.labeled = labeled
    }

    // MARK: Sizes along and across the edge

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    /// Ring, and the name under it when labeled.
    private var stack: CGFloat { s(Self.ring) + (labeled ? s(Self.labelGap + Self.labelHeight) : 0) }

    /// Down a side the stack runs along the edge; along the top or bottom the
    /// name moves into the depth, so the body gets deeper instead.
    var depth: CGFloat { 2 * s(Self.ringMargin) + (edge.isVertical ? s(Self.ring) : stack) }
    var cellAlong: CGFloat { edge.isVertical ? stack : s(Self.ring) }
    var curl: CGFloat { s(Self.curlRadius) }
    var corner: CGFloat { s(Self.cornerRadius) }
    var spacing: CGFloat { s(Self.cellSpacing) }
    private var padStart: CGFloat { edge.isVertical ? s(Self.padTop) : s(Self.padTop + Self.padBottom) / 2 }
    private var padEnd: CGFloat { edge.isVertical ? s(Self.padBottom) : s(Self.padTop + Self.padBottom) / 2 }
    var orbDisc: CGFloat { s(Self.orbDisc) }
    var orbStroke: CGFloat { s(Self.orbStroke) }
    var orbArcRadius: CGFloat { curl - s(Self.orbGap) }

    /// From one ring's centre to the next.
    var step: CGFloat { cellAlong + spacing }

    /// Past five rings, everything shrinks a little per ring so the bar doesn't
    /// run off: 6 rings at 0.86, 8 at 0.75, 10 and more at 0.66.
    static func density(rings: Int) -> CGFloat {
        rings <= 5 ? 1 : max(0.66, 5.0 / CGFloat(rings) * 1.04)
    }

    var bodyLength: CGFloat {
        2 * curl + padStart + CGFloat(count) * cellAlong + CGFloat(count - 1) * spacing + padEnd
    }

    /// The card's extent along the edge and away from it, tail included.
    private var cardAlong: CGFloat { edge.isVertical ? Self.cardMaxHeight : Self.cardWidth }
    private var cardDepth: CGFloat {
        (edge.isVertical ? Self.cardWidth : Self.cardMaxHeight) + Self.tailLength
    }

    /// From the settings disc's centre to the grip's centre (Codenotch's gripReach).
    var gripReach: CGFloat { s(NotchLayout.orbDiameter / 2 + NotchLayout.gripGap + NotchLayout.gripWidth / 2) }
    private var endReach: CGFloat { gripReach + s(NotchLayout.gripHotZone) / 2 }
    private var totalAlong: CGFloat { bodyLength + 2 * endReach + cardAlong }
    private var totalDepth: CGFloat { Self.bleed + depth + Self.tailGap + cardDepth }

    /// Fixed for a given number of cells, size and edge: never changes on hover.
    var panelSize: CGSize {
        edge.isVertical
            ? CGSize(width: totalDepth, height: totalAlong)
            : CGSize(width: totalAlong, height: totalDepth)
    }

    private var bodyStart: CGFloat { (totalAlong - bodyLength) / 2 }

    // MARK: Mapping onto the edge

    /// A box given along the edge and inward from the screen edge (depth 0 is
    /// the panel's outer side, `bleed` past the screen).
    private func rect(along a0: CGFloat, _ a1: CGFloat, depth d0: CGFloat, _ d1: CGFloat) -> CGRect {
        let size = panelSize
        switch edge {
        case .right: return CGRect(x: size.width - d1, y: a0, width: d1 - d0, height: a1 - a0)
        case .left: return CGRect(x: d0, y: a0, width: d1 - d0, height: a1 - a0)
        case .bottom: return CGRect(x: a0, y: size.height - d1, width: a1 - a0, height: d1 - d0)
        case .top: return CGRect(x: a0, y: d0, width: a1 - a0, height: d1 - d0)
        }
    }

    private func point(along a: CGFloat, depth d: CGFloat) -> CGPoint {
        let r = rect(along: a, a, depth: d, d)
        return CGPoint(x: r.minX, y: r.minY)
    }

    // MARK: Parts

    func bodyRect(expanded: Bool) -> CGRect {
        if expanded {
            return rect(along: bodyStart, bodyStart + bodyLength, depth: 0, Self.bleed + depth)
        }
        let center = bodyStart + bodyLength / 2
        let half = s(Self.pillLength) / 2
        return rect(along: center - half, center + half, depth: 0, Self.bleed + s(Self.pillDepth))
    }

    /// Where the folded pill listens for the pointer: deeper and longer than the pill.
    var wakeRect: CGRect {
        let center = bodyStart + bodyLength / 2
        let half = s(Self.pillLength) / 2 + 8
        return rect(along: center - half, center + half, depth: 0, Self.bleed + Self.wakeDepth)
    }

    private func cellCenterAlong(_ index: Int) -> CGFloat {
        bodyStart + curl + padStart + CGFloat(index) * (cellAlong + spacing) + cellAlong / 2
    }

    /// Center of a cell's ring + label stack.
    /// A point between cells / over a group, `out` past the body's far side.
    func alongPoint(_ along: CGFloat, out: CGFloat) -> CGPoint {
        point(along: along, depth: Self.bleed + depth + out)
    }

    func cellAlongCenter(_ index: Int) -> CGFloat { cellCenterAlong(index) }

    /// A point inside the body at a position along it, at the rings' middle.
    func midPoint(_ along: CGFloat) -> CGPoint {
        point(along: along, depth: Self.bleed + depth / 2)
    }

    func cellCenter(_ index: Int) -> CGPoint {
        point(along: cellCenterAlong(index), depth: Self.bleed + depth / 2)
    }

    /// The area a cell owns while hovering: its stack and half the gap around it.
    func cellRect(_ index: Int) -> CGRect {
        let center = cellCenterAlong(index)
        let half = (cellAlong + spacing) / 2
        return rect(along: center - half, center + half, depth: 0, Self.bleed + depth)
    }

    func cellIndex(at point: CGPoint) -> Int? {
        (0..<count).first { cellRect($0).contains(point) }
    }

    /// The centre the far end's flare curves around: the orb's arc runs parallel
    /// to that curve, which is what makes it read as part of the body.
    var orbCenter: CGPoint {
        card ? corner(start: false, outer: false)
            : point(along: bodyStart + bodyLength, depth: Self.bleed + curl)
    }

    var orbRect: CGRect {
        if card { return cornerRect(orbCenter) }
        let c = orbCenter
        let half = s(Self.orbHotZone) / 2
        return CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half)
    }

    /// The "mark the screen" shortcut: the settings orb mirrored onto the start of
    /// the body, centred on that end's flare.
    var markOrbCenter: CGPoint {
        card ? corner(start: true, outer: true) : point(along: bodyStart, depth: Self.bleed + curl)
    }

    /// The card's four corners each hold a button: the start end has Mark (away
    /// from the edge) and History (by it); the far end Keep open (away from the
    /// edge) and Settings (by it).
    /// The two buttons of an end stand one above the other, on one line just
    /// past the card's end, centred a touch above its middle — the lower one
    /// kept clear of the screen edge.
    private func corner(start: Bool, outer: Bool) -> CGPoint {
        let a0 = bodyStart + curl, a1 = bodyStart + bodyLength - curl
        // Out past the corner arcs (left end to the left, right end to the right).
        let along = start ? a0 - s(32) : a1 + s(32)
        let lift = s(4), gap = s(22)
        let lowest = Self.bleed + s(19)
        let inner = max(cardMiddle + lift - gap, lowest)
        return point(along: along, depth: outer ? inner + 2 * gap : inner)
    }

    /// One end of the card (the room its two corner buttons live in), a little
    /// past it so the pointer finds it coming from outside.
    func endZone(start: Bool) -> CGRect {
        let a0 = start ? bodyStart - s(34) : bodyStart + bodyLength - curl
        let a1 = start ? bodyStart + curl : bodyStart + bodyLength + s(34)
        return rect(along: a0, a1, depth: 0, Self.bleed + depth + s(6))
    }

    /// The 4-corner card's own corners: the centre of each rounded corner and
    /// its radius, for the arcs that hug them.
    func cardCorner(start: Bool, outer: Bool) -> (center: CGPoint, radius: CGFloat) {
        let a0 = bodyStart + curl, a1 = bodyStart + bodyLength - curl
        let d0 = s(6), d1 = Self.bleed + depth
        let r = min(corner, (d1 - d0) / 2, (a1 - a0) / 2)
        return (point(along: start ? a0 + r : a1 - r, depth: outer ? d1 - r : d0 + r), r)
    }

    var historyOrbCenter: CGPoint { corner(start: true, outer: false) }
    var hideOrbCenter: CGPoint { corner(start: false, outer: true) }
    var historyOrbRect: CGRect { cornerRect(historyOrbCenter) }
    var hideOrbRect: CGRect { cornerRect(hideOrbCenter) }

    func cornerRect(_ c: CGPoint) -> CGRect {
        let half = s(20)
        return CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half)
    }

    /// The 4-corner card (no flares): the end buttons sit in the room the
    /// flares had, level with the card's middle.
    var card: Bool { MainActor.assumeIsolated { Preferences.shared.barShape == .card } }
    private var cardMiddle: CGFloat { Self.bleed + depth / 2 + s(3) }

    var markOrbRect: CGRect {
        if card { return cornerRect(markOrbCenter) }
        let c = markOrbCenter
        let half = s(Self.orbHotZone) / 2
        return CGRect(x: c.x - half, y: c.y - half, width: 2 * half, height: 2 * half)
    }

    /// The drag handle: a row of dots inside the body, along its far side (the top
    /// of a bottom bar), where no card can cover it.
    var gripCenter: CGPoint {
        point(along: bodyStart + bodyLength / 2, depth: Self.bleed + depth - s(Self.ringMargin) * 0.45)
    }

    /// "Update to 0.2.1": just outside the bar, over its far end (away from the edge).
    /// With the bar folded, just over the small pill in the middle.
    func updatePillCenter(expanded: Bool) -> CGPoint {
        expanded
            ? point(along: bodyStart + bodyLength - curl - s(48), depth: Self.bleed + depth + s(18))
            : point(along: bodyStart + bodyLength / 2, depth: Self.bleed + s(Self.pillDepth) + s(20))
    }

    /// The resize handle, like a window's: in the body's far-end corner away from
    /// the edge (the top right of a bottom bar).
    var resizeCenter: CGPoint {
        let (c, r) = cardCorner(start: false, outer: true)
        let k = r + s(6)
        return CGPoint(x: c.x + resizeDirection.dx * k, y: c.y + resizeDirection.dy * k)
    }

    var resizeRect: CGRect {
        let c = resizeCenter
        // Easy to catch at any size: never under 30 pt.
        let half = max(s(15), 15)
        return CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2)
    }

    /// Out of that corner (forward along the body and away from the edge): a
    /// drag this way grows the sidebar. Panel coordinates, y down.
    var resizeDirection: CGVector {
        let x = -backAlong.dx - towardEdge.dx, y = -backAlong.dy - towardEdge.dy
        return CGVector(dx: x / 2.squareRoot(), dy: y / 2.squareRoot())
    }

    var gripRect: CGRect {
        // Mostly above the bar, where the handle rises to, so it doesn't eat the
        // top of the rings below it.
        let base = gripCenter
        let c = CGPoint(x: base.x - towardEdge.dx * s(9), y: base.y - towardEdge.dy * s(9))
        let long: CGFloat = max(s(90), bodyLength * 0.35), short: CGFloat = s(34)
        return edge.isVertical
            ? CGRect(x: c.x - short / 2, y: c.y - long / 2, width: short, height: long)
            : CGRect(x: c.x - long / 2, y: c.y - short / 2, width: long, height: short)
    }

    var notchEdge: NotchEdge {
        switch edge {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// Unit vectors, in panel coordinates, pointing back along the body (toward
    /// its start) and out toward the screen edge.
    var backAlong: CGVector { edge.isVertical ? CGVector(dx: 0, dy: -1) : CGVector(dx: -1, dy: 0) }
    var towardEdge: CGVector {
        switch edge {
        case .right: CGVector(dx: 1, dy: 0)
        case .left: CGVector(dx: -1, dy: 0)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .top: CGVector(dx: 0, dy: -1)
        }
    }

    /// The space the card (with its tail) may use beside a cell. The card itself is
    /// smaller; it hugs the body side of this box and centres on the cell.
    func cardSlot(_ index: Int) -> CGRect {
        let center = min(max(cellCenterAlong(index), cardAlong / 2), totalAlong - cardAlong / 2)
        let start = Self.bleed + depth + Self.tailGap
        return rect(along: center - cardAlong / 2, center + cardAlong / 2, depth: start, start + cardDepth)
    }

    /// The card's real frame once its size is known (`size` includes the tail),
    /// plus the gap to the body so the pointer can cross over.
    func cardRect(_ index: Int, size: CGSize) -> CGRect {
        let slot = cardSlot(index)
        let reach = Self.tailGap + 4
        switch edge {
        case .right:
            return CGRect(x: slot.maxX - size.width, y: slot.midY - size.height / 2, width: size.width + reach, height: size.height)
        case .left:
            return CGRect(x: slot.minX - reach, y: slot.midY - size.height / 2, width: size.width + reach, height: size.height)
        case .bottom:
            return CGRect(x: slot.midX - size.width / 2, y: slot.maxY - size.height, width: size.width, height: size.height + reach)
        case .top:
            return CGRect(x: slot.midX - size.width / 2, y: slot.minY - reach, width: size.width, height: size.height + reach)
        }
    }

    /// Which way the card sits from the body; its tail points back at the cell.
    var tailDirection: TailDirection {
        switch edge {
        case .right: .leading
        case .left: .trailing
        case .bottom: .up
        case .top: .down
        }
    }
}

/// Where the card sits relative to the body: the tail points the other way.
enum TailDirection: Equatable {
    case leading, trailing, up, down
}
