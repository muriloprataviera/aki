// Adapted from Codenotch's SideNotchShape (MIT, Copyright (c) 2026 Vinz,
// https://github.com/vinzdg/codenotch), without the display-notch cutout and
// dip handling.

import SwiftUI

/// The sidebar's silhouette: rounded on the far side, flush with the screen edge,
/// and flaring into the edge at both ends so it reads as moulded into the bezel.
struct EdgeShape: Shape {
    var edge: SidebarEdge
    var cornerRadius: CGFloat
    /// How far the flare reaches along and across at each end.
    var curlRadius: CGFloat
    /// Share of each flare spent ramping its bend in and out (0 = plain arc).
    var filletRamp: CGFloat = 0.5
    /// Above zero: no flares, four round corners, lifted this far off the edge.
    var floating: CGFloat = 0

    /// Animating these (not just the rect) is what makes the fold look liquid:
    /// the corner opens and the flares grow from the border as it unfolds.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(cornerRadius, curlRadius), floating) }
        set {
            cornerRadius = newValue.first.first
            curlRadius = newValue.first.second
            floating = newValue.second
        }
    }

    /// Handle reach that makes a cubic Bézier trace a circle.
    static let circleReach: CGFloat = 0.5523

    func path(in rect: CGRect) -> Path {
        // Drawn for the right edge (depth across, length along, bezel at maxX)
        // and turned onto the real one.
        let depth = edge.isVertical ? rect.width : rect.height
        let length = edge.isVertical ? rect.height : rect.width
        let transform: CGAffineTransform
        switch edge {
        case .right: transform = .identity
        case .left: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0)
        case .top: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: depth)
        case .bottom: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
        return canonicalPath(in: CGRect(x: 0, y: 0, width: depth, height: length))
            .applying(transform)
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private func canonicalPath(in rect: CGRect) -> Path {
        if floating > 0.001 {
            // The card: the flares' room becomes margin at both ends, the edge side
            // steps back by `floating`, and every corner is round.
            let card = CGRect(x: rect.minX, y: rect.minY + curlRadius,
                              width: max(0, rect.width - floating), height: max(0, rect.height - 2 * curlRadius))
            let radius = min(cornerRadius, card.width / 2, card.height / 2)
            return Path(roundedRect: card, cornerRadius: radius, style: .continuous)
        }
        // The corner is claimed first, out of half the width, and the flare takes
        // what is left, so a narrow pill keeps round ends.
        let corner0 = max(0, min(cornerRadius, rect.width / 2))
        let curl = max(0, min(curlRadius, rect.width - corner0))
        let corner = max(0, min(corner0, (rect.height - 2 * curl) / 2))
        let top = rect.minY + curl
        let bottom = rect.maxY - curl
        let far = rect.minX

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if curl > 0.001 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX - curl, y: top),
                      leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: -1, dy: 0))
        }
        path.addLine(to: CGPoint(x: far + corner, y: top))
        turn(&path, to: CGPoint(x: far, y: top + corner),
             leaving: CGVector(dx: -1, dy: 0), arriving: CGVector(dx: 0, dy: 1))
        path.addLine(to: CGPoint(x: far, y: bottom - corner))
        turn(&path, to: CGPoint(x: far + corner, y: bottom),
             leaving: CGVector(dx: 0, dy: 1), arriving: CGVector(dx: 1, dy: 0))
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: bottom))
        if curl > 0.001 {
            fluidTurn(&path, to: CGPoint(x: rect.maxX, y: rect.maxY),
                      leaving: CGVector(dx: 1, dy: 0), arriving: CGVector(dx: 0, dy: 1))
        }
        path.closeSubpath()
        return path
    }

    /// A quarter turn whose bend ramps in from nothing at both ends, integrated
    /// from its curvature and walked out as a fine polyline, so the flare meets
    /// the border with no visible kink.
    private func fluidTurn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector) {
        guard let from = path.currentPoint else { return }
        let alongReach = (to.x - from.x) * leaving.dx + (to.y - from.y) * leaving.dy
        let acrossReach = (to.x - from.x) * arriving.dx + (to.y - from.y) * arriving.dy
        guard alongReach != 0, acrossReach != 0 else {
            path.addLine(to: to)
            return
        }
        let p = min(max(filletRamp, 0), 0.5)
        let bend = (CGFloat.pi / 2) / (1 - p)
        let steps = 96
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(CGFloat, CGFloat)] = [(0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = p <= 0 ? 1 : (s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1))
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v))
        }
        let (endU, endV) = walk[walk.count - 1]
        let alongScale = alongReach / endU, acrossScale = acrossReach / endV
        for (wu, wv) in walk.dropFirst() {
            path.addLine(to: CGPoint(
                x: from.x + leaving.dx * wu * alongScale + arriving.dx * wv * acrossScale,
                y: from.y + leaving.dy * wu * alongScale + arriving.dy * wv * acrossScale))
        }
    }

    /// A circular quarter turn from the current point to `to`.
    private func turn(_ path: inout Path, to: CGPoint, leaving: CGVector, arriving: CGVector) {
        guard let from = path.currentPoint else { return }
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let out = abs(delta.dx * leaving.dx + delta.dy * leaving.dy)
        let into = abs(delta.dx * arriving.dx + delta.dy * arriving.dy)
        guard out > 0, into > 0 else {
            path.addLine(to: to)
            return
        }
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + leaving.dx * out * Self.circleReach,
                              y: from.y + leaving.dy * out * Self.circleReach),
            control2: CGPoint(x: to.x - arriving.dx * into * Self.circleReach,
                              y: to.y - arriving.dy * into * Self.circleReach))
    }
}

/// Codenotch's motion vocabulary: springs just under bouncy, so the sidebar
/// settles like a body of liquid instead of snapping.
enum Motion {
    static let unfold = Animation.spring(response: 0.5, dampingFraction: 0.76)
    /// Closing: the rings go first, then the body draws in without a bounce.
    static let fold = Animation.spring(response: 0.36, dampingFraction: 0.92).delay(0.06)
    static let contents = Animation.spring(response: 0.48, dampingFraction: 0.8)
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.86)
    static let hover = Animation.spring(response: 0.18, dampingFraction: 0.85)
    static let crossfade = Animation.easeInOut(duration: 0.16)
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)

    /// Each cell trails the one above it, so the stack unfurls.
    static func stagger(_ index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    /// Rings come in from the middle outward, as the body opens around them.
    static func fromMiddle(_ index: Int, of count: Int) -> Animation {
        let distance = abs(Double(index) - Double(count - 1) / 2)
        // Same spring as the body, barely staggered, so they travel out with it.
        return .spring(response: 0.5, dampingFraction: 0.8).delay(min(distance * 0.015, 0.06))
    }
}
