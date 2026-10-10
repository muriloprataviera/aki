import AkiCore
import AppKit
import Observation
import SwiftUI

/// One mark on the frozen screen: a point or an area, its comment, and the
/// conversation it goes to (so one batch can go to several, each in its colour).
struct Mark: Identifiable, Equatable {
    let id = UUID()
    var screen: Int
    /// Points, top-left origin within its screen. A point mark has zero size.
    var rect: CGRect
    var comment = ""
    var destination: String?
    var number: Int
    /// The UI element it was made on (clicked while outlined), if any.
    var element: ProbedElement?
    /// Where the pointer was when the mark was made: the comment opens there.
    var anchor: CGPoint = .zero
    /// Text chosen with ⌥ (whole lines read off the screen).
    var text: String?
    /// What goes to the agent: the text it covers by default; the crop only
    /// when you tick it (pictures fill the disk and the agent's context).
    var sendsImage = false
    var sendsText = true
    /// You turned the crop on or off yourself: Aki stops guessing for this mark.
    var imageChosen = false
    /// The screen picture it was made on (the page may scroll afterwards).
    var grab: ScreenGrab?
    /// The app / page it was made on (a queued mark may come from an earlier round).
    var context: MarkContext?
    /// Which picture of its screen that was: drawn only while it's still showing.
    var generation = 0

    static func == (a: Mark, b: Mark) -> Bool {
        a.id == b.id && a.screen == b.screen && a.rect == b.rect && a.comment == b.comment
            && a.destination == b.destination && a.number == b.number && a.element == b.element
            && a.anchor == b.anchor && a.text == b.text && a.sendsImage == b.sendsImage
            && a.sendsText == b.sendsText && a.generation == b.generation
    }

    var isPoint: Bool { rect.width < 1 && rect.height < 1 }
}

/// Everything about one round of marking, from ⇧⌘A to Enter.
@MainActor @Observable
final class MarkingSession {
    /// The frozen screens. Replaced after you scroll the page below.
    var grabs: [ScreenGrab]
    /// Bumped each time a screen is captured again.
    var generation: [Int: Int] = [:]
    /// The page below is scrolling: the frozen picture steps aside.
    var scrolling = false
    /// The screen keeps running under the overlay (each mark takes its own picture).
    var live = true
    /// The app being marked: the one in front (it follows ⌘Tab while marking).
    var context: MarkContext
    /// Conversations you can send to, in sidebar order.
    var terminals: [AgentTerminal]
    /// Each session's colour, as on its ring.
    var hues: [String: Color] = [:]
    /// Each session's project (folder), to offer the destination's siblings first.
    var projects: [String: String] = [:]

    var marks: [Mark] = []
    var editing: UUID? {
        didSet { if let oldValue, editing == nil { lastEdited = oldValue } }
    }
    /// The mark whose card closed last: the queue stays beside where that card was.
    var lastEdited: UUID?
    var draft = ""
    var destination: String?
    /// Set when sending: marks fly to the ring of their conversation.
    var flying = false
    /// Saving is under way (a second ⌘⏎ meanwhile does nothing).
    var sending = false
    /// Live-screen pictures of new marks still being taken.
    var capturing = 0
    /// The element under the pointer (global rect), outlined like Vibe Annotations.
    var hovered: ProbedElement? {
        didSet { if hovered?.frame != oldValue?.frame || hovered?.label != oldValue?.label { level = 0 } }
    }
    /// The text on each screen (read in the background when marking starts).
    var texts: [Int: ScreenText] = [:]
    /// ⌥ is held: hover and clicks pick lines of text instead of UI elements.
    var optionHeld = false
    /// ⇧ held: a click goes to the app below (the plain arrow says so, no outline).
    var shiftHeld = false
    /// The line under the pointer in ⌥ mode, with the screen it's on.
    var hoveredLine: (screen: Int, line: ScreenText.Line)?
    /// Last pointer position per screen, to refresh the hover when ⌥ changes.
    var pointer: [Int: CGPoint] = [:]

