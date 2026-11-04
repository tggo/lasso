import Foundation
@testable import HerdrKit
import Testing

/// Transport that replies from a closure — lets tests assert on the exact request line.
struct FakeTransport: HerdrTransport {
    let reply: @Sendable (JSONValue) -> String
    func request(_ line: Data) async throws -> Data {
        let req = try JSONDecoder().decode(JSONValue.self, from: line)
        return Data(reply(req).utf8)
    }

    func stream(_: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { c in
            c.yield(Data(#"{"id":"lasso_events","result":{"type":"subscription_started"}}"#.utf8))
            c.yield(Data(#"{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"blocked","new_field":1}}"#.utf8))
            c.finish()
        }
    }
}

let snapshotJSON = #"""
{"id":"x","result":{"type":"session_snapshot","snapshot":{"version":"0.9.5","protocol":22,
"workspaces":[{"workspace_id":"w1","number":1,"label":"api","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"blocked","future":"x"}],
"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,"pane_count":2,"agent_status":"blocked"}],
"panes":[{"pane_id":"w1:p1","terminal_id":"t","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"blocked","agent":"claude","revision":3}],
"layouts":[],
"agents":[{"pane_id":"w1:p1","terminal_id":"t","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent_status":"blocked","agent":"claude","display_agent":"Claude Code","revision":3},
          {"pane_id":"w1:p2","terminal_id":"u","workspace_id":"w1","tab_id":"w1:t1","focused":false,"agent_status":"telepathic","revision":1}]}}}
"""#

@Test func decodesSnapshotLeniently() async throws {
    let c = HerdrClient(transport: FakeTransport { _ in snapshotJSON })
    let s = try await c.snapshot()
    #expect(s.workspaces.first?.label == "api")
    #expect(s.agents.count == 2)
    #expect(s.agents[0].displayName == "Claude Code")
    #expect(s.agents[1].agentStatus == .unknown) // unknown future status
}

@Test func serverErrorSurfaces() async throws {
    let c = HerdrClient(transport: FakeTransport { _ in #"{"id":"x","error":{"code":"agent_not_found","message":"nope"}}"# })
    await #expect(throws: HerdrClientError.server(HerdrError(code: "agent_not_found", message: "nope"))) {
        try await c.prompt("w1:p9", text: "hi", isAgent: true)
    }
}

@Test func sendKeysUsesPaneSendInput() async throws {
    let seen = Box()
    let c = HerdrClient(transport: FakeTransport { req in seen.set(req); return #"{"id":"x","result":{"type":"ok"}}"# })
    try await c.sendKeys("w1:p1", ["ctrl+c"])
    #expect(seen.value?["method"]?.stringValue == "pane.send_input")
    #expect(seen.value?["params"]?["keys"] == .array([.string("ctrl+c")]))
}

@Test func eventsStreamMarksAckAndDecodes() async throws {
    let c = HerdrClient(transport: FakeTransport { _ in "" })
    var got: [HerdrEvent] = []
    for try await e in c.events(statusOf: ["w1:p1"]) {
        got.append(e)
    }
    #expect(got.map(\.name).first == "lasso.subscribed") // ack: re-snapshot point
    #expect(got.count == 2)
    #expect(got[1].paneId == "w1:p1")
    #expect(got[1].status == .blocked)
}

@Test func statusOrderPutsBlockedFirst() {
    #expect([AgentStatus.idle, .working, .blocked, .done].sorted() == [.blocked, .working, .done, .idle])
}

final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var v: JSONValue?
    func set(_ x: JSONValue) { lock.withLock { v = x } }
    var value: JSONValue? { lock.withLock { v } }
}
