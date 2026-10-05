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
        /// Its pieces split where the words are far apart ("Chats   Channels   Apps":
        /// tabs, a toolbar's labels), each a rect; one piece for ordinary text.
        var parts: [CGRect] = []
    }

    let lines: [Line]

    static func read(_ grab: ScreenGrab) async -> ScreenText {
        let image = grab.image, size = grab.screen.frame.size
        return await Task.detached(priority: .userInitiated) { read(image, size: size) }.value
    }

    /// The text in a picture shown at `size` points.
    static func read(_ image: CGImage, size: CGSize) -> ScreenText {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["pt-BR", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { observation -> Line? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                // Vision's boxes are normalised with the origin bottom-left.
                let box = observation.boundingBox
                let rect = CGRect(
                    x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                    width: box.width * size.width, height: box.height * size.height)
                return Line(text: candidate.string, rect: rect.insetBy(dx: -2, dy: -2),
                            parts: parts(of: candidate, lineHeight: rect.height, size: size))
            }
            return ScreenText(lines: lines)
    }

    /// A line's words grouped where they sit close; a gap wider than about one
    /// line's height starts a new piece.
    private static func parts(of candidate: VNRecognizedText, lineHeight: CGFloat, size: CGSize) -> [CGRect] {
        let string = candidate.string
        var words: [CGRect] = []
        var index = string.startIndex
        for word in string.split(separator: " ", omittingEmptySubsequences: true) {
            guard let range = string.range(of: word, range: index..<string.endIndex) else { continue }
            index = range.upperBound
            guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
            words.append(CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                width: box.width * size.width, height: box.height * size.height))
        }
        guard words.count > 1 else { return [] }
        var parts: [CGRect] = [words[0]]
        for word in words.dropFirst() {
            if word.minX - parts[parts.count - 1].maxX > lineHeight * 0.9 {
                parts.append(word)
            } else {
                parts[parts.count - 1] = parts[parts.count - 1].union(word)
            }
        }
        return parts.count > 1 ? parts.map { $0.insetBy(dx: -2, dy: -2) } : []
    }

    /// The line under a point.
    func line(at point: CGPoint) -> Line? {
        lines.first { $0.rect.contains(point) }
    }

    /// The row of a grid drawn as one picture (a spreadsheet's canvas) at a point: every
    /// piece of text level with it inside `bounds`, as one line across the whole width.
    func row(at point: CGPoint, within bounds: CGRect) -> Line? {
        let inside = lines.filter { bounds.intersects($0.rect) }
        guard let anchor = inside.filter({ $0.rect.minY - 2 <= point.y && point.y <= $0.rect.maxY + 2 })
            .min(by: { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) })
        else { return nil }
        // Cells of that row: their middle within the anchor's height (wrapped cells reach further).
        let band = anchor.rect.insetBy(dx: 0, dy: -max(anchor.rect.height * 0.35, 3))
        let cells = inside.filter { $0.rect.midY >= band.minY && $0.rect.midY <= band.maxY }
            .sorted { $0.rect.minX < $1.rect.minX }
        let top = cells.map(\.rect.minY).min() ?? anchor.rect.minY
        let bottom = cells.map(\.rect.maxY).max() ?? anchor.rect.maxY
        let rect = CGRect(x: bounds.minX, y: top - 2, width: bounds.width, height: bottom - top + 4)
        return Line(text: cells.map(\.text).joined(separator: " | "), rect: rect)
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