    func updateLineHover(screen: Int) {
        guard optionHeld, let point = pointer[screen], let line = texts[screen]?.line(at: point) else {
            if hoveredLine != nil { hoveredLine = nil }
            return
        }
        if hoveredLine?.line != line { hoveredLine = (screen, line) }
    }

    /// How far up the containers ↑ has gone from the hovered element.
    var level = 0
    /// What a click would mark: the hovered element or one of its containers.
    var target: ProbedElement? {
        guard let single = singleTarget else { return nil }
        guard !gathered.isEmpty else { return single }
        // Several gathered with ⇧ and the arrows: one box around them all.
        let all = gathered + [single]
        let box = all.dropFirst().reduce(all[0].frame) { $0.union($1.frame) }
        var group = ProbedElement(frame: box, label: "“\(all.count) \(L10n.t("items"))”")
        group.appName = single.appName
        group.title = all.compactMap(\.title).joined(separator: " · ")
        return group
    }

    /// The one outlined element (or its container, ↑ / ↓), before any gathering.
    private var singleTarget: ProbedElement? {
        guard let hovered else { return nil }
        if level < 0 { return hovered.finer.first ?? hovered }
        return level == 0 ? hovered : hovered.ancestors[min(level, hovered.ancestors.count) - 1]
    }

    /// What ⇧ with the arrows added, beside the one outlined now (marked as one area).
    var gathered: [ProbedElement] = []

    func widen() { if let hovered, level < hovered.ancestors.count { level += 1 } }
    /// Down to the container below, or past the hovered thing to what's inside (−1).
    func narrow() {
        if level > 0 { level -= 1 } else if level == 0, hovered?.finer.isEmpty == false { level = -1 }
    }
    private var probing = false
    private var keyboardHold: CGPoint?
    private var probeStarted = Date.distantPast
    private var lastProbe: CGPoint = .zero

    /// The queue as it is, ready to carry into the next round (text read now, as
    /// the screen it came from goes away).
    func carried() -> [Mark] {
        commitDraft()
        return marks.map { mark in
            var m = mark
            if m.text == nil { m.text = text(of: mark) }
            m.generation = -1  // from an earlier screen: listed in the queue, not drawn
            return m
        }
    }

    /// Starts with marks kept from an earlier round (they stay in the queue).
    func resume(_ queued: [Mark]) {
        marks = queued
        renumber()
    }

    init(grabs: [ScreenGrab], context: MarkContext, terminals: [AgentTerminal], destination: String?) {
        self.grabs = grabs
        self.context = context
        self.terminals = terminals
        self.destination = destination ?? terminals.first?.id
    }

    /// A session's number, as on its ring (terminals come in sidebar order).
    func number(of id: String) -> Int? {
        terminals.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    func terminal(_ id: String?) -> AgentTerminal? {
        terminals.first { $0.id == id }
    }

    /// Refresh the available sessions without moving marks to a different agent.
    /// A closed destination stays on its mark until the user chooses a new one.
    func updateTerminals(_ open: [AgentTerminal]) {
        if terminals != open { terminals = open }
        if destination == nil, marks.isEmpty { destination = open.first?.id }
    }

    var hasUnavailableDestinations: Bool {
        marks.contains { terminal($0.destination) == nil }
    }

    /// The colour of a conversation: its project's hue, as on its ring.
    func hue(for destination: String?) -> NSColor {
        guard let terminal = terminal(destination) else { return .white }
        return NSColor(hues[terminal.id] ?? AkiPalette.hue(number: number(of: terminal.id)))
    }

    /// Looks up what's under the pointer (global point, top-left origin), at most
    /// one lookup at a time and only when the pointer really moved.
    /// Menus that were open when marking began (global top-left points): they closed
    /// as Aki came forward, so what's in them is found on the picture.
    var menus: [CGRect] = []

    /// What's at a point, as the pointer would find it: the app's own answer, or the
    /// picture's when that says too little (or a menu closed there).
    private func lookup(at point: CGPoint) async -> ProbedElement? {
        let front = context.pid
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let screen = grabs.indices.first { i in
            let f = grabs[i].screen.frame
            return CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height).contains(point)
        }
        guard let screen else { return nil }
        let grab = grabs[screen]
        let size = grab.screen.frame.size
        let origin = CGPoint(x: grab.screen.frame.minX, y: primary - grab.screen.frame.maxY)
        let text = texts[screen]
        let inMenu = menus.contains { $0.contains(point) }
        return await Task.detached(priority: .userInitiated) {
            var found = inMenu ? nil : ElementProbe.element(at: point, preferring: front)
            if VisualProbe.tooVague(found, screen: CGRect(origin: .zero, size: size)) {
                found = VisualProbe.element(at: point, found: found, image: grab.image, screenSize: size, origin: origin, text: text)
            }
            return found
        }.value
    }

