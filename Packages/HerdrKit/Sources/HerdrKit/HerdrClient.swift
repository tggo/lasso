import Foundation

/// Carries NDJSON lines to a herdr socket. One request per call; `stream` holds its
/// channel open for `events.subscribe`.
public protocol HerdrTransport: Sendable {
    func request(_ line: Data) async throws -> Data
    func stream(_ line: Data) -> AsyncThrowingStream<Data, Error>
}

public enum HerdrClientError: Error, Equatable, CustomStringConvertible {
    case server(HerdrError)
    case unexpected(String)

    public var description: String {
        switch self {
        case let .server(e): "herdr: \(e.message) (\(e.code))"
        case let .unexpected(s): "Unexpected herdr reply: \(s)"
        }
    }
}

/// Typed herdr API over any transport.
public struct HerdrClient: Sendable {
    public let transport: HerdrTransport
    private let ids = Counter()

    public init(transport: HerdrTransport) { self.transport = transport }

    // MARK: raw

    public func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = "lasso_\(ids.next())"
        let reply = try await transport.request(HerdrRequest(id: id, method: method, params: params).line())
        switch try HerdrMessage.decode(line: reply) {
        case let .result(_, value): return value
        case let .failure(_, e): throw HerdrClientError.server(e)
        case let .event(name, _): throw HerdrClientError.unexpected("event \(name)")
        }
    }

    // MARK: session

    public func ping() async throws -> PongInfo { try await call("ping").decode(PongInfo.self) }

    public func snapshot() async throws -> Snapshot {
        let r = try await call("session.snapshot")
        guard let snap = r["snapshot"] else { throw HerdrClientError.unexpected("no snapshot") }
        return try snap.decode(Snapshot.self)
    }

    // MARK: agents

    /// Works for any pane (agent or plain shell).
    public func read(_ target: String, source: ReadSource = .recent, lines: Int? = 200, ansi: Bool = false) async throws -> ReadResult {
        var p: [String: JSONValue] = ["pane_id": .string(target), "source": .string(source.rawValue),
                                      "format": .string(ansi ? "ansi" : "text"), "strip_ansi": .bool(!ansi)]
        if let lines { p["lines"] = .number(Double(lines)) }
        let r = try await call("pane.read", .object(p))
        return try (r["read"] ?? r).decode(ReadResult.self)
    }

    /// Agent panes get `agent.prompt` (herdr submits it properly); plain panes get text + enter.
    public func prompt(_ target: String, text: String, isAgent: Bool) async throws {
        if isAgent {
            _ = try await call("agent.prompt", .object(["target": .string(target), "text": .string(text)]))
        } else {
            _ = try await call("pane.send_input", .object(["pane_id": .string(target), "text": .string(text), "keys": .array([.string("enter")])]))
        }
    }

    /// Keys use herdr names: `enter`, `esc`, `ctrl+c`, `tab`, `shift+tab`, `up`, `down`, ...
    public func sendKeys(_ target: String, _ keys: [String]) async throws {
        _ = try await call("pane.send_input", .object(["pane_id": .string(target), "keys": .array(keys.map(JSONValue.string))]))
    }

    public func sendText(pane: String, _ text: String) async throws {
        _ = try await call("pane.send_input", .object(["pane_id": .string(pane), "text": .string(text)]))
    }

    public func startAgent(kind: String, name: String, pane: String) async throws {
        _ = try await call("agent.start", .object(["kind": .string(kind), "name": .string(name), "pane_id": .string(pane)]))
    }

    public func renameAgent(_ target: String, to name: String) async throws {
        _ = try await call("agent.rename", .object(["target": .string(target), "name": .string(name)]))
    }

    // MARK: workspaces / tabs

    @discardableResult
    public func createWorkspace(label: String?, cwd: String? = nil) async throws -> JSONValue {
        var p: [String: JSONValue] = [:]
        if let label { p["label"] = .string(label) }
        if let cwd { p["cwd"] = .string(cwd) }
        return try await call("workspace.create", .object(p))
    }

    public func renameWorkspace(_ id: String, to label: String) async throws {
        _ = try await call("workspace.rename", .object(["workspace_id": .string(id), "label": .string(label)]))
    }

    public func closeWorkspace(_ id: String) async throws {
        _ = try await call("workspace.close", .object(["workspace_id": .string(id)]))
    }

    @discardableResult
    public func createTab(workspace: String, label: String?) async throws -> JSONValue {
        var p: [String: JSONValue] = ["workspace_id": .string(workspace)]
        if let label { p["label"] = .string(label) }
        return try await call("tab.create", .object(p))
    }

    public func renameTab(_ id: String, to label: String) async throws {
        _ = try await call("tab.rename", .object(["tab_id": .string(id), "label": .string(label)]))
    }

    public func closeTab(_ id: String) async throws {
        _ = try await call("tab.close", .object(["tab_id": .string(id)]))
    }

    // MARK: events

    /// Global lifecycle kinds that need no pane id.
    public static let lifecycleSubscriptions = [
        "workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed",
        "tab.created", "tab.closed", "tab.renamed",
        "pane.created", "pane.closed", "pane.updated", "pane.exited", "pane.agent_detected",
    ]

    /// Subscribe to lifecycle events plus status changes of the given panes.
    public func events(statusOf panes: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
        let subs: [JSONValue] = Self.lifecycleSubscriptions.map { .object(["type": .string($0)]) }
            + panes.map { .object(["type": .string("pane.agent_status_changed"), "pane_id": .string($0)]) }
        let line: Data
        do {
            line = try HerdrRequest(id: "lasso_events", method: "events.subscribe",
                                    params: .object(["subscriptions": .array(subs)])).line()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let raw = transport.stream(line)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await l in raw {
                        switch try? HerdrMessage.decode(line: l) {
                        case let .event(name, data): cont.yield(HerdrEvent(name: name, data: data))
                        case let .failure(_, e): throw HerdrClientError.server(e)
                        default: continue // subscribe ack and unknown lines
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
