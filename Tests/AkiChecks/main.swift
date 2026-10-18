import AkiCore
import Foundation

// Run with `swift run AkiChecks`. Exits 1 if any check fails.

var failures = 0

@MainActor func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name) (line \(line))")
    }
}

let temp = FileManager.default.temporaryDirectory.appending(path: "aki-checks-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temp) }

// MARK: Store

print("store")
let store = AnnotationStore(directory: temp)
let first = try await store.upsert(Annotation(["url": "http://localhost:3000/", "comment": "make it bigger"]))
check(first.id.hasPrefix("aki_"), "generates an id when missing")
check(first.status == "pending", "new annotations are pending")
check(first["created_at"] != nil && first["updated_at"] != nil, "sets timestamps")

_ = try await store.upsert(Annotation(["id": "b", "url": "x", "comment": "", "worktree": "/repo/wt"]))
let merged = try await store.upsert(Annotation(["id": "b", "comment": "now with text", "_synced": true]))
check(merged["url"]?.string == "x" && merged["comment"]?.string == "now with text", "merges by id")
check(merged["_synced"] == .bool(true), "keeps fields it doesn't know")

for i in 0..<60 { _ = try await store.upsert(Annotation(["id": .string("bulk\(i)"), "url": "y"])) }
check(await store.list().annotations.count == 62, "lists everything by default (no silent limit of 50)")
check(await store.list(.init(limit: 5)).annotations.count == 5, "honors an explicit limit")
check(await store.list(.init(worktree: "/repo/wt")).annotations.map(\.id) == ["b"], "filters by worktree")

let updated = try await store.update("b", with: ["status": "completed", "id": "hijack"])
check(updated?.status == "completed" && updated?.id == "b", "update merges but never changes the id")
check(try await store.update("nope", with: [:]) == nil, "update of a missing id returns nil")
check(try await store.delete("b")?.id == "b", "delete returns the removed annotation")
check(await store.get("b") == nil, "deleted annotation is gone")

let snapshot = await store.list().annotations
check(try await store.replaceAll(snapshot.reversed()).skipped, "sync with the same content is skipped")
check(try await store.replaceAll([Annotation(["id": "only"])]).count == 1, "sync replaces everything")

let reopened = AnnotationStore(directory: temp)
check(await reopened.list().annotations.map(\.id) == ["only"], "persists to disk")
let permissions = try FileManager.default.attributesOfItem(atPath: reopened.fileURL.path)[.posixPermissions]
check((permissions as? Int) == 0o600, "annotations file is private (600)")

let brokenDir = temp.appending(path: "broken")
try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
try Data("{not json".utf8).write(to: brokenDir.appending(path: "annotations.json"))
let broken = AnnotationStore(directory: brokenDir)
check(await broken.list().annotations.isEmpty, "a corrupted file starts empty")
let backups = try FileManager.default.contentsOfDirectory(atPath: brokenDir.path)
check(backups.contains { $0.contains("corrupted") }, "and keeps the corrupted file aside")

// MARK: API (called directly)

print("api")
let apiStore = AnnotationStore(directory: temp.appending(path: "api"))
let extensionOrigin = "chrome-extension://abcdefghijklmnop"
let api = AkiAPI(store: apiStore, token: String(repeating: "t", count: 64), allowedOrigins: [extensionOrigin])
let auth = ["host": "127.0.0.1:3850", "authorization": "Bearer " + String(repeating: "t", count: 64)]

func json(_ response: HTTPResponse) -> [String: JSONValue] {
    (try? JSONDecoder().decode(JSONValue.self, from: response.body))?.object ?? [:]
}

var response = await api.handle(HTTPRequest(method: "GET", path: "/health", headers: ["host": "localhost:3850"]))
check(response.status == 200 && json(response)["app"]?.string == "aki", "health is public")

response = await api.handle(HTTPRequest(method: "GET", path: "/api/annotations", headers: ["host": "127.0.0.1:3850"]))
check(response.status == 401, "no token → 401")

response = await api.handle(
    HTTPRequest(
        method: "GET", path: "/api/annotations",
        headers: ["host": "127.0.0.1:3850", "authorization": "Bearer wrong"]))
check(response.status == 401, "wrong token → 401")

response = await api.handle(
    HTTPRequest(
        method: "DELETE", path: "/api/annotations/x",
        headers: ["host": "127.0.0.1:3850", "origin": "https://evil.example"]))
check(response.status == 401 && response.headers["Access-Control-Allow-Origin"] == nil, "random website can't call it")

response = await api.handle(
    HTTPRequest(method: "GET", path: "/api/annotations", headers: auth.merging(["host": "evil.example:3850"]) { $1 }))
check(response.status == 403, "foreign Host header → 403 (DNS rebinding)")

response = await api.handle(
    HTTPRequest(
        method: "GET", path: "/api/annotations",
        headers: ["host": "127.0.0.1:3850", "origin": extensionOrigin]))
check(
    response.status == 200 && response.headers["Access-Control-Allow-Origin"] == extensionOrigin,
    "allowed extension works without token, with CORS")

response = await api.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data(#"{"id":"p1","url":"u","comment":"hi"}"#.utf8)))
check(response.status == 200 && json(response)["success"] == .bool(true), "POST creates")

response = await api.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data("[1,2]".utf8)))
check(response.status == 400, "POST with a non-object body → 400")

