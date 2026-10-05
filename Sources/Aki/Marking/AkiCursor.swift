import AppKit

/// The marking pointer: the site's pin — a red speech-bubble with a dark dot,
/// pointing with its tail (bottom left). Same shape as the `.pb` / `.pd` paths in
/// website (viewBox 16 14 52 53), drawn here so the app needs no file.
enum AkiCursor {
    /// ⇧ held while marking: clicks go to the app below, so the pointer is the plain
    /// arrow everywhere — over buttons and cards too — until ⇧ is let go.
    nonisolated(unsafe) static var passThrough = false

    /// Sets a cursor unless ⇧ holds the arrow.
    static func set(_ cursor: NSCursor) {
        (passThrough ? NSCursor.arrow : cursor).set()
    }

    static let pin: NSCursor = {
        let size: CGFloat = 28
        let scale = size / 53
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -16, y: -14)
            let center = CGPoint(x: 42, y: 40), r: CGFloat = 24
            let bubble = CGMutablePath()
            bubble.move(to: CGPoint(x: 42, y: 16))
            // Round from the top to where the tail leaves, the long way.
            bubble.addArc(center: center, radius: r, startAngle: -.pi / 2,
                          endAngle: atan2(60.2 - 40, 29 - 42), clockwise: false)
            bubble.addLine(to: CGPoint(x: 18, y: 65))  // the tip: where it points
            bubble.addLine(to: CGPoint(x: 22, y: 54.4))
            bubble.addArc(center: center, radius: r, startAngle: atan2(54.4 - 40, 22 - 42),
                          endAngle: 3 * .pi / 2, clockwise: false)
            bubble.closeSubpath()
            // A thin white edge so it shows on dark screens too.
            cg.addPath(bubble)
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(4)
            cg.setLineJoin(.round)
            cg.strokePath()
            cg.addPath(bubble)
            cg.setFillColor(NSColor(red: 1, green: 0.231, blue: 0.122, alpha: 1).cgColor)  // #FF3B1F
            cg.fillPath()
            cg.setFillColor(NSColor(white: 0.078, alpha: 1).cgColor)  // #141414
            cg.fillEllipse(in: CGRect(x: 34, y: 32, width: 16, height: 16))
            return true
        }
        // The tail's tip (18, 65) in the image's top-left coordinates.
        return NSCursor(image: image, hotSpot: NSPoint(x: (18 - 16) * scale, y: (65 - 14) * scale))
    }()
}
