import Foundation

/// Which herdr a host runs.
/// - `herdr`: the herdr TUI multiplexer (`~/.config/herdr/herdr.sock`, NDJSON `{id,method,params}`).
/// - `core`: Herdr.app from herdr.dev. Its terminal runtime `herdr-core` speaks JSON-RPC 2.0 on
///   `~/.local/state/herdr-core/default/default.sock`; spaces and tabs live in the desktop app
///   (`~/.config/herdr-app/herdr-app.sock`, `{"ls":{}}` / `{"do":cmd,"args":{}}`).
public enum HerdrBackend: String, Sendable, Codable { case herdr, core }

/// Pure codec and mapping for herdr-core. No I/O, so it is unit-tested against captured replies.
public enum Core {
    public static func request(id: Int, method: String, params: JSONValue = .object([:])) throws -> Data {
        let v: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                    "method": .string(method), "params": params])
        return try line(v)
    }

    static func line(_ v: JSONValue) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var d = try e.encode(v)
        d.append(0x0A)
        return d
    }

    /// `result` of a JSON-RPC reply, or the error as `HerdrClientError.server`.
    public static func result(_ line: Data) throws -> JSONValue {
        let v = try JSONDecoder().decode(JSONValue.self, from: line)
        if let r = v["result"] { return r }
        if let e = v["error"] {
            let kind = e["data"]?["kind"]?.stringValue ?? e["code"].map { "\($0)" } ?? "error"
            var msg = e["message"]?.stringValue ?? "error"
            if let hint = e["data"]?["hint"]?.stringValue { msg += " (\(hint))" }
            throw HerdrClientError.server(HerdrError(code: kind, message: msg))
        }
        throw HerdrClientError.unexpected(String(decoding: line, as: UTF8.self))
    }

    /// Request line for the desktop app socket.
    public static func appCommand(_ name: String, _ args: [String: JSONValue]) throws -> Data {
        try line(.object(["do": .string(name), "args": .object(args)]))
    }

    public static func appResult(_ line: Data) throws -> JSONValue {
        let v = try JSONDecoder().decode(JSONValue.self, from: line)
        if let e = v["error"]?.stringValue { throw HerdrClientError.server(HerdrError(code: "app", message: e)) }
        return v
    }

    /// herdr-core status word → Lasso status. `error` needs a person, so it ranks with blocked.
    public static func status(_ word: String?) -> AgentStatus {
        switch word {
        case "blocked", "error": .blocked
        case "working": .working
        case "done": .done
        case "idle": .idle
        default: .unknown
        }
    }

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Build a Lasso snapshot from `terminal.list` and (optionally) the app's `ls`.
    /// Without the app, terminals are grouped by their `herdr.space` label, else into one "Terminals" space.
    public static func snapshot(terminals: [JSONValue], spaces: JSONValue?, version: String, generation: Int) -> Snapshot {
        struct T { let id, space, tab: String; let v: JSONValue }
        let live = terminals.filter { $0["state"]?.stringValue != "finished" }
        let ts: [T] = live.compactMap { t in
            guard let id = t["address"]?.stringValue else { return nil }
            let space = t["labels"]?["herdr.space"]?.stringValue ?? "_"
            let tab = t["labels"]?["herdr.tab"]?.stringValue ?? "\(space)/_"
            return T(id: id, space: space, tab: tab, v: t)
        }
        let statusOf = Dictionary(ts.map { ($0.id, status($0.v["status"]?["state"]?.stringValue)) }, uniquingKeysWith: { a, _ in a })

        var workspaces: [Workspace] = []
        var tabs: [Tab] = []
        var known = Set<String>()
        if case let .array(list)? = spaces?["spaces"] {
            for (i, s) in list.enumerated() {
                guard let sid = s["id"]?.stringValue else { continue }
                known.insert(sid)
                var tabList: [JSONValue] = []
                if case let .array(tl)? = s["tabs"] { tabList = tl }
                for (j, t) in tabList.enumerated() {
                    guard let tid = t["id"]?.stringValue else { continue }
                    let st = ts.filter { $0.tab == tid }.map { statusOf[$0.id] ?? .unknown }.min() ?? .unknown
                    tabs.append(Tab(tabId: tid, workspaceId: sid, number: j + 1, label: t["name"]?.stringValue ?? "\(j + 1)",
                                    focused: t["active"]?.boolValue ?? false, agentStatus: st))
                }
                let st = ts.filter { $0.space == sid }.map { statusOf[$0.id] ?? .unknown }.min() ?? .unknown
                workspaces.append(Workspace(workspaceId: sid, number: i + 1, label: s["name"]?.stringValue ?? "Space \(i + 1)",
                                            focused: s["active"]?.boolValue ?? false, activeTabId: nil, agentStatus: st))
            }
        }
        // Terminals the app does not list (app closed, or started with `hc run`).
        let orphans = ts.filter { !known.contains($0.space) }
        for space in Set(orphans.map(\.space)).sorted() {
            let group = orphans.filter { $0.space == space }
            let label = space == "_" ? "Terminals"
                : group.first?.v["labels"]?["where"]?.stringValue?.components(separatedBy: " / ").first ?? space
            let st = group.map { statusOf[$0.id] ?? .unknown }.min() ?? .unknown
            workspaces.append(Workspace(workspaceId: space, number: workspaces.count + 1, label: label, focused: false,
                                        activeTabId: nil, agentStatus: st))
            for tab in Set(group.map(\.tab)).sorted() {
                tabs.append(Tab(tabId: tab, workspaceId: space, number: tabs.count + 1, label: "1", focused: false,
                                agentStatus: group.filter { $0.tab == tab }.map { statusOf[$0.id] ?? .unknown }.min() ?? .unknown))
            }
        }

        var panes: [Pane] = []
        var agents: [Agent] = []
        for t in ts {
            let st = statusOf[t.id] ?? .unknown
            let app = t.v["status"]?["app"]?.stringValue
            let cwd = t.v["foreground"]?["cwd"]?.stringValue ?? t.v["cwd"]?.stringValue
            let title = t.v["title"]?.stringValue
            let name = t.v["name"]?.stringValue
            panes.append(Pane(paneId: t.id, workspaceId: t.space, tabId: t.tab, focused: false, agentStatus: st,
                              agent: app, cwd: cwd, label: name ?? title, title: title))
            // An agent is a terminal whose program reports status (OSC 7501).
            if t.v["status"] != nil, t.v["status"] != .null {
                agents.append(Agent(paneId: t.id, workspaceId: t.space, tabId: t.tab, agentStatus: st, agent: app,
                                    displayAgent: app.map(prettyApp), name: name ?? title, cwd: cwd, title: title, focused: false,
                                    pid: t.v["foreground"]?["pid"]?.intValue))
            }
        }
        return Snapshot(version: version, protocol: generation, workspaces: workspaces, tabs: tabs, panes: panes, agents: agents)
    }

    // swiftlint:enable function_body_length cyclomatic_complexity

    static func prettyApp(_ s: String) -> String {
        switch s {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        case "opencode": "opencode"
        default: s
        }
    }
}