    enum Direction { case up, down, left, right }
    private var moving = false

    /// The arrows walk the screen: the next thing above, below or beside the outlined
    /// one, about its size (a card goes to the next card, a word to the next word).
    /// `gather` (⇧): the one outlined stays, and the next joins it (they add up).
    func move(_ direction: Direction, gather: Bool = false) {
        guard !moving, let current = singleTarget, let whole = target else { return }
        moving = true
        // Gathering: from the edge of all that's gathered. A plain arrow lets the group
        // go and walks from the one outlined (back to one gathered, too).
        if !gather { gathered = [] }
        let from = gather ? whole.frame : current.frame
        let center = CGPoint(x: from.midX, y: from.midY)
        let wanted = max(current.frame.width * current.frame.height, 1)
        Task {
            defer { moving = false }
            for distance in [6.0, 18, 40, 80, 140, 220] as [CGFloat] {
                let point: CGPoint = switch direction {
                case .up: CGPoint(x: from.midX, y: from.minY - distance)
                case .down: CGPoint(x: from.midX, y: from.maxY + distance)
                case .left: CGPoint(x: from.minX - distance, y: from.midY)
                case .right: CGPoint(x: from.maxX + distance, y: from.midY)
                }
                guard let found = await lookup(at: point) else { continue }
                let options = [found] + found.ancestors
                // Elsewhere: not holding where you are, not inside it.
                let valid = options.indices.filter { i in
                    let f = options[i].frame
                    return !f.contains(center) && !from.contains(CGPoint(x: f.midX, y: f.midY)) && f.width > 4 && f.height > 4
                }
                // The one closest to the size you had.
                guard let best = valid.min(by: { a, b in
                    abs(log(options[a].frame.width * options[a].frame.height / wanted))
                        < abs(log(options[b].frame.width * options[b].frame.height / wanted))
                }) else { continue }
                // From a page: its containers came from the page too (only the first
                // carries the flag), and the page's own pick climbs to the chosen one.
                if found.fromBrowser { await Task.detached { BrowserProbe.climb(best) }.value }
                var picked = options[best]
                picked.fromBrowser = found.fromBrowser
                picked.ancestors = Array(options.dropFirst(best + 1))
                keyboardHold = lastProbe
                if gather {
                    if !gathered.contains(where: { $0.frame == current.frame }) { gathered.append(current) }
                } else {
                    gathered = []
                }
                hovered = picked
                level = 0
                return
            }
            NSSound.beep()
        }
    }

