import AppKit

/// For apps that don't say what's in their window (Telegram, games, some design and
/// cross-platform apps answer "a window" and nothing more): the boxes are found in
/// the picture itself. From the pointer, a rectangle grows while the background
/// stays the same colour, and stops at borders, separators and other backgrounds —
/// the row, button or card you're on, then (↑) what holds it. Local, ~5 ms.
enum VisualProbe {
    /// One picture's pixels at one pixel per point, kept while it's on screen.
    final class Pixels: @unchecked Sendable {
        let width: Int
        let height: Int
        fileprivate let data: [UInt8]

        init?(_ image: CGImage, size: CGSize) {
            let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
            self.width = width
            self.height = height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.data = data
        }

        /// Top-left origin, like the screen's points (a bitmap's first row is its top).
        fileprivate func color(_ x: Int, _ y: Int) -> RGB {
            let i = (y * width + x) * 4
            return RGB(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
        }
    }

    fileprivate struct RGB: Hashable {
        let r: Int, g: Int, b: Int
        func near(_ o: RGB, _ tolerance: Int = 9) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
        }
        var bucket: RGB { RGB(r: r / 6, g: g / 6, b: b / 6) }
    }

    /// One per screen picture (a few at most: one per display).
    nonisolated(unsafe) private static var cached: [(image: CGImage, pixels: Pixels)] = []
    private static let lock = NSLock()

    static func pixels(of image: CGImage, size: CGSize) -> Pixels? {
        if let hit = lock.withLock({ cached.first { $0.image === image } }) { return hit.pixels }
        guard let pixels = Pixels(image, size: size) else { return nil }
        lock.withLock {
            cached.append((image, pixels))
            if cached.count > 4 { cached.removeFirst() }
        }
        return pixels
    }

