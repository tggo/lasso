import Foundation
import Testing
@testable import HerdrKit

@Test func requestIsOneNDJSONLine() throws {
    let line = try HerdrRequest(id: "req_1", method: "ping").line()
    #expect(String(decoding: line, as: UTF8.self) == #"{"id":"req_1","method":"ping","params":{}}"# + "\n")
}

@Test func decodesResult() throws {
    let msg = try HerdrMessage.decode(line: Data(#"{"id":"req_1","result":{"type":"pong","extra":1}}"#.utf8))
    guard case let .result(id, value) = msg else { Issue.record("not a result"); return }
    #expect(id == "req_1")
    #expect(value["type"]?.stringValue == "pong")
}

@Test func decodesErrorWithEmptyId() throws {
    let msg = try HerdrMessage.decode(line: Data(#"{"id":"","error":{"code":"invalid_request","message":"bad json"}}"#.utf8))
    #expect(msg == .failure(id: "", HerdrError(code: "invalid_request", message: "bad json")))
}

@Test func decodesEvent() throws {
    let msg = try HerdrMessage.decode(line: Data(#"{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","status":"blocked"}}"#.utf8))
    guard case let .event(name, data) = msg else { Issue.record("not an event"); return }
    #expect(name == "pane_agent_status_changed")
    #expect(data["status"]?.stringValue == "blocked")
}
