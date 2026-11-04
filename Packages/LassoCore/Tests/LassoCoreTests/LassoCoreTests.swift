import Foundation
import HerdrKit
@testable import LassoCore
import LassoSSH
import Testing

@Test func socketPathResolution() {
    let t = SSHTarget(host: "h", user: "u")
    #expect(HerdrHost(name: "a", target: t).socketPath(home: "/home/u") == "/home/u/.config/herdr/herdr.sock")
    #expect(HerdrHost(name: "a", target: t, session: "work").socketPath(home: "/h") == "/h/.config/herdr/sessions/work/herdr.sock")
    #expect(HerdrHost(name: "a", target: t, socketPath: "~/x.sock").socketPath(home: "/h") == "/h/x.sock")
}

@Test func hostRepositoryRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-\(UUID())")
    let repo = HostRepository(directory: dir)
    let h = HerdrHost(name: "mac", target: SSHTarget(host: "10.0.0.2", user: "me"), session: "s")
    try repo.save([h])
    #expect(repo.load() == [h])
}

@Test func shellQuoteEscapes() { #expect(shellQuote("a'b") == #"'a'\''b'"#) }

// MARK: integration (make test-integration)

enum IT {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["LASSO_IT_HOST"] != nil }
    static func host(pinned: HostKey? = nil) -> HerdrHost {
        HerdrHost(name: "it", target: SSHTarget(host: env["LASSO_IT_HOST"]!, port: Int(env["LASSO_IT_PORT"]!)!, user: env["LASSO_IT_USER"]!),
                  socketPath: env["LASSO_IT_SOCK"]!, pinnedHostKey: pinned)
    }

    static func keys() throws -> KeyStore {
        try MemoryKeyStore(key: SSHKey(openSSHPEM: String(contentsOfFile: env["LASSO_IT_KEY"]!, encoding: .utf8)))
    }
}

