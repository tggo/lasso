import Foundation

/// Agent status as herdr reports it. Unknown future values decode to `.unknown`.
public enum AgentStatus: String, Sendable, Codable, CaseIterable, Comparable {
    case blocked, working, done, idle, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Attention order: blocked first, then working, done, idle, unknown.
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct Workspace: Sendable, Codable, Identifiable, Equatable {
    public let workspaceId: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let activeTabId: String?
    public let agentStatus: AgentStatus
    public var id: String { workspaceId }
}

public struct Tab: Sendable, Codable, Identifiable, Equatable {
    public let tabId: String
    public let workspaceId: String
    public let number: Int
    public let label: String
    public let focused: Bool
    public let agentStatus: AgentStatus
    public var id: String { tabId }
}

public struct Pane: Sendable, Codable, Identifiable, Equatable {
    public let paneId: String
    public let workspaceId: String
    public let tabId: String
    public let focused: Bool
    public let agentStatus: AgentStatus
    public let agent: String?
    public let cwd: String?
    public let label: String?
    public let title: String?
    public var id: String { paneId }
}

public struct Agent: Sendable, Codable, Identifiable, Equatable {
    public let paneId: String
    public let workspaceId: String
    public let tabId: String
    public let agentStatus: AgentStatus
    public let agent: String?
    public let displayAgent: String?
    public let name: String?
    public let cwd: String?
    public let title: String?
    public let focused: Bool
    /// Process id of the agent (Herdr.app reports the terminal's foreground process).
    public var pid: Int?
    public var id: String { paneId }

    /// Best human label: explicit name, then detected agent, then pane id.
    public var displayName: String { name ?? displayAgent ?? agent ?? paneId }
}

public struct Snapshot: Sendable, Codable, Equatable {
    public let version: String
    public let `protocol`: Int
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]
    public let agents: [Agent]

    public static let empty = Snapshot(version: "", protocol: 0, workspaces: [], tabs: [], panes: [], agents: [])
}

public struct ReadResult: Sendable, Codable, Equatable {
    public let paneId: String
    public let text: String
    public let revision: Int
    public let truncated: Bool
}

public struct PongInfo: Sendable, Codable, Equatable {
    public let version: String
    public let `protocol`: Int
}

public enum ReadSource: String, Sendable { case visible, recent, recentUnwrapped = "recent_unwrapped", detection }

/// A streamed herdr event, kept schema-free apart from its kind and pane/workspace ids.
public struct HerdrEvent: Sendable, Equatable {
    public let name: String
    public let data: JSONValue
    public var paneId: String? { data["pane_id"]?.stringValue ?? data["pane"]?["pane_id"]?.stringValue }
    public var status: AgentStatus? { data["agent_status"]?.stringValue.flatMap(AgentStatus.init(rawValue:)) }
}

extension JSONDecoder {
    static let herdr: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension JSONValue {
    func decode<T: Decodable>(_: T.Type) throws -> T {
        try JSONDecoder.herdr.decode(T.self, from: JSONEncoder().encode(self))
    }
}
