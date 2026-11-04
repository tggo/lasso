import Foundation
@testable import HerdrKit
import Testing

private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

/// Shapes captured from herdr-core 0.1.15 / herdr-app 0.1.10, with made-up names.
private let terminals = """
[{"address":"t1","state":"live","cwd":"/home/u","labels":{"herdr.space":"spA","herdr.tab":"tbA1","where":"api / 1"},
  "foreground":{"argv":["claude"],"cwd":"/home/u/api","name":"2.1","pid":1},"title":"Fix login","name":null,
  "status":{"app":"claude-code","state":"blocked","kind":"permission"}},
 {"address":"t2","state":"live","cwd":"/home/u","labels":{"herdr.space":"spA","herdr.tab":"tbA2"},
  "foreground":{"argv":["zsh"],"cwd":"/home/u","name":"zsh","pid":2},"title":null,"name":null,"status":null},
 {"address":"t3","state":"live","cwd":"/srv","labels":{},"title":"x","status":{"app":"codex","state":"working"}},
 {"address":"t4","state":"finished","labels":{},"status":null}]
"""
private let spaces = """
{"spaces":[{"id":"spA","name":"api","active":true,"tabs":[{"id":"tbA1","name":"1","active":true},{"id":"tbA2","name":"2","active":false}]}]}
"""

@Test func coreSnapshotMapsSpacesTabsAndAgents() throws {
    guard case let .array(ts) = try json(terminals) else { Issue.record("fixture"); return }
    let s = Core.snapshot(terminals: ts, spaces: try json(spaces), version: "core", generation: 1)
    #expect(s.workspaces.map(\.label) == ["api", "Terminals"])
    #expect(s.workspaces[0].agentStatus == .blocked)
    #expect(s.tabs.filter { $0.workspaceId == "spA" }.map(\.label) == ["1", "2"])
    #expect(s.panes.map(\.paneId) == ["t1", "t2", "t3"]) // finished t4 dropped
    #expect(s.agents.map(\.paneId) == ["t1", "t3"]) // t2 is a plain shell
    let a = try #require(s.agents.first)
    #expect(a.displayName == "Fix login")
    #expect(a.displayAgent == "Claude Code")
    #expect(a.cwd == "/home/u/api")
}

@Test func coreSnapshotWithoutAppGroupsByLabel() throws {
    guard case let .array(ts) = try json(terminals) else { return }
    let s = Core.snapshot(terminals: ts, spaces: nil, version: "core", generation: 1)
    #expect(Set(s.workspaces.map(\.label)) == ["api", "Terminals"])
}

@Test func coreStatusWords() {
    #expect(Core.status("error") == .blocked)
    #expect(Core.status("done") == .done)
    #expect(Core.status("someday") == .unknown)
    #expect(Core.status(nil) == .unknown)
}

@Test func coreErrorsCarryKindAndHint() throws {
    let line = Data(#"{"error":{"code":-32000,"data":{"hint":"see `hc ls --all`","kind":"not_found"},"message":"no terminal \"x\""},"id":4,"jsonrpc":"2.0"}"#.utf8)
    #expect(throws: HerdrClientError.server(HerdrError(code: "not_found", message: #"no terminal "x" (see `hc ls --all`)"#))) {
        try Core.result(line)
    }
    #expect(throws: HerdrClientError.self) { try Core.appResult(Data(#"{"error":"no space"}"#.utf8)) }
}

@Test func coreRequestIsJSONRPC() throws {
    let l = try Core.request(id: 7, method: "terminal.list")
    #expect(String(decoding: l, as: UTF8.self) == #"{"id":7,"jsonrpc":"2.0","method":"terminal.list","params":{}}"# + "\n")
}
