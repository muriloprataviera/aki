import AppKit
import Vision

/// The text on a frozen screen, read with the Vision framework (on this Mac, no
/// network). Lets you select lines inside things Accessibility sees as one block —
/// a terminal, a canvas, an image — and gives every mark the text it covers.
struct ScreenText {
    struct Line: Equatable {
        let text: String
        /// Points, top-left origin within the screen.
        let rect: CGRect
    }

    let lines: [Line]

    static func read(_ grab: ScreenGrab) async -> ScreenText {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["pt-BR", "en-US"]
            let handler = VNImageRequestHandler(cgImage: grab.image, options: [:])
            try? handler.perform([request])
            let size = grab.screen.frame.size
            let lines = (request.results ?? []).compactMap { observation -> Line? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                // Vision's boxes are normalised with the origin bottom-left.
                let box = observation.boundingBox
                let rect = CGRect(
                    x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                    width: box.width * size.width, height: box.height * size.height)
                return Line(text: candidate.string, rect: rect.insetBy(dx: -2, dy: -2))
            }
            return ScreenText(lines: lines)
        }.value
    }

    /// The line under a point.
    func line(at point: CGPoint) -> Line? {
        lines.first { $0.rect.contains(point) }
    }

    /// Lines a rect covers (their middle inside it), top to bottom.
    func lines(in rect: CGRect) -> [Line] {
        lines.filter { rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            .sorted { abs($0.rect.minY - $1.rect.minY) > 4 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
    }

    /// The text a rect covers, line by line.
    func text(in rect: CGRect) -> String {
        lines(in: rect).map(\.text).joined(separator: "\n")
    }
}
