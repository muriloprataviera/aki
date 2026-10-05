import AkiCore
import AppKit
import Foundation

let usage = """
    aki \(Aki.version) — point at anything on screen, your coding agent reads it.

    usage:
      aki list [--all] [--status S]   pending marks for this worktree (--all: every worktree and site)
      aki wait [--idle N]             block until new marks arrive here and the user pauses N s (default 5)
      aki done ID...                  mark as resolved
      aki delete ID...                delete
      aki sessions                    agents running now, grouped by worktree (what the sidebar shows)
      aki mcp                         MCP server over stdio (add with: claude mcp add aki -- aki mcp)
      aki app                         open the app (sidebar + server)
      aki serve [--port N]            run only the annotations server, in the foreground (default \(Aki.defaultPort))
      aki --version

    The worktree is the git root of the current folder (override with AKI_WORKTREE).
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aki: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { fail("\(name) needs a value") }
    return arguments[index + 1]
}

func makeClient() -> AkiClient {
    do { return try AkiClient() } catch { fail("can't read the token in \(AkiHome.default.tokenURL.path): \(error)") }
}

/// The agent session this command runs under (found by walking up to its `claude`).
let currentSession = ClaudeSessions.session(ofAncestorsOf: getpid())
/// Its id as the sidebar knows it: Claude's session id, or "codex:<pid>" for the others.
let currentSessionID = currentSession?.sessionId ?? AgentSessions.agentID(ofAncestorsOf: getpid())

var currentWorktree: String {
    if let custom = ProcessInfo.processInfo.environment["AKI_WORKTREE"], !custom.isEmpty { return custom }
    return Worktree.root(of: FileManager.default.currentDirectoryPath)
}

// Line-buffered so logs show up right away when stdout goes to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

// Opened from Finder / `open Aki.app` (no terminal attached) or `aki app`: run the app.
if arguments.first == "app" || (arguments.isEmpty && isatty(STDIN_FILENO) == 0) {
    AppMain.run()
}

do {
    switch arguments.first {
    case "list":
        let client = makeClient()
        let all = try await client.list(status: option("--status") ?? "pending")
        if arguments.contains("--all") {
            print(all.isEmpty ? "no annotations" : AnnotationText.render(all))
            break
        }
        let worktree = currentWorktree
        let filter = WorktreeFilter(worktree: worktree, sessionId: currentSessionID)
        let mine = all.filter(filter.matches)
        print("# worktree: \(worktree)")
        if let session = currentSession { print("# session: \(session.name ?? session.sessionId)") }
        print("# ports served from it: \(filter.ports.sorted().map(String.init).joined(separator: ", ").ifEmpty("none"))")
        print("# \(mine.count) annotation(s) for this worktree")
        if !mine.isEmpty { print("\n" + AnnotationText.render(mine)) }
        await client.markRead(mine)
        if all.count > mine.count { print("\n# \(all.count - mine.count) other(s) elsewhere (aki list --all)") }

    case "wait":
        let idle = option("--idle").flatMap(Double.init) ?? Double(UserDefaults(suiteName: "ai.useaki.Aki")?.integer(forKey: "waitIdleSeconds") ?? 0).nonZero ?? 5
        let worktree = currentWorktree
        print("# waiting for annotations in \(worktree)")
        let waitClient = makeClient()
        let fresh = try await Waiter.waitForNew(
            client: waitClient, worktree: worktree, sessionId: currentSessionID, idle: .seconds(idle))
        await waitClient.markRead(fresh)
        print("# \(fresh.count) new annotation(s)\n")
        print(AnnotationText.render(fresh))

    case "done", "delete":
        let ids = Array(arguments.dropFirst())
        guard !ids.isEmpty else { fail("which id?") }
        let client = makeClient()
        for id in ids {
            if arguments.first == "done" {
                try await client.update(
                    id, ["status": "completed",
                         "resolved_at": .string(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date()))])
                print("resolved \(id)")
            } else {
                try await client.delete(id)
                print("deleted \(id)")
            }
        }

    case "terminals":
        if ProcessInfo.processInfo.environment["AKI_TIMING"] == "1" {
            let clock = ContinuousClock()
            var t0 = clock.now
            let live = ClaudeSessions.live()
            print("live", live.count, clock.now - t0); t0 = clock.now
            for s in live { _ = ClaudeSessions.title(sessionId: s.sessionId, cwd: s.cwd) }
            print("titles", clock.now - t0); t0 = clock.now
            for s in live { _ = ClaudeSessions.lastAgentMessage(sessionId: s.sessionId, cwd: s.cwd) }
            print("messages", clock.now - t0); t0 = clock.now
            for s in live { _ = Worktree.root(of: s.cwd) }
            print("roots", clock.now - t0); t0 = clock.now
        }
        for t in AgentSessions.terminals() {
            let message = (t.lastMessage ?? "").prefix(70)
            print("\(t.agent.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(t.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(t.name.prefix(30).padding(toLength: 30, withPad: " ", startingAt: 0)) \(URL(filePath: t.worktree).lastPathComponent)  — \(message)")
        }

    case "visual-probe":
        // Bench for the picture-based lookup: aki visual-probe in.png out.png x,y x,y …
        // (points). Draws the box found at each point (red) and the one holding it (blue).
        guard arguments.count >= 4, let image = NSImage(contentsOfFile: arguments[1]),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixels = VisualProbe.Pixels(cg, size: image.size)
        else { fail("usage: aki visual-probe in.png out.png x,y …") }
        let text = ScreenText.read(cg, size: image.size)
        let bounds = CGRect(origin: .zero, size: image.size)
        var found: [(CGPoint, [CGRect])] = []
        for argument in arguments.dropFirst(3) {
            let xy = argument.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { continue }
            let point = CGPoint(x: xy[0], y: xy[1])
            let started = Date()
            let boxes = VisualProbe.boxes(at: point, in: pixels, within: bounds, lines: text.lines)
            print("\(argument): \(boxes.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(separator: " ⊂ "))  (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            found.append((point, boxes))
        }
        let out = NSImage(size: image.size, flipped: true) { _ in
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            for (point, boxes) in found {
                for (i, box) in boxes.prefix(2).enumerated() {
                    (i == 0 ? NSColor.systemRed : NSColor.systemBlue).setStroke()
                    let path = NSBezierPath(rect: box.insetBy(dx: CGFloat(-i), dy: CGFloat(-i)))
                    path.lineWidth = 2
                    path.stroke()
                }
                NSColor.systemYellow.setFill()
                NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
            return true
        }
        guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { fail("couldn't draw") }
        try? png.write(to: URL(filePath: arguments[2]))

    case "orca-tabs":
        // Which Orca tab each conversation maps to (no switching).
        for t in AgentSessions.terminals() {
            print("\(t.name.prefix(36).padding(toLength: 36, withPad: " ", startingAt: 0)) → \(TerminalJump.orcaTab(for: t) ?? "—")")
        }

    case "sessions":
        for session in AgentSessions.scan() {
            let state = [session.listening ? "listening" : nil, session.working ? "working" : nil].compactMap { $0 }
            print("\(session.worktree)  [\(session.branch ?? "-")]  \(session.agents.map(\.rawValue).joined(separator: "+"))  \(state.joined(separator: ","))")
        }

    case "mcp":
        await MCPServer(client: makeClient(), worktree: currentWorktree, sessionId: currentSessionID).run()

    case "serve":
        var port = Aki.defaultPort
        if let value = option("--port") {
            guard let parsed = UInt16(value) else { fail("--port needs a number") }
            port = parsed
        }
        let home = AkiHome.default
        let token: String
        do { token = try home.token() } catch { fail("can't create \(home.tokenURL.path): \(error)") }
        let api = AkiAPI(store: AnnotationStore(directory: home.url), token: token)
        let server = HTTPServer(port: port) { await api.handle($0) }
        do {
            let actual = try await server.start()
            print("aki listening on http://127.0.0.1:\(actual) (data in \(home.url.path))")
        } catch {
            fail("can't listen on port \(port): \(error)")
        }
        while true { try await Task.sleep(for: .seconds(3600)) }

    case "--version", "version":
        print(Aki.version)

    default:
        print(usage)
    }
} catch {
    fail("\(error)")
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension Double {
    /// Nil when zero (a setting never saved).
    var nonZero: Double? { self == 0 ? nil : self }
}