    /// What to point at when the usual lookup said too little (`found`): the boxes
    /// seen in the picture, smallest first, then — on a canvas — the row, then what
    /// was found. Global points, top-left origin, like `found`. `origin` is where
    /// the screen's top-left sits in those points.
    static func element(at point: CGPoint, found: ProbedElement?, image: CGImage, screenSize: CGSize, origin: CGPoint,
                        text: ScreenText?) -> ProbedElement? {
        guard let pixels = pixels(of: image, size: screenSize) else { return found }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let screenRect = CGRect(origin: .zero, size: screenSize)
        // Inside what was found (the window, the canvas), else the whole screen.
        let bounds = found.map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y).intersection(screenRect) } ?? screenRect
        let boxes = boxes(at: local, in: pixels, within: bounds, lines: text?.lines ?? [])
        guard !boxes.isEmpty else { return found }
        var frames = boxes
        // A spreadsheet: after the cell, its whole row.
        if found?.label.lowercased().hasPrefix("canvas") == true, let row = text?.row(at: local, within: bounds),
           let last = frames.last, row.rect.width > last.width {
            frames.append(row.rect)
        }
        let elements = frames.map { rect -> ProbedElement in
            let words = text?.text(in: rect).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
            let label = words.isEmpty ? L10n.t("area") : "“\(words.count > 32 ? String(words.prefix(32)) + "…" : words)”"
            var element = ProbedElement(frame: rect.offsetBy(dx: origin.x, dy: origin.y), label: label)
            element.appName = found?.appName
            return element
        }
        var first = elements[0]
        first.ancestors = Array(elements.dropFirst()) + (found.map { [$0] } ?? []) + (found?.ancestors ?? [])
        return first
    }

    /// The boxes around a point (screen points, top-left origin), smallest first,
    /// each one holding the one before; all inside `bounds` (the app's window).
    /// `lines` (text read off the screen) keep a box from cutting through words.
    static func boxes(at point: CGPoint, in pixels: Pixels, within bounds: CGRect, lines: [ScreenText.Line] = []) -> [CGRect] {
        let limit = bounds.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard limit.width > 4, limit.height > 4, limit.contains(point) else { return [] }
        var levels: [CGRect] = []
        var start = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        if let line = lines.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            // On words: the piece of the line under the pointer (one tab of a row of
            // tabs), or the whole line. Its own level when it sits on a wider background.
            // (The box itself grows from the pointer: words read off the screen may run
            // across a border, two cells read as one line.)
            let piece = line.parts.first { $0.insetBy(dx: -4, dy: -2).contains(point) } ?? line.rect
            levels.append(piece.insetBy(dx: -4, dy: -3).intersection(limit))
        } else if let icon = ink(near: point, in: pixels, limit: limit) {
            // On a drawing with no words (an icon on a bar): the drawing, with room around it.
            start = icon
            levels.append(icon.insetBy(dx: -5, dy: -5).intersection(limit))
        }
        start = start.intersection(limit)
        var current = grow(start, in: pixels, limit: limit, lines: lines)
        // A speck (an icon's stroke, a letter): straight on to what holds it.
        while current.width < 20 || current.height < 16 {
            let next = grow(current, in: pixels, limit: limit, lines: lines)
            if next == current { break }
            current = next
        }
        // The words or the icon get their own level only when what holds them is much
        // bigger (a tab in a row of tabs, an icon on a bar); a message bubble or a
        // button around its label is the thing itself.
        // Still a speck: a picture (a photo in a message, a thumbnail) has no one colour
        // to grow on. Grow the other way: until its edges meet what's around it.
        if current.width < 40 || current.height < 30, levels.isEmpty,
           let picture = picture(at: point, in: pixels, limit: limit) {
            current = picture
        }
        if let first = levels.first {
            let piece = first.intersection(current)
            levels = current.width * current.height < piece.width * piece.height * 6 || piece.isEmpty ? [] : [piece]
        }
        levels.append(current)
        for _ in 0..<4 {
            let next = grow(current, in: pixels, limit: limit, lines: lines)
            if next.width <= current.width + 3 && next.height <= current.height + 3 { break }
            // Nearly the whole window: that's the window, not a box in it.
            if next.width * next.height > limit.width * limit.height * 0.85 { break }
            levels.append(next)
            current = next
        }
        return levels
    }

    /// The drawing under (or right next to) the pointer when it isn't text: the pixels
    /// unlike the background around them, joined across gaps of a few points. Nil when
    /// there's nothing there or it's too big to be one icon.
    private static func ink(near point: CGPoint, in pixels: Pixels, limit: CGRect) -> CGRect? {
        let px = Int(point.x), py = Int(point.y)
        let minX = Int(limit.minX), maxX = Int(limit.maxX) - 1, minY = Int(limit.minY), maxY = Int(limit.maxY) - 1
        let reach = 18
        var counts: [RGB: (count: Int, color: RGB)] = [:]
        for y in max(py - reach, minY)...min(py + reach, maxY) {
            for x in max(px - reach, minX)...min(px + reach, maxX) {
                let c = pixels.color(x, y)
                counts[c.bucket, default: (0, c)].count += 1
            }
        }
        guard let background = counts.values.max(by: { $0.count < $1.count })?.color else { return nil }
        func inked(_ x: Int, _ y: Int) -> Bool { !pixels.color(x, y).near(background, 24) }
        // The nearest inked pixel within a few points.
        var seed: (Int, Int)?
        search: for radius in 0...6 {
            for dy in -radius...radius {
                for dx in -radius...radius where max(abs(dx), abs(dy)) == radius {
                    let x = px + dx, y = py + dy
                    if x >= minX, x <= maxX, y >= minY, y <= maxY, inked(x, y) { seed = (x, y); break search }
                }
            }
        }
        guard let seed else { return nil }
        // Flood over inked pixels, stepping across gaps of up to 3 points.
        var seen = Set<Int>()
        var queue = [seed]
        var l = seed.0, r = seed.0, t = seed.1, b = seed.1
        let gap = 3
        while let (x, y) = queue.popLast() {
            let key = y * pixels.width + x
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y)
            if r - l > 64 || b - t > 64 || seen.count > 6000 { return nil }  // not an icon
            for dy in -gap...gap {
                for dx in -gap...gap where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= minX, nx <= maxX, ny >= minY, ny <= maxY, !seen.contains(ny * pixels.width + nx),
                          inked(nx, ny) else { continue }
                    queue.append((nx, ny))
                }
            }
        }
        guard r - l >= 6, b - t >= 6 else { return nil }
        return CGRect(x: l, y: t, width: r - l + 1, height: b - t + 1)
    }

    /// A picture around a point: the colour around it (well outside) is found first,
    /// then a box grows from the point while its edges are mostly *not* that colour.
    private static func picture(at point: CGPoint, in pixels: Pixels, limit: CGRect) -> CGRect? {
        let minX = Int(limit.minX), maxX = Int(limit.maxX) - 1, minY = Int(limit.minY), maxY = Int(limit.maxY) - 1
        var l = max(Int(point.x) - 2, minX), r = min(Int(point.x) + 2, maxX)
        var t = max(Int(point.y) - 2, minY), b = min(Int(point.y) + 2, maxY)
        func surrounding() -> RGB? {
            var counts: [RGB: (count: Int, color: RGB)] = [:]
            let reach = 260, step = 4
            for y in stride(from: max(t - reach, minY), through: min(b + reach, maxY), by: step) {
                for x in stride(from: max(l - reach, minX), through: min(r + reach, maxX), by: step) {
                    let c = pixels.color(x, y)
                    counts[c.bucket, default: (0, c)].count += 1
                }
            }
            return counts.values.max(by: { $0.count < $1.count })?.color
        }
        guard let outside = surrounding() else { return nil }
        // The pointer is on the background itself: no picture here.
        if pixels.color(Int(point.x), Int(point.y)).near(outside, 8) { return nil }
        func inside(_ points: [(Int, Int)]) -> Bool {
            let matching = points.filter { pixels.color($0.0, $0.1).near(outside, 8) }.count
            return Double(matching) / Double(max(points.count, 1)) < 0.6
        }
        var grew = true
        while grew {
            grew = false
            if l > minX, inside((t...b).map { (l - 1, $0) }) { l -= 1; grew = true }
            if r < maxX, inside((t...b).map { (r + 1, $0) }) { r += 1; grew = true }
            if t > minY, inside((l...r).map { ($0, t - 1) }) { t -= 1; grew = true }
            if b < maxY, inside((l...r).map { ($0, b + 1) }) { b += 1; grew = true }
            if (r - l) * (b - t) > Int(limit.width * limit.height * 0.6) { return nil }  // ran over the window
        }
        guard r - l >= 24, b - t >= 24 else { return nil }
        return CGRect(x: l, y: t, width: r - l + 1, height: b - t + 1)
    }

    /// Grows `box` while its edges run over the background around it. The edges are
    /// checked with running sums (one step each), so a box the size of a window is
    /// as quick as a button.
    private static func grow(_ box: CGRect, in pixels: Pixels, limit: CGRect, lines: [ScreenText.Line]) -> CGRect {
        let minX = Int(limit.minX), maxX = Int(limit.maxX) - 1, minY = Int(limit.minY), maxY = Int(limit.maxY) - 1
        var l = max(Int(box.minX), minX), r = min(Int(box.maxX), maxX)
        var t = max(Int(box.minY), minY), b = min(Int(box.maxY), maxY)
        guard l < r, t < b else { return box }
        // The background: the commonest colour in a ring just outside the box.
        var counts: [RGB: (count: Int, color: RGB)] = [:]
        let ring = 4
        for y in max(t - ring, minY)...min(b + ring, maxY) {
            for x in max(l - ring, minX)...min(r + ring, maxX) where !(x >= l && x <= r && y >= t && y <= b) {
                let c = pixels.color(x, y)
                counts[c.bucket, default: (0, c)].count += 1
            }
        }
        guard let background = counts.values.max(by: { $0.count < $1.count })?.color else { return box }

        // Which pixels of the window are that background, summed along rows and columns.
        let w = maxX - minX + 1, h = maxY - minY + 1
        var rows = [Int32](repeating: 0, count: (w + 1) * h)   // rows[y][x+1] = matches in row y up to x
        var cols = [Int32](repeating: 0, count: w * (h + 1))   // cols[x][y+1] = matches in column x up to y
        for y in 0..<h {
            var run: Int32 = 0
            for x in 0..<w {
                let hit: Int32 = pixels.color(x + minX, y + minY).near(background, 5) ? 1 : 0
                run += hit
                rows[y * (w + 1) + x + 1] = run
                cols[x * (h + 1) + y + 1] = cols[x * (h + 1) + y] + hit
            }
        }
        func rowShare(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
            let base = (y - minY) * (w + 1)
            return Double(rows[base + x1 - minX + 1] - rows[base + x0 - minX]) / Double(x1 - x0 + 1)
        }
        func colShare(_ x: Int, _ y0: Int, _ y1: Int) -> Double {
            let base = (x - minX) * (h + 1)
            return Double(cols[base + y1 - minY + 1] - cols[base + y0 - minY]) / Double(y1 - y0 + 1)
        }
        // Words cover well under two thirds of a line through them; a border or a
        // separator covers all of it. So a third of background is enough to go on.
        let need = 0.3
        var grew = true
        while grew {
            grew = false
            if l > minX, colShare(l - 1, t, b) >= need { l -= 1; grew = true }
            if r < maxX, colShare(r + 1, t, b) >= need { r += 1; grew = true }
            if t > minY, rowShare(t - 1, l, r) >= need { t -= 1; grew = true }
            if b < maxY, rowShare(b + 1, l, r) >= need { b += 1; grew = true }
        }
        var found = CGRect(x: l, y: t, width: r - l + 1, height: b - t + 1)
        // Never through the middle of a line of text: take it whole.
        for line in lines where found.intersects(line.rect) && !found.contains(line.rect) {
            let overlap = found.intersection(line.rect)
            if overlap.width * overlap.height > line.rect.width * line.rect.height * 0.6 {
                found = found.union(line.rect).intersection(limit)
            }
        }
        return found
    }

    /// Whether an element found the usual way says too little to point at: no
    /// element, the window itself, or a box covering most of the window.
    static func tooVague(_ element: ProbedElement?, screen: CGRect) -> Bool {
        guard let element else { return true }
        if element.fromBrowser {
            // Pages answer precisely, except what they draw as one picture (a spreadsheet).
            return element.label.lowercased().hasPrefix("canvas")
        }
        let role = element.role ?? ""
        if role == "AXWindow" || role == "AXApplication" { return true }
        let area = element.frame.width * element.frame.height
        return area > screen.width * screen.height * 0.25
            && ["AXGroup", "AXScrollArea", "AXUnknown", "AXLayoutArea", "AXSplitGroup", "AXWebArea", ""].contains(role)
    }
}