@Suite(.enabled(if: IT.enabled), .serialized) struct CoreIntegration {
    @Test func tofuPinsThenMismatchRefuses() async throws {
        let pinned = PinBox()
        let link = try HostLink(host: IT.host(), keys: IT.keys(), onPin: { pinned.set($0) })
        _ = try await HerdrClient(transport: link).ping()
        let key = try #require(pinned.value)

        let bogus = HostKey(type: "ssh-ed25519", blob: Data(repeating: 7, count: 51))
        let bad = try HostLink(host: IT.host(pinned: bogus), keys: IT.keys())
        await #expect(throws: HostKeyMismatch.self) { _ = try await HerdrClient(transport: bad).ping() }

        let good = try HostLink(host: IT.host(pinned: key), keys: IT.keys())
        #expect(try await HerdrClient(transport: good).ping().version.isEmpty == false)
    }

    @Test @MainActor func storeSeesWorkspaceAndAgentStatusLive() async throws {
        let link = try HostLink(host: IT.host(), keys: IT.keys())
        let store = SessionStore(hostID: UUID(), transport: link)
        var changes: [(String, AgentStatus)] = []
        store.onStatusChange = { a, _ in changes.append((a.paneId, a.agentStatus)) }
        store.start()
        defer { store.stop() }
        try await waitUntil { store.phase == .live }

        let label = "it-\(Int.random(in: 1000 ... 9999))"
        let created = try await store.client.createWorkspace(label: label)
        let ws = try #require(created["workspace"]?["workspace_id"]?.stringValue)
        let pane = try #require(created["root_pane"]?["pane_id"]?.stringValue)
        try await waitUntil { store.snapshot.workspaces.contains { $0.label == label } }

        // Pretend an agent runs in the pane and becomes blocked.
        _ = try await store.client.call("pane.report_agent", .object([
            "pane_id": .string(pane), "source": .string("lasso-it"), "agent": .string("claude"), "state": .string("working"),
        ]))
        try await waitUntil { store.agent(pane)?.agentStatus == .working }
        _ = try await store.client.call("pane.report_agent", .object([
            "pane_id": .string(pane), "source": .string("lasso-it"), "agent": .string("claude"), "state": .string("blocked"),
        ]))
        let t0 = Date()
        try await waitUntil { store.agent(pane)?.agentStatus == .blocked }
        #expect(Date().timeIntervalSince(t0) < 2) // CAP-2: within 2 s
        #expect(store.agentsByAttention.prefix { $0.agentStatus == .blocked }.contains { $0.paneId == pane })
        #expect(changes.contains { $0 == (pane, .blocked) })

        try await store.client.sendText(pane: pane, "echo lasso-marker\n")
        try await waitUntilAsync { await (try? store.client.read(pane, lines: 50).text.contains("lasso-marker")) == true }

        try await store.client.closeWorkspace(ws)
        try await waitUntil { !store.snapshot.workspaces.contains { $0.workspaceId == ws } }
    }

    @Test func attachStreamsTerminal() async throws {
        let link = try HostLink(host: IT.host(), keys: IT.keys())
        let c = HerdrClient(transport: link)
        let created = try await c.createWorkspace(label: "it-attach")
        let pane = try #require(created["root_pane"]?["pane_id"]?.stringValue)
        let ws = try #require(created["workspace"]?["workspace_id"]?.stringValue)
        _ = try await c.call("pane.report_agent", .object([
            "pane_id": .string(pane), "source": .string("lasso-it"), "agent": .string("claude"), "state": .string("idle"),
        ]))
        let pty = try await link.attach(pane: pane, takeover: true, cols: 80, rows: 24)
        let out = Bytes()
        pty.start(output: { out.append($0) }, exit: { _ in })
        try await Task.sleep(for: .milliseconds(800))
        pty.write(Data("echo attach-ok\r".utf8))
        for _ in 0 ..< 60 where !out.text.contains("attach-ok") {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(out.text.contains("attach-ok"))
        pty.close()
        try await c.closeWorkspace(ws)
    }
}

@MainActor func waitUntil(timeout: Double = 5, _ cond: @MainActor () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        guard Date() < end else { Issue.record("timed out"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor func waitUntilAsync(timeout: Double = 5, _ cond: @MainActor () async -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while await !cond() {
        guard Date() < end else { Issue.record("timed out"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(100))
    }
}

final class PinBox: @unchecked Sendable {
    private let l = NSLock(); private var v: HostKey?
    func set(_ k: HostKey) { l.withLock { v = k } }
    var value: HostKey? { l.withLock { v } }
}

final class Bytes: @unchecked Sendable {
    private let l = NSLock(); private var d = Data()
    func append(_ x: Data) { l.withLock { d.append(x) } }
    var text: String { l.withLock { String(decoding: d, as: UTF8.self) } }
}

/// Herdr.app (herdr-core) over real SSH. Runs only where Herdr.app's core is running for the
/// integration user (developer machines); CI has no Herdr.app and skips it.
@Suite(.serialized, .enabled(if: IT.enabled && FileManager.default.fileExists(
    atPath: NSHomeDirectory() + "/.local/state/herdr-core/default/default.sock")))
struct HerdrAppIntegration {
    static func host() -> HerdrHost {
        let e = ProcessInfo.processInfo.environment
        return HerdrHost(name: "core", target: SSHTarget(host: e["LASSO_IT_HOST"]!, port: Int(e["LASSO_IT_PORT"]!)!, user: e["LASSO_IT_USER"]!))
    }

    /// A throwaway terminal that reports working, then blocked, then waits for an answer.
    static let fakeAgent = #"printf '\033]7501;state=working:app=lasso-it\007'; sleep 1; "#
        + #"printf '\033]7501;state=blocked:app=lasso-it\007'; read x; echo "got-$x"; sleep 20"#

    @Test @MainActor func detectsCoreAndFollowsBlockedAgent() async throws {
        let link = try HostLink(host: Self.host(), keys: IT.keys())
        #expect(try await link.backend() == .core)
        let store = SessionStore(hostID: UUID(), transport: link)
        store.start()
        defer { store.stop() }
        try await waitUntil { store.phase == .live }

        let run = try await store.client.coreCall("terminal.run", [
            "argv": .array(["sh", "-c", Self.fakeAgent].map(JSONValue.string)),
            "labels": .object(["lasso": .string("it")]), "rm": .bool(true),
        ])
        let t = try #require(run["address"]?.stringValue)
        defer { Task { _ = try? await HerdrClient(transport: link).coreCall("terminal.kill", ["terminal": .string(t)]) } }

        try await waitUntil { store.agent(t)?.agentStatus == .working }
        let t0 = Date()
        try await waitUntil { store.agent(t)?.agentStatus == .blocked }
        #expect(Date().timeIntervalSince(t0) < 2.5) // 1 s scripted gap + delivery
        #expect(store.agentsByAttention.first?.agentStatus == .blocked)

        try await store.client.prompt(t, text: "yes", isAgent: true)
        try await waitUntilAsync(timeout: 10) { await (try? store.client.read(t, lines: 20).text.contains("got-yes")) == true }
    }

    @Test func readsClaudeTranscriptOfARunningSession() async throws {
        let link = try HostLink(host: Self.host(), keys: IT.keys())
        let snap = try await HerdrClient(transport: link).snapshot()
        guard let pid = snap.agents.first(where: { $0.agent == "claude-code" && $0.pid != nil })?.pid else { return }
        var t = ClaudeTranscript()
        var cur = TranscriptCursor()
        #expect(try await link.readTranscript(pid: pid, into: &t, cursor: &cur))
        #expect(!t.items.isEmpty)
        let before = cur.offset, n = t.items.count
        _ = try await link.readTranscript(pid: pid, into: &t, cursor: &cur) // incremental: no re-read
        print("TRANSCRIPT items", n, "->", t.items.count, "offset", before, "->", cur.offset)
        #expect(cur.offset >= before)
        #expect(t.items.count >= min(n, t.maxItems)) // incremental read keeps history
    }

    @Test func attachesWithHc() async throws {
        let link = try HostLink(host: Self.host(), keys: IT.keys())
        let c = HerdrClient(transport: link)
        let run = try await c.coreCall("terminal.run", ["argv": .array([.string("sh")]), "labels": .object(["lasso": .string("it")])])
        let t = try #require(run["address"]?.stringValue)
        let pty = try await link.attach(pane: t, takeover: true, cols: 80, rows: 24)
        let out = Bytes()
        pty.start(output: { out.append($0) }, exit: { _ in })
        try await Task.sleep(for: .milliseconds(800))
        pty.write(Data("echo attach-ok\r".utf8))
        for _ in 0 ..< 60 where !out.text.contains("attach-ok") {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(out.text.contains("attach-ok"))
        pty.close()
        _ = try await c.coreCall("terminal.kill", ["terminal": .string(t)])
        _ = try? await c.coreCall("terminal.rm", ["terminal": .string(t)])
    }
}

@Test func transcriptBuildsChatIncrementally() {
    let l1 = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"fix the login"}}"#
    // swiftlint:disable:next line_length
    let l2 = #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"make test\nmore","description":"Run tests"}}]}}"#
    let l3 = #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok","is_error":false}]}}"#
    let meta = #"{"type":"user","uuid":"m","isMeta":true,"message":{"role":"user","content":"hidden"}}"#
    let side = #"{"type":"assistant","uuid":"s","isSidechain":true,"message":{"role":"assistant","content":"sub"}}"#
    let all = [l1, l2, meta, side, l3].joined(separator: "\n") + "\n"
    var t = ClaudeTranscript()
    let bytes = Data(all.utf8)
    // Split mid-line: the second half completes it.
    t.feed(bytes.prefix(50))
    #expect(t.items.isEmpty)
    t.feed(bytes.dropFirst(50))
    #expect(t.items == [
        .user(id: "u1", text: "fix the login"),
        .assistant(id: "a1#1", text: "Looking."),
        .tool(id: "tu1", name: "Bash", summary: "Run tests", result: "ok", isError: false),
    ])
}

@Test func transcriptSkipsPartialFirstLineAndTags() {
    var t = ClaudeTranscript()
    let data = Data(("tail of a cut line}\n" + #"{"type":"user","uuid":"u","message":{"content":"<command-name>/clear</command-name>"}}"# + "\n"
        + #"{"type":"user","uuid":"v","message":{"content":"real"}}"# + "\n").utf8)
    t.feed(data, dropFirstLine: true)
    #expect(t.items == [.user(id: "v", text: "real")])
}
