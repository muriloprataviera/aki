// From Codenotch's NotchRootView.swift (MIT, Copyright (c) 2026 Vinz,
// https://github.com/vinzdg/codenotch): only the flare walk the settings orb
// follows; the strand drawn between a dragged notch and the display's hole is
// not used by Aki.

import SwiftUI

enum GooNeck {
    /// The notch's flare as `SideNotchShape.fluidTurn` draws it, normalised to a
    /// unit quarter: `u` along the bezel, `v` across, and the heading there.
    static let flareWalk: [(u: CGFloat, v: CGFloat, heading: CGFloat)] = {
        let p: CGFloat = 0.5, steps = 96
        let bend = (CGFloat.pi / 2) / (1 - p)
        var heading: CGFloat = 0, u: CGFloat = 0, v: CGFloat = 0
        var walk: [(u: CGFloat, v: CGFloat, heading: CGFloat)] = [(0, 0, 0)]
        for i in 0..<steps {
            let s = (CGFloat(i) + 0.5) / CGFloat(steps)
            let share = s < p ? s / p : (s > 1 - p ? (1 - s) / p : 1)
            let before = heading
            heading += bend * share / CGFloat(steps)
            u += cos(heading) / CGFloat(steps)
            v += sin(heading) / CGFloat(steps)
            walk.append((u, v, (before + heading) / 2))
        }
        let end = walk[walk.count - 1]
        return walk.map { ($0.u / end.u, $0.v / end.v, $0.heading) }
    }()
}
