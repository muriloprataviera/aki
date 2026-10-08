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
_ = try await waitAPI.store.upsert(Annotation(["id": "old", "worktree": "/repo/wt"]))
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
check(AgentSessions.classify("/opt/homebrew/bin/codex") == .agent(.codex), "codex alone is a session")
check(AgentSessions.classify("codex --no-daemon resume 01a1") == .agent(.codex), "codex resume is a session")
check(AgentSessions.classify("codex -c model=x review") == nil, "codex review with options isn't")
check(AgentSessions.classify("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled") == nil,
      "the ChatGPT app's codex app-server isn't")
check(AgentSessions.classify("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex sandbox -c shell_environment_policy.inherit=all") == nil,
      "the ChatGPT app's codex sandbox isn't")
check(AgentSessions.classify("claude -p hi") == nil && AgentSessions.classify("claude") == .agent(.claude), "claude -p isn't, claude is")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)

// A tab's status sign goes, a name's own first character stays.
check(tabNameWithoutStatus("✳ SEO AKI") == "SEO AKI", "status sign taken off a name")
check(tabNameWithoutStatus("⠂ MENU") == "MENU", "spinner taken off a name")
check(tabNameWithoutStatus("🐛 Login") == "🐛 Login", "an emoji in a name stays")
check(tabNameWithoutStatus("[API] auth") == "[API] auth", "brackets in a name stay")