response = await api.handle(HTTPRequest(method: "GET", path: "/api/annotations/p1", headers: auth))
check(json(response)["annotation"]?.object?["comment"]?.string == "hi", "GET by id")

response = await api.handle(
    HTTPRequest(method: "PUT", path: "/api/annotations/p1", headers: auth, body: Data(#"{"status":"completed"}"#.utf8)))
check(json(response)["annotation"]?.object?["status"]?.string == "completed", "PUT merges")

response = await api.handle(
    HTTPRequest(method: "GET", path: "/api/annotations", query: ["status": "pending"], headers: auth))
check(json(response)["count"] == .number(0) && json(response)["total"] == .number(1), "list filters by status")

response = await api.handle(
    HTTPRequest(
        method: "POST", path: "/api/annotations/sync", headers: auth,
        body: Data(#"{"annotations":[{"id":"s1"},{"id":"s2"}]}"#.utf8)))
check(json(response)["count"] == .number(2), "sync replaces")

response = await api.handle(
    HTTPRequest(method: "POST", path: "/api/annotations/sync", headers: auth, body: Data(#"{"annotations":[{}]}"#.utf8)))
check(response.status == 400, "sync rejects annotations without id")

response = await api.handle(HTTPRequest(method: "DELETE", path: "/api/annotations/s1", headers: auth))
check(json(response)["deleted"] == .bool(true), "DELETE")
response = await api.handle(HTTPRequest(method: "DELETE", path: "/api/annotations/s1", headers: auth))
check(response.status == 404, "DELETE twice → 404")

// MARK: Real server

print("server")
let token = String(repeating: "k", count: 64)
let netAPI = AkiAPI(store: AnnotationStore(directory: temp.appending(path: "net")), token: token)
let server = HTTPServer(port: 0, maxBody: 1024) { await netAPI.handle($0) }
let port = try await server.start()
check(port > 0, "starts on a free port (\(port))")

func call(_ method: String, _ path: String, body: String? = nil, token: String? = nil) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let body {
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as! HTTPURLResponse).statusCode, data)
}

check(try await call("GET", "/health").0 == 200, "health over the network")
check(try await call("GET", "/api/annotations").0 == 401, "token required over the network")
check(
    try await call("POST", "/api/annotations", body: #"{"id":"n1","url":"u","comment":"ção ✓"}"#, token: token).0 == 200,
    "POST over the network")
let (_, listed) = try await call("GET", "/api/annotations?status=all", token: token)
check(String(data: listed, encoding: .utf8)?.contains("ção ✓") == true, "UTF-8 survives the round trip")
check(
    try await call("POST", "/api/annotations", body: String(repeating: "x", count: 2048), token: token).0 == 413,
    "oversized body → 413")

let lsof = Process()
lsof.executableURL = URL(filePath: "/usr/sbin/lsof")
lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
let pipe = Pipe()
lsof.standardOutput = pipe
try lsof.run()
lsof.waitUntilExit()
let listening = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
check(listening.contains("127.0.0.1:\(port)") && !listening.contains("*:\(port)"), "listens on 127.0.0.1 only")
server.stop()

// MARK: Worktrees, text, images

print("worktree")
check(Worktree.localPort(of: "http://localhost:3000/a?b") == 3000, "port of a localhost URL")
check(Worktree.localPort(of: "http://127.0.0.1/") == 80, "default port")
check(Worktree.localPort(of: "https://example.com/") == nil, "external sites have no local port")
let filter = WorktreeFilter(worktree: "/repo/wt")
check(filter.matches(Annotation(["worktree": "/repo/wt"])), "tagged annotation matches its worktree")
check(!filter.matches(Annotation(["worktree": "/repo/other", "url": "http://localhost:1/"])), "tag wins over the URL")
check(!filter.matches(Annotation(["url": "https://example.com/"])), "external page isn't in any worktree")

let tagging = AkiAPI(
    store: AnnotationStore(directory: temp.appending(path: "tag")), token: String(repeating: "t", count: 64),
    worktreeForPort: { $0 == 3000 ? "/repo/front" : nil })
response = await tagging.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data(#"{"url":"http://localhost:3000/x"}"#.utf8)))
check(json(response)["annotation"]?.object?["worktree"]?.string == "/repo/front", "localhost page gets the worktree serving it")
response = await tagging.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data(#"{"url":"http://localhost:4000/"}"#.utf8)))
check(json(response)["annotation"]?.object?["worktree"] == nil, "unknown port stays untagged")

print("sessions")
func processArguments(_ argv: [String], environment: [String]) -> Data {
    var argc = Int32(argv.count)
    var data = withUnsafeBytes(of: &argc) { Data($0) }
    data.append(Data("/bin/agent\0\0\0".utf8))
    for value in argv + environment { data.append(Data((value + "\0").utf8)) }
    data.append(0)
    return data
}
check(AgentSessions.terminalHandle(inProcessArguments: processArguments(
    ["codex", "ORCA_TERMINAL_HANDLE=wrong"], environment: ["PATH=/bin", "ORCA_TERMINAL_HANDLE=term_right"])) == "term_right",
    "Orca identity comes from the environment, never from the user's prompt")
check(AgentSessions.terminalHandle(inProcessArguments: processArguments(
    ["codex", "ORCA_TERMINAL_HANDLE=wrong"], environment: ["PATH=/bin"])) == nil,
    "a prompt cannot impersonate an Orca tab when no identity was injected")
check(AgentSessions.terminalHandle(inProcessArguments: Data([1, 2, 3])) == nil,
    "truncated process arguments have no terminal identity")
check(Annotation(["agent": "grok", "session_id": "codex:12"]).destinationAgent == .grok,
    "a moved mark's saved agent takes precedence over its legacy session id")
check(Annotation(["session_id": "codex:12"]).destinationAgent == .codex,
    "old Codex marks retain their agent after the process closes")
check(Annotation(["session_id": "unknown:12"]).destinationAgent == nil,
    "an unknown session id never invents an agent")
let identityMark = try await store.upsert(Annotation([
    "id": "identity", "agent": "codex", "session_name": "App session",
    "terminal_app": ["name": "Orca", "bundle_id": "com.stablyai.orca"],
]))
let identityReopened = AnnotationStore(directory: temp)
let persistedIdentity = await identityReopened.get(identityMark.id)
check(persistedIdentity?.destinationAgent == .codex
      && persistedIdentity?["session_name"]?.string == "App session"
      && persistedIdentity?["terminal_app"]?.object?["bundle_id"]?.string == "com.stablyai.orca",
      "history preserves the agent, session name and terminal app after reopening")
let registry = temp.appending(path: "sessions")
try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
try Data(#"{"pid":\#(getpid()),"sessionId":"s-1","cwd":"/repo/wt","name":"PHOTO EDITOR","nameSource":"user","status":"waiting","kind":"interactive","updatedAt":1791065231403}"#.utf8)
    .write(to: registry.appending(path: "\(getpid()).json"))
try Data(#"{"pid":999999,"sessionId":"dead","cwd":"/x","kind":"interactive"}"#.utf8).write(to: registry.appending(path: "999999.json"))
let live = ClaudeSessions.live(in: registry)
check(live.map(\.sessionId) == ["s-1"], "only sessions whose process is alive")
check(live.first?.status == .waiting && live.first?.name == "PHOTO EDITOR", "status and name read")
check(ClaudeSessions.session(ofAncestorsOf: getpid(), in: registry)?.sessionId == "s-1", "finds the session it runs under")
let sessionFilter = WorktreeFilter(worktree: "/repo/wt", sessionId: "s-1")
check(sessionFilter.matches(Annotation(["session_id": "s-1", "worktree": "/repo/wt"])), "mark aimed at this session")
check(!sessionFilter.matches(Annotation(["session_id": "s-2", "worktree": "/repo/wt"])), "not one aimed at a sibling session")
check(sessionFilter.matches(Annotation(["worktree": "/repo/wt"])), "untargeted marks in the worktree still arrive")

print("text and images")
let home = AkiHome(url: temp.appending(path: "home"))
let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
let rich = Annotation([
    "id": "r1", "url": "http://localhost:3000/", "comment": "", "created_at": "2026-10-03T10:20:30.000Z",
    "element_context": ["tag": "button", "text": "Save"], "selector": "#save",
    "pending_changes": ["color": ["original": "red", "value": "blue"]],
    "screenshot": ["data_url": .string("data:image/png;base64," + pixel)],
])
let rendered = AnnotationText.render(rich, home: home)
check(rendered.contains("## #r1 · r1  (2026-10-03 10:20)"), "header with code, id and date")
// Short codes: the same everywhere, found from any terminal.
check(MarkFolder.code("aki_1791339895884_df9f68ee") == "df9f68", "short code of a mark")
check(markCode("aki_1791339895884_df9f68ee") == "#df9f68", "short code as people read it")
let coded = [Annotation(["id": "aki_1_df9f68ee"]), Annotation(["id": "aki_2_e8a1b2c3"]), Annotation(["id": "aki_3_e8a1ffff"])]
check(MarkFolder.resolve(["#df9f68"], in: coded).found.map(\.id) == ["aki_1_df9f68ee"], "finds a mark by #code")
check(MarkFolder.resolve(["e8a1b2"], in: coded).found.map(\.id) == ["aki_2_e8a1b2c3"], "finds a mark by bare code")
check(MarkFolder.resolve(["e8a1"], in: coded).problems.count == 1, "an ambiguous code says so")
check(MarkFolder.resolve(["e8a1b2c3"], in: coded).found.map(\.id) == ["aki_2_e8a1b2c3"], "finds a mark by its 8-letter code (the message's commands)")
check(MarkFolder.resolve(["zzzzzz"], in: coded).problems.count == 1, "an unknown code says so")
check(MarkFolder.url(for: "aki_1_df9f68ee", created: Date(timeIntervalSince1970: 1_791_374_400), home: home).path
        .hasSuffix("/marks/2026-10-07/df9f68ee"), "a mark's folder is its day and its id's random part")
check(rendered.contains("comment:  (no text)") && rendered.contains("<button> #save"), "comment and element")
check(rendered.contains("change:   color: red → blue"), "pending style change")
let imageFile = AnnotationImage.file(for: rich, home: home)
check(imageFile?.pathExtension == "png" && FileManager.default.fileExists(atPath: imageFile?.path ?? ""), "inline screenshot saved as a file")
check(rendered.contains("image:    \(imageFile?.path ?? "-")"), "image path in the text")

print("wait")
try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
let waitToken = try home.token()
let waitAPI = AkiAPI(
    store: AnnotationStore(directory: home.url), token: waitToken, worktreeForPort: { _ in nil })
let waitServer = HTTPServer(port: 0) { await waitAPI.handle($0) }
let waitPort = try await waitServer.start()
let client = try AkiClient(home: home, port: waitPort)
_ = try await waitAPI.store.upsert(Annotation(["id": "unread", "worktree": "/repo/wt"]))
let leftOver = try await Waiter.waitForNew(
    client: client, worktree: "/repo/wt", idle: .milliseconds(600), timeout: .seconds(3), poll: .milliseconds(150))
check(leftOver.map(\.id) == ["unread"], "a mark pending but never read comes back at once")
try await client.update("unread", ["status": "completed"])
_ = try await waitAPI.store.upsert(Annotation(["id": "old", "worktree": "/repo/wt", "read_at": "2026-10-16T00:00:00Z"]))
async let waited = Waiter.waitForNew(
    client: client, worktree: "/repo/wt", idle: .milliseconds(600), timeout: .seconds(10), poll: .milliseconds(150))
try await Task.sleep(for: .milliseconds(400))
_ = try await waitAPI.store.upsert(Annotation(["id": "new1", "worktree": "/repo/wt"]))
_ = try await waitAPI.store.upsert(Annotation(["id": "other", "worktree": "/repo/elsewhere"]))
try await Task.sleep(for: .milliseconds(300))
_ = try await waitAPI.store.upsert(Annotation(["id": "new2", "worktree": "/repo/wt"]))
let started = ContinuousClock.now
let batch = try await waited
check(Set(batch.map(\.id)) == ["new1", "new2"], "wait returns only new marks of this worktree, together")
check(ContinuousClock.now - started >= .milliseconds(400), "and only after the user pauses")
try await client.update("new1", ["status": "completed"])
check(await waitAPI.store.get("new1")?.status == "completed", "client resolves")
waitServer.stop()

// Which processes count as agent sessions.
// The Claude app's Code tab: its own Claude Code, under "Application Support", run as a program.
let desktopClaude = "/Users/x/Library/Application Support/Claude/claude-code/2.1.299/4fa9/claude.app/Contents/MacOS/claude --output-format stream-json --verbose --input-format stream-json"
check(AgentSessions.classify(desktopClaude) == .agent(.claude), "the Claude app's Code session is a session")
check(AgentSessions.headless(desktopClaude) == nil, "and not a headless run")
check(AgentSessions.isClaudeAppSession(desktopClaude), "found as a Claude app session by its process")
check(AgentSessions.sessionID(in: desktopClaude + " --resume=2b1c-44 --model=x") == "2b1c-44", "its session id from --resume=")
check(AgentSessions.sessionID(in: desktopClaude + " --session-id 9f9f") == "9f9f", "or from --session-id")
check(!AgentSessions.isClaudeAppSession("/Users/x/.local/bin/claude --resume=1"), "a terminal's claude isn't the app's")
check(ClaudeSessions.parse(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":"sdk","entrypoint":"claude-desktop"}"#.utf8)) != nil, "a Code session of the Claude app is listed")
check(ClaudeSessions.parse(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":"bg","entrypoint":"cli"}"#.utf8)) == nil, "a background run from a terminal isn't")
check(AgentSessions.classify("/opt/homebrew/bin/codex") == .agent(.codex), "codex alone is a session")
check(AgentSessions.classify("codex --no-daemon resume 01a1") == .agent(.codex), "codex resume is a session")
check(AgentSessions.classify("codex -c model=x review") == nil, "codex review with options isn't")
check(AgentSessions.classify("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled") == nil,
      "the ChatGPT app's codex app-server isn't")
check(AgentSessions.classify(#"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c forced_login_method="chatgpt" exec-server --remote https://x"#) == nil,
      "nor its exec-server")
check(AgentSessions.headless("/opt/homebrew/bin/codex -c model=x review --base main") == .codex, "a codex review spends Codex")
check(AgentSessions.headless("/opt/homebrew/bin/codex exec hi") == .codex, "so does codex exec")
check(AgentSessions.headless("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server") == nil, "the app's server isn't a run")
check(AgentSessions.headless("/Users/x/.local/bin/claude -p hi") == .claude, "claude -p spends Claude")
check(AgentSessions.headless("/opt/homebrew/bin/node /opt/homebrew/bin/claude -p hi") == .claude, "also run by node")
check(AgentSessions.classify("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex sandbox -c shell_environment_policy.inherit=all") == nil,
      "the ChatGPT app's codex sandbox isn't")
check(AgentSessions.classify("claude -p hi") == nil && AgentSessions.classify("claude") == .agent(.claude), "claude -p isn't, claude is")

// A tab's status sign goes, a name's own first character stays.
check(tabNameWithoutStatus("✳ SEO AKI") == "SEO AKI", "status sign taken off a name")
check(tabNameWithoutStatus("⠂ MENU") == "MENU", "spinner taken off a name")
check(tabNameWithoutStatus("🐛 Login") == "🐛 Login", "an emoji in a name stays")
check(tabNameWithoutStatus("[API] auth") == "[API] auth", "brackets in a name stay")

// Codex's limits, from one of its log lines: the week goes by the window's length.
let codexLine = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":17.0,"window_minutes":10080,"resets_at":4102444800},"secondary":{"used_percent":42.4,"window_minutes":300,"resets_at":4102444800}}}}"#
let codexLimits = UsageLimits.parseCodex(line: Data(codexLine.utf8), updated: Date())
check(codexLimits?.week?.percent == 17, "Codex week read from the 7-day window")
check(codexLimits?.fiveHour?.percent == 42, "Codex 5-hour window read")
let monthly = UsageLimits.parseCodex(line: Data(#"{"payload":{"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":43200,"resets_at":4102444800},"secondary":null}}}"#.utf8), updated: Date())
check(monthly?.month?.percent == 3 && monthly?.week == nil, "Codex 30-day window read as the month")
check(UsageLimits.parseCodex(line: Data(#"{"payload":{"rate_limits":{"primary":null,"secondary":null}}}"#.utf8), updated: Date()) == nil,
      "no windows, no limits")
// What OpenAI says of a Codex account: resets saved, all-time numbers, weeks in order.
var codexAccount = CodexAccount()
codexAccount.addUsage(Data(#"{"plan_type":"prolite","rate_limit_reset_credits":{"available_count":3,"applicable_available_count":0}}"#.utf8))
codexAccount.addProfile(Data(#"{"stats":{"lifetime_tokens":2701713581,"total_threads":4133,"longest_running_turn_sec":15359,"most_used_reasoning_effort":"medium","top_invocations":[{"type":"plugin","plugin_name":"github","skill_name":null,"usage_count":299},{"type":"skill","plugin_name":null,"skill_name":"orca-cli","usage_count":6}],"weekly_usage_buckets":[{"start_date":"2026-03-09","tokens":5},{"start_date":"2026-03-02","tokens":9}]}}"#.utf8))
check(codexAccount.resetsSaved == 3 && codexAccount.resetsUsable == 0, "Codex resets saved read")
check(codexAccount.lifetimeTokens == 2701713581 && codexAccount.threads == 4133, "Codex all-time numbers read")
check(codexAccount.invocations.map(\.name) == ["github", "orca-cli"], "Codex calls named by plugin or skill")
check(codexAccount.weeks.map(\.tokens) == [9, 5], "Codex weeks oldest first")

// Codex's older logs come zstd-compressed: unpacked whole, and a cut file refused.
let packedLog = FileManager.default.temporaryDirectory.appending(path: "aki-check-\(UUID().uuidString).jsonl.zst")
let unpackedLog = FileManager.default.temporaryDirectory.appending(path: "aki-check-\(UUID().uuidString).jsonl")
let packedBytes = Data(base64Encoded: "KLUv/QRYkQAAbGluZSBvbmUKbGluZSB0d28KK4y37g==")!
try? packedBytes.write(to: packedLog)
check(TokenLedger.unpack(packedLog, to: unpackedLog) && (try? String(contentsOf: unpackedLog, encoding: .utf8)) == "line one\nline two\n",
      "a zstd log unpacked")
try? packedBytes.prefix(packedBytes.count - 4).write(to: packedLog)
check(!TokenLedger.unpack(packedLog, to: unpackedLog), "a cut zstd log refused")
try? FileManager.default.removeItem(at: packedLog)
try? FileManager.default.removeItem(at: unpackedLog)
// A real one, on demand: AKI_ZST_SAMPLE=<log.jsonl.zst> AKI_ZST_EXPECT=<same, unpacked by zstd -d>.
if let sample = ProcessInfo.processInfo.environment["AKI_ZST_SAMPLE"], let expect = ProcessInfo.processInfo.environment["AKI_ZST_EXPECT"] {
    check(TokenLedger.unpack(URL(fileURLWithPath: sample), to: unpackedLog)
          && (try? Data(contentsOf: unpackedLog)) == (try? Data(contentsOf: URL(fileURLWithPath: expect))), "a real Codex log unpacked as zstd does")
    try? FileManager.default.removeItem(at: unpackedLog)
}

// The history counts each request once: a first pass, the reading of older logs, then
// a session resumed after more than a week (read again from its start).
let ledgerRoot = FileManager.default.temporaryDirectory.appending(path: "aki-ledger-\(UUID().uuidString)")
let claudeLogs = ledgerRoot.appending(path: "claude/project")
try? FileManager.default.createDirectory(at: claudeLogs, withIntermediateDirectories: true)
let ledgerLog = claudeLogs.appending(path: "session.jsonl")
func claudeTurn(_ id: String, _ at: Date, _ tokens: Int) -> String {
    #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: at))","requestId":"\#(id)","cwd":"/tmp","message":{"model":"claude-opus-4-5","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"# + "\n"
}
let ledgerNow = Date()
try? (claudeTurn("r1", ledgerNow.addingTimeInterval(-20 * 86400), 100) + claudeTurn("r2", ledgerNow.addingTimeInterval(-3 * 86400), 10)
      + claudeTurn("r3", ledgerNow.addingTimeInterval(-3600), 1)).write(to: ledgerLog, atomically: true, encoding: .utf8)
let ledger = TokenLedger(home: AkiHome(url: ledgerRoot.appending(path: "home")), claudeRoot: ledgerRoot.appending(path: "claude"),
                         codexRoot: ledgerRoot.appending(path: "codex/sessions"))
ledger.update(now: ledgerNow)
if ledger.needsBackfill { ledger.backfill() }
check(ledger.daily(agent: "claude").values.reduce(0, +) == 111, "old and new requests counted once")
// Ten days on, the session resumed: one new request, the file read again from its start.
let later = ledgerNow.addingTimeInterval(10 * 86400)
if let handle = try? FileHandle(forWritingTo: ledgerLog) {
    handle.seekToEndOfFile()
    handle.write(Data(claudeTurn("r4", later.addingTimeInterval(-3600), 1000).utf8))
    try? handle.close()
}
try? FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: ledgerLog.path)
ledger.update(now: later)
check(ledger.daily(agent: "claude").values.reduce(0, +) == 1111, "a resumed session's old requests not counted again")
// Aki closed for twelve days; a session that ran and ended three days into them still counts.
let ended = claudeLogs.appending(path: "ended.jsonl")
try? claudeTurn("r5", later.addingTimeInterval(3 * 86400), 5).write(to: ended, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.modificationDate: later.addingTimeInterval(3 * 86400)], ofItemAtPath: ended.path)
ledger.update(now: later.addingTimeInterval(12 * 86400))
check(ledger.daily(agent: "claude").values.reduce(0, +) == 1116, "a session that ended while Aki was closed counted")
try? FileManager.default.removeItem(at: ledgerRoot)

// Days in a row up to today (or yesterday), the longest run, the busiest day.
let streakNow = ISO8601DateFormatter().date(from: "2026-10-18T15:00:00Z")!
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let streakSpend = TokenSpend.of([], weekStart: nil, daily: ["2026-10-17": 5, "2026-10-16": 9, "2026-10-14": 1, "2026-10-01": 2,
                                                             "2026-10-02": 2, "2026-10-03": 2, "2026-10-04": 2],
                                now: streakNow, calendar: utc)
check(streakSpend.streak == 2, "streak counts back from yesterday when today is empty")
check(streakSpend.longestStreak == 4, "longest run found")
check(streakSpend.busiest?.total.tokens == 9, "busiest day found")
check(TokenSpend.modelName("claude-opus-4-1-20250805") == "Opus 4.1" && TokenSpend.modelName("gpt-6.1-sol") == "gpt-6.1-sol",
      "model names shortened")
let renewed = UsageLimits.parseCodex(line: Data(codexLine.replacingOccurrences(of: "4102444800", with: "1000").utf8), updated: Date())?.current()
check(renewed?.week?.percent == 0, "a window that already renewed reads 0%")
check((renewed?.week?.resets ?? .distantPast) > Date(), "a renewed week keeps a start (its next renewal)")
check(UsageLimits.parseCodex(line: Data(codexLine.replacingOccurrences(of: #"{"type":"event_msg""#, with: #"{"timestamp":"2026-10-10T20:57:25.894Z","type":"event_msg""#).utf8),
                              updated: .distantPast)?.updated == Date(timeIntervalSince1970: 1791665845.894),
      "a Codex report dated by its own time")

// The Mac's screenshots: found by their name (any language) or macOS's own mark, nothing else.
let shots = FileManager.default.temporaryDirectory.appending(path: "aki-shots-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: shots.appending(path: "inside"), withIntermediateDirectories: true)
let oldName = "Screenshot 2026-10-10 at 15.30.00 \(UUID().uuidString).png"
for name in [oldName, "Captura de Tela 2026-01-02 às 09.10.11.png", "inside/截屏2026-10-10 15.30.00.png",
             "screenshot of the logo.png", "Screenshot 1.png", "Screen Recording 2.mov", "report.pdf", "notes.txt"] {
    FileManager.default.createFile(atPath: shots.appending(path: name).path, contents: Data(repeating: 1, count: 1000))
}
let marked = shots.appending(path: "foto.png")
FileManager.default.createFile(atPath: marked.path, contents: Data(repeating: 1, count: 500))
_ = "1".withCString { setxattr(marked.path, "com.apple.metadata:kMDItemIsScreenCapture", $0, 1, 0, 0) }
let old = shots.appending(path: oldName)
try? FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-40 * 24 * 3600)], ofItemAtPath: old.path)
let found = Screenshots.scan([shots])
check(found.files.count == 4, "screenshots found by name in any language and by macOS's mark (\(found.files.count))")
check(found.bytes == 3500, "their size added up")
check(found.older(than: 30).map(\.url.lastPathComponent) == [old.lastPathComponent], "only the old one is old")
let oldOnes = found.older(than: 30)
check(Screenshots.trash(oldOnes).count == 1 && !FileManager.default.fileExists(atPath: old.path), "the old one goes to the Trash")
// Out of the Trash again: the check leaves nothing behind.
for item in oldOnes { try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash/\(item.url.lastPathComponent)")) }
try? FileManager.default.removeItem(at: shots)

// Codex is working while its log has a turn open.
check(CodexSessions.turnOpen(#"{"payload":{"type":"task_complete"}}\n{"payload":{"type":"task_started"}}"#) == true, "a turn just started is open")
check(CodexSessions.turnOpen(#"{"payload":{"type":"task_started"}}\n{"payload":{"type":"task_complete"}}"#) == false, "a finished turn is closed")
check(CodexSessions.turnOpen(#"{"payload":{"type":"task_started"}}\n{"payload":{"type":"turn_aborted"}}"#) == false, "an interrupted turn is closed")
check(CodexSessions.turnOpen(#"{"type":"session_meta"}"#) == nil, "no turn event in it: look further")

// The agents' desktop apps: the app itself, never one of its helpers.
check(DesktopApps.bundleID(of: "app:com.openai.codex") == "com.openai.codex", "an app destination's id names its app")
check(DesktopApps.bundleID(of: "codex:123") == nil, "a terminal session isn't an app")
let appMessage = AnnotationText.forApp([
    Annotation(["id": "aki_1_aaaaaaaa", "created_at": "2026-10-13T10:00:00Z", "comment": "botão torto", "url": "http://localhost:3000/x"]),
    Annotation(["id": "aki_2_bbbbbbbb", "created_at": "2026-10-13T10:01:00Z"]),
])
check(appMessage.contains("2 marcas") && appMessage.contains("1. botão torto") && appMessage.contains("localhost:3000")
      && appMessage.contains("2. (sem comentário)") && !appMessage.contains("aki show"), "an app's message carries the marks themselves")
check(appMessage.hasPrefix("📍 Aki: 2 marcas na tela (#aaaaaa, #bbbbbb)."), "an app's message names its marks in its first line")

// A Codex conversation's name comes from its index, by the id ending its log's name.
let codexHome = FileManager.default.temporaryDirectory.appending(path: "aki-codex-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
try? """
{"id":"01a1372a-7a31-78a2-a61a-aa7a4582e215","thread_name":"Primeiro nome","updated_at":"x"}
{"id":"01a1372a-7a31-78a2-a61a-aa7a4582e215","thread_name":"Revisar NFs no Drive","updated_at":"y"}
""".write(to: codexHome.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
let codexLog = URL(filePath: "/x/rollout-2026-10-13T18-28-13-01a1372a-7a31-78a2-a61a-aa7a4582e215.jsonl")
check(CodexSessions.threadName(of: codexLog, home: codexHome) == "Revisar NFs no Drive", "a Codex conversation is named as Codex named it last")
try? FileManager.default.removeItem(at: codexHome)

// The Claude app's cached usage: only its own usage request, and its two windows.
check(ClaudeAppUsage.isUsage("1/0/https://claude.ai/api/organizations/abc/usage"), "claude app usage key")
check(ClaudeAppUsage.isUsage("1/0/https://claude.ai/api/organizations/abc/usage?x=1"), "claude app usage key with query")
check(!ClaudeAppUsage.isUsage("1/0/https://claude.ai/api/organizations/abc/chat_conversations"), "other claude requests are not read")
let appUsage = ClaudeAppUsage.parse(Data(#"{"five_hour":{"utilization":12.4,"resets_at":"2026-10-15T22:00:00.123+00:00"},"seven_day":{"utilization":29,"resets_at":"2026-10-19T12:00:00Z"}}"#.utf8), updated: Date())
check(appUsage?.week?.percent == 29 && appUsage?.fiveHour?.percent == 12 && appUsage?.week?.resets != nil && appUsage?.fiveHour?.resets != nil, "claude app usage parsed")
check(ClaudeAppUsage.parse(Data(#"{"other":1}"#.utf8), updated: Date()) == nil, "no windows, no reading")

// A message pasted into a Claude app's Code session: found in that session's transcript.
do {
    let base = FileManager.default.temporaryDirectory.appending(path: "aki-received-\(UUID().uuidString)")
    let registry = base.appending(path: "sessions"), projects = base.appending(path: "projects")
    let cwd = "/tmp/proj x"
    let slug = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: projects.appending(path: slug), withIntermediateDirectories: true)
    try? Data(#"{"pid":\#(getpid()),"sessionId":"s1","cwd":"/tmp/proj x","kind":"sdk","entrypoint":"claude-desktop"}"#.utf8)
        .write(to: registry.appending(path: "1.json"))
    let line = #"{"type":"user","message":{"content":"📍 Aki: 2 marcas na tela (#ab12cd, #ef34aa).\n\"x\""}}"# + "\n"
    try? Data(line.utf8)
        .write(to: projects.appending(path: slug).appending(path: "s1.jsonl"))
    check(ClaudeSessions.received("📍 Aki: 2 marcas na tela (#ab12cd, #ef34aa).", sessionId: "s1", in: registry, projects: projects), "a message sent to a Code session is found in its transcript")
    check(!ClaudeSessions.received("📍 Aki: 1 marca na tela (#999999).", sessionId: "s1", in: registry, projects: projects), "another message isn't")
    try? FileManager.default.removeItem(at: registry.appending(path: "1.json"))
    check(ClaudeSessions.received("📍 Aki: 2 marcas na tela (#ab12cd, #ef34aa).", sessionId: "s1", in: registry, projects: projects), "found without a registry entry too")
    try? FileManager.default.removeItem(at: base)
}

// The week's conversations: a folder with quotes, also in a line cut short.
check(SessionHistory.firstValue(of: "cwd", in: #"{"cwd":"/tmp/projeto \"A\"","type":"user"}"#) == #"/tmp/projeto "A""#, "a folder with quotes is read whole")
check(SessionHistory.firstValue(of: "cwd", in: #"{"type":"session_meta","payload":{"id":"x","cwd":"/a \"b\"","base_instructions":"cut"#) == #"/a "b""#, "also from a line cut short")

// The apps' own conversations, each a destination.
check(DesktopApps.bundleID(of: "app:com.openai.codex#01a0-ab") == "com.openai.codex", "a conversation's app")
check(DesktopApps.conversation(of: "app:com.openai.codex#01a0-ab") == "01a0-ab", "a conversation's id")
check(DesktopApps.conversation(of: "app:com.openai.codex") == nil, "the app itself is no conversation")
check(DesktopApps.link(to: "01a0-ab", in: "com.openai.codex")?.absoluteString == "codex://threads/01a0-ab", "codex thread link")
check(DesktopApps.link(to: "abc-1", in: "com.anthropic.claudefordesktop")?.absoluteString == "claude://claude.ai/chat/abc-1", "claude chat link")
check(DesktopApps.link(to: "a/../b?x", in: "com.openai.codex") == nil, "only an id goes in a link")
check(ClaudeAppUsage.isConversationList("1/0/https://claude.ai/api/organizations/o/chat_conversations_v2?limit=30&offset=0"), "the chats list")
check(!ClaudeAppUsage.isConversationList("1/0/https://claude.ai/api/organizations/o/chat_conversations_v2?starred=true"), "not the starred ones")
let chats = ClaudeAppUsage.parseConversations(Data(#"{"data":[{"uuid":"a","name":"Old","updated_at":"2026-10-01T10:00:00Z"},{"uuid":"b","name":"New","updated_at":"2026-10-02T10:00:00Z"},{"uuid":"c","name":"","updated_at":"2026-10-03T10:00:00Z"}]}"#.utf8))
check(chats?.map(\.id) == ["b", "a"], "chats newest first, unnamed ones left out")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