    func probe(at point: CGPoint) {
        // Picked with the arrow keys: a small nudge of the pointer keeps it.
        if let hold = keyboardHold {
            if hypot(point.x - hold.x, point.y - hold.y) < 14 { return }
            keyboardHold = nil
            gathered = []  // the pointer moved on: a new pick
        }
        // A lookup that hangs must not freeze the outline: after a second, start anew.
        if probing, Date().timeIntervalSince(probeStarted) > 1 { probing = false }
        guard !probing, hypot(point.x - lastProbe.x, point.y - lastProbe.y) > 2 else { return }
        probing = true
        probeStarted = Date()
        lastProbe = point
        let front = context.pid
        // The screen under the point, for the picture-based lookup when the app says too little.
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let screen = grabs.indices.first { i in
            let f = grabs[i].screen.frame
            return CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height).contains(point)
        }
        let grab = screen.map { grabs[$0] }
        let size = grab?.screen.frame.size ?? .zero
        let origin = grab.map { CGPoint(x: $0.screen.frame.minX, y: primary - $0.screen.frame.maxY) } ?? .zero
        let text = screen.flatMap { texts[$0] }
        let inMenu = menus.contains { $0.contains(point) }
        Task.detached(priority: .userInitiated) {
            var found = inMenu ? nil : ElementProbe.element(at: point, preferring: front)
            if let grab, VisualProbe.tooVague(found, screen: CGRect(origin: .zero, size: size)) {
                found = VisualProbe.element(at: point, found: found, image: grab.image, screenSize: size, origin: origin, text: text)
            }
            await MainActor.run {
                // Same element as before (pointer moved inside it): keep the ↑ level.
                if self.hovered?.frame != found?.frame || self.hovered?.label != found?.label { self.hovered = found }
                self.probing = false
            }
        }
    }

    /// A screen captured again after scrolling: new picture, its text read anew.
    func replace(_ grab: ScreenGrab, on screen: Int) {
        guard screen < grabs.count else { return }
        // Marks on the old picture keep the text read off it (it's about to go).
        for i in marks.indices where marks[i].screen == screen && marks[i].text == nil {
            if let words = text(of: marks[i]) { marks[i].text = words }
        }
        grabs[screen] = grab
        generation[screen, default: 0] += 1
        texts[screen] = nil
        // A new picture: the menus that had closed belong to the old one.
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let f = grab.screen.frame
        let bounds = CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height)
        menus.removeAll { bounds.intersects($0) }
        hovered = nil
        hoveredLine = nil
        lastProbe = .zero
    }

    /// Arrow keys on a web page: container, first child, sibling before / after.
    func step(_ step: BrowserProbe.Step) {
        Task.detached(priority: .userInitiated) {
            let found = BrowserProbe.step(step)
            await MainActor.run {
                guard let found else { return }
                self.keyboardHold = self.lastProbe
                self.hovered = found
                self.level = 0
            }
        }
    }

    /// Gives the keyboard to the overlay on a screen, so typing lands in the comment.
    var focusScreen: (Int) -> Void = { _ in }
    /// Set by the controller: takes a fresh picture for a mark on a live screen.
    var markAdded: (Mark) -> Void = { _ in }

    /// Starts a mark (finishing the one being written, if any).
    func add(screen: Int, rect: CGRect, element: ProbedElement? = nil, anchor: CGPoint? = nil, text: String? = nil) {
        commitDraft()
        var mark = Mark(screen: screen, rect: rect, destination: destination, number: marks.count + 1, element: element,
                        anchor: anchor ?? CGPoint(x: rect.maxX, y: rect.maxY), text: text)
        mark.grab = screen < grabs.count ? grabs[screen] : nil
        // The app (and page) where it was made: marking may have begun in another one.
        // Told by the element found there; an area dragged over nothing found keeps the
        // app marking began in (window order alone can mislead).
        mark.context = context
        if screen < grabs.count, let app = element?.appName, app != context.appName {
            let frame = grabs[screen].screen.frame
            let primary = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: frame.minX + rect.midX, y: primary - frame.maxY + rect.midY)
            if let here = MarkContext.at(center, appName: app) {
                mark.context = here
                context = here  // the next marks start from that app too
            }
        }
        // A page on localhost picks its session (by port), unless you chose one yourself.
        if !destinationChosen, let url = mark.context?.url, url.contains("://localhost:") || url.contains("://127.0.0.1:") {
            let id = mark.id
            // Counted like a picture being taken: a send waits for it.
            capturing += 1
            Task {
                defer { capturing -= 1 }
                guard let found = await destinationForPage(url), !destinationChosen else { return }
                destination = found
                if let i = marks.firstIndex(where: { $0.id == id }) { marks[i].destination = found }
            }
        }
        mark.generation = generation[screen, default: 0]
        switch Preferences.shared.markContent {
        case .automatic: mark.sendsImage = Self.looksVisual(mark, text: self.text(of: mark))
        case let choice:
            mark.sendsText = choice == .text || choice == .both
            mark.sendsImage = choice == .image || choice == .both
            mark.imageChosen = true  // your setting: Aki stops guessing
        }
        marks.append(mark)
        markAdded(mark)
        // Its crop to the clipboard too (⌘V anywhere): now on a frozen picture; on a live
        // screen once its own picture is taken (`copyPicture`, from the controller).
        if !live { copyPicture(of: mark.id) }
        editing = mark.id
        draft = ""
        focusScreen(screen)
    }

    /// A safe folder name from a project or session name ("SITE AKI 4321" → "SITE-AKI-4321").
    static func folderName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "other" : String(cleaned.prefix(60))
    }

    /// A picture helps when what was marked is visual — an image, an icon, a
    /// drawing, a video, or an area with no text in it; otherwise text is enough.
    static func looksVisual(_ mark: Mark, text: String?) -> Bool {
        let role = (mark.element?.role ?? "").lowercased()
        let visualRoles = ["img", "image", "axImage", "svg", "canvas", "video", "picture", "path", "figure"].map { $0.lowercased() }
        if visualRoles.contains(role) { return true }
        if let label = mark.element?.label.lowercased(), label.hasPrefix("img") || label.hasPrefix("svg") || label.hasPrefix("canvas") {
            return true
        }
        let words = (text ?? mark.element?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty
    }

    /// Opens a queued mark's comment again.
    func edit(_ id: UUID) {
        commitDraft()
        guard let mark = marks.first(where: { $0.id == id }) else { return }
        editing = id
        draft = mark.comment
        focusScreen(mark.screen)
    }

    /// A live screen: the mark's own picture, taken right after it was made (and
    /// its text read from it), since there's no frozen screen to crop from.
    func refreshPicture(of id: UUID, grab: ScreenGrab, text read: ScreenText?) {
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        marks[i].grab = grab
        if marks[i].text == nil, !marks[i].isPoint, let read {
            let words = read.text(in: marks[i].rect)
            if !words.isEmpty { marks[i].text = words }
        }
        if !marks[i].imageChosen {
            marks[i].sendsImage = Self.looksVisual(marks[i], text: marks[i].text ?? marks[i].element?.title)
        }
    }

    func commitDraft() {
        guard let editing, let index = marks.firstIndex(where: { $0.id == editing }) else { return }
        marks[index].comment = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.editing = nil
        draft = ""
    }

    /// Drops the mark being written.
    func cancelEditing() {
        guard let editing else { return }
        marks.removeAll { $0.id == editing }
        self.editing = nil
        draft = ""
        renumber()
    }

    /// The "+N" list of other sessions is open (esc closes it before anything else).
    var listOpen = false

    /// ⏎ with nothing being written: mark what's outlined, as a click would.
    func markTarget() {
        guard let target, !flying, !sending, editing == nil else { return }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        // The screen where you're pointing first (an outline across two displays goes
        // on the one you were looking at), cut to it, as the outline is drawn.
        let pointed = grabs.indices.first { i in
            let f = grabs[i].screen.frame
            return CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height).contains(lastProbe)
        }
        let order = (pointed.map { [$0] } ?? []) + grabs.indices.filter { $0 != pointed }
        for index in order {
            let frame = grabs[index].screen.frame
            let local = target.frame.offsetBy(dx: -frame.minX, dy: -(primary - frame.maxY))
                .intersection(CGRect(origin: .zero, size: frame.size))
            guard !local.isNull, !local.isEmpty else { continue }
            add(screen: index, rect: local, element: target, anchor: CGPoint(x: local.maxX, y: local.maxY))
            focusScreen(index)
            return
        }
    }

    /// Marks ticked in the queue, to take out together (button or ⌫).
    var queueSelected: Set<UUID> = []

    func removeSelected() {
        let ids = queueSelected
        queueSelected = []
        for id in ids { remove(id) }
    }

    func remove(_ id: UUID) {
        queueSelected.remove(id)
        marks.removeAll { $0.id == id }
        if editing == id { editing = nil; draft = "" }
        renumber()
    }

    func renumber() {
        for index in marks.indices { marks[index].number = index + 1 }
    }

    /// Next conversation as destination (Tab). The mark being written follows.
    func cycleDestination(by step: Int = 1) {
        guard !terminals.isEmpty else { return }
        let index = terminals.firstIndex { $0.id == destination } ?? -1
        setDestination(terminals[(index + step + terminals.count) % terminals.count].id)
    }

    /// The text a mark covers: what ⌥ picked, or what's read inside its area.
    func text(of mark: Mark) -> String? {
        if let text = mark.text { return text }
        guard !mark.isPoint, mark.generation == generation[mark.screen, default: 0],
            let read = texts[mark.screen]?.text(in: mark.rect), !read.isEmpty
        else { return nil }
        return read
    }

    /// A mark's crop to the clipboard (when Settings says so), from `grab` when given.
    func copyPicture(of id: UUID, from grab: ScreenGrab? = nil) {
        guard Preferences.shared.copyCrop, var mark = marks.first(where: { $0.id == id }) else { return }
        if let grab { mark.grab = grab }
        guard let image = previewImage(of: mark) else { return }
        Self.copy(image)
        // Said on the card for a moment: it's on the clipboard.
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.copied == id { self?.copied = nil }
        }
    }

    /// Aki's own lists that scroll (other sessions, the queue), per screen, in that
    /// screen's overlay (top-left origin): the wheel over them scrolls them.
    @ObservationIgnored var scrollAreas: [String: CGRect] = [:]

    /// The mark whose crop was just copied (the card says so for a moment).
    var copied: UUID?

    /// An image on the clipboard: one item, as PNG and TIFF (as the Mac's own screenshot
    /// does), so clipboard histories like Raycast's show one picture with its preview.
    static func copy(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation else { return }
        let item = NSPasteboardItem()
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        item.setData(tiff, forType: .tiff)
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([item])
    }

    /// The crop a mark sends, as an image for the preview.
    func previewImage(of mark: Mark) -> NSImage? {
        guard let grab = mark.grab ?? (mark.screen < grabs.count ? grabs[mark.screen] : nil) else { return nil }
        guard let crop = grab.crop(cropRect(for: mark, in: grab)) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }

    func toggle(_ id: UUID, image: Bool) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        if image {
            marks[index].sendsImage.toggle()
            marks[index].imageChosen = true
        } else {
            marks[index].sendsText.toggle()
        }
    }

    /// You chose the destination yourself in this round (⇥, the picker, the list):
    /// the page you mark on no longer changes it.
    var destinationChosen = false
    /// Set by the controller: the session serving a page (localhost:3000 → "3000 …").
    var destinationForPage: (String?) async -> String? = { _ in nil }

    /// Every mark in the queue (and the next ones) to one session.
    func setDestinationForAll(_ id: String) {
        destinationChosen = true
        destination = id
        for i in marks.indices { marks[i].destination = id }
    }

    func setDestination(_ id: String) {
        destinationChosen = true
        destination = id
        if let editing, let index = marks.firstIndex(where: { $0.id == editing }) {
            marks[index].destination = id
        }
    }

    // MARK: Sending

    /// Saves each mark as an annotation (with its crop) for its conversation.
    /// Saves every mark; returns the sessions they went to and the marks that
    /// couldn't be saved (disk full, no permission), which stay in the queue.
    func save(_ toSave: [Mark], into store: AnnotationStore, home: AkiHome = .default) async -> (sentTo: [String], failed: [UUID]) {
        let batch = "batch_\(Int(Date().timeIntervalSince1970 * 1000))"
        var sentTo: [String] = []
        var failed: [UUID] = []
        for mark in toSave {
            guard let grab = mark.grab ?? (mark.screen < grabs.count ? grabs[mark.screen] : nil) else { continue }
            let id = "aki_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8).lowercased())"
            var fields: [String: JSONValue] = [
                "id": .string(id), "comment": .string(mark.comment), "status": "pending",
                "kind": .string(mark.isPoint ? "point" : "area"), "batch_id": .string(batch),
                "number": .number(Double(mark.number)), "source": "mac",
                "rect": [
                    "x": .number(mark.rect.minX), "y": .number(mark.rect.minY),
                    "width": .number(mark.rect.width), "height": .number(mark.rect.height),
                    "screen": .number(Double(mark.screen)),
                ],
            ]
            var app: [String: JSONValue] = [:]
            let context = mark.context ?? self.context
            if let name = context.appName { app["name"] = .string(name) }
            if let bundle = context.bundleID { app["bundle_id"] = .string(bundle) }
            if let window = context.windowTitle, !window.isEmpty { app["window"] = .string(window) }
            if !app.isEmpty { fields["app"] = .object(app) }
            if let url = context.url { fields["url"] = .string(url) }
            // The words the mark covers, read off the screen, so the agent can quote
            // them (a terminal line, an error, code) without reading the image.
            if mark.sendsText, let words = text(of: mark) {
                fields["selected_text"] = .string(String(words.prefix(4000)))
            }
            if let element = mark.element {
                // Same shape as Vibe Annotations' element_context, so agents read it alike.
                var info: [String: JSONValue] = ["path": .string(element.label)]
                if let role = element.role { info["tag"] = .string(role) }
                if let title = element.title { info["text"] = .string(title) }
                if let id = element.domID { info["id"] = .string(id) }
                if !element.domClasses.isEmpty { info["classes"] = .array(element.domClasses.map { .string($0) }) }
                if let source = element.source {
                    info["source"] = .string(source)
                    fields["source_file_path"] = .string(source)
                }
                if let html = element.html { info["html"] = .string(html) }
                fields["element_context"] = .object(info)
                fields["selector"] = .string(element.selector ?? element.label)
            }
            // Never redirect a queued mark silently when its session closes.
            guard let terminal = terminal(mark.destination) else {
                failed.append(mark.id)
                continue
            }
            fields["session_id"] = .string(terminal.id)
            fields["worktree"] = .string(terminal.worktree)
            fields.merge(terminal.identityFields) { _, new in new }
            // Its own folder: marks/<day>/<code>/ with the crop and a record of the request.
            let folder = MarkFolder.make(for: id, home: home)
            if mark.sendsImage, let folder, let crop = grab.crop(cropRect(for: mark, in: grab)), let jpeg = jpegData(crop) {
                let file = folder.appending(path: "crop.jpg")
                if (try? jpeg.write(to: file, options: .atomic)) != nil { fields["image_path"] = .string(file.path) }
            }
            // The crop was asked for and couldn't be written: not sent without it.
            if mark.sendsImage, fields["image_path"] == nil {
                if let folder { try? FileManager.default.removeItem(at: folder) }
                failed.append(mark.id)
                continue
            }
            if let saved = try? await store.upsert(Annotation(fields)) {
                if let folder { MarkFolder.writeRecord(of: saved, in: folder) }
                if let session = fields["session_id"]?.string { sentTo.append(session) }
            } else {
                failed.append(mark.id)
            }
        }
        return (Array(Set(sentTo)), failed)
    }

    /// An area with a little room around it; a point with its surroundings.
    func cropRect(for mark: Mark, in grab: ScreenGrab) -> CGRect {
        let bounds = CGRect(origin: .zero, size: grab.screen.frame.size)
        if mark.isPoint {
            return CGRect(x: mark.rect.midX - 220, y: mark.rect.midY - 150, width: 440, height: 300).intersection(bounds)
        }
        return mark.rect.insetBy(dx: -12, dy: -12).intersection(bounds)
    }

    /// Small and light: at most 1200 px on the long side, JPEG at 70%
    /// (a Retina PNG of the same crop is ~10× bigger).
    private func jpegData(_ image: CGImage) -> Data? {
        let longest = CGFloat(max(image.width, image.height))
        let factor = min(1, 1200 / longest)
        let width = Int(CGFloat(image.width) * factor), height = Int(CGFloat(image.height) * factor)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
