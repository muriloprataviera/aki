import AkiCore
import AppKit
import SwiftUI

/// A ring's motion (the arc turning while its agent works, the ring breathing while it
/// waits or listens), run by Core Animation in the window server: the sidebar isn't
/// redrawn for it (a SwiftUI animation redid the whole sidebar's layout at every frame,
/// all day, for each ring that moved).
struct RingMotion: NSViewRepresentable {
    enum Kind: Equatable {
        /// An arc of the ring, a full turn every `period` seconds.
        case turn(arc: CGFloat, period: Double, glow: CGFloat)
        /// The whole ring, its opacity going from `low` to `high` and back.
        case breathe(low: Float, high: Float, period: Double)
    }

    let kind: Kind
    let color: Color
    let lineWidth: CGFloat
    /// From the ring's edge to the middle of the stroke.
    let inset: CGFloat

    func makeNSView(context: Context) -> MotionView { MotionView() }

    func updateNSView(_ view: MotionView, context: Context) {
        view.set(kind: kind, color: NSColor(color).cgColor, lineWidth: lineWidth, inset: inset)
    }

    final class MotionView: NSView {
        private let shape = CAShapeLayer()
        private var current: (Kind, CGColor, CGFloat, CGFloat)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.isGeometryFlipped = true
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Clicks go to the ring under it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if let current { draw(current) }
        }

        func set(kind: Kind, color: CGColor, lineWidth: CGFloat, inset: CGFloat) {
            if let current, current.0 == kind, current.1 == color, current.2 == lineWidth, current.3 == inset { return }
            current = (kind, color, lineWidth, inset)
            draw(current!)
        }

        private func draw(_ state: (Kind, CGColor, CGFloat, CGFloat)) {
            let (kind, color, lineWidth, inset) = state
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            shape.strokeColor = color
            shape.lineWidth = lineWidth
            let radius = max(min(bounds.width, bounds.height) / 2 - inset, 1)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let path = CGMutablePath()
            shape.removeAllAnimations()
            switch kind {
            case let .turn(arc, period, glow):
                // From the top, like the ring's still arc (a quarter turn back from 3 o'clock).
                path.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + arc * 2 * .pi, clockwise: false)
                shape.shadowColor = color
                shape.shadowOpacity = glow > 0 ? 0.6 : 0
                shape.shadowRadius = glow
                shape.shadowOffset = .zero
                shape.opacity = 1
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                // (Clockwise on screen: negative in Core Animation's own sense.)
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = period
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                shape.add(spin, forKey: "turn")
            case let .breathe(low, high, period):
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                shape.shadowOpacity = 0
                shape.opacity = high
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = low
                fade.toValue = high
                fade.duration = period / 2
                fade.autoreverses = true
                fade.repeatCount = .infinity
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fade.isRemovedOnCompletion = false
                shape.add(fade, forKey: "breathe")
            }
            shape.path = path
            CATransaction.commit()
        }
    }
}

/// An agent's symbol turning (once every `period` seconds), drawn once and turned by
/// Core Animation, like `RingMotion`.
struct SpinningGlyph: NSViewRepresentable {
    let agent: AgentSession.Agent
    let size: CGFloat
    let color: Color
    var period: Double = 4

    func makeNSView(context: Context) -> GlyphView { GlyphView() }

    func updateNSView(_ view: GlyphView, context: Context) {
        let key = "\(agent.rawValue)|\(size)|\(color.description)|\(period)"
        guard view.key != key else { return }
        view.key = key
        let renderer = ImageRenderer(content: AgentGlyphView(agent: agent, size: size).foregroundStyle(color))
        renderer.scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        view.show(renderer.cgImage, size: size, period: period)
    }

    final class GlyphView: NSView {
        var key = ""
        private let glyph = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glyph.contentsGravity = .resizeAspect
            layer?.addSublayer(glyph)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        func show(_ image: CGImage?, size: CGFloat, period: Double) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.contents = image
            glyph.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
            glyph.removeAllAnimations()
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise on screen (this layer isn't flipped).
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = period
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            glyph.add(spin, forKey: "turn")
            CATransaction.commit()
        }
    }
}
