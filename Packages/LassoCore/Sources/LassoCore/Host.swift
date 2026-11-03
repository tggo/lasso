import Foundation
import LassoSSH

/// A machine running herdr, as the user configured it. Contains no secrets.
public struct HerdrHost: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var target: SSHTarget
    /// Named herdr session (`herdr --session <name>`); nil = default session.
    public var session: String?
    /// Explicit socket path; overrides `session` and the default location.
    public var socketPath: String?
    /// Pinned on first successful connection (TOFU). A mismatch refuses to connect.
    public var pinnedHostKey: HostKey?

    public init(id: UUID = UUID(), name: String, target: SSHTarget, session: String? = nil,
                socketPath: String? = nil, pinnedHostKey: HostKey? = nil) {
        self.id = id
        self.name = name
        self.target = target
        self.session = session
        self.socketPath = socketPath
        self.pinnedHostKey = pinnedHostKey
    }

    /// Socket path relative to `$HOME`, resolved on the host (sshd does not expand `~`).
    func socketPath(home: String) -> String {
        if let socketPath, !socketPath.isEmpty {
            return socketPath.hasPrefix("~/") ? home + socketPath.dropFirst(1) : socketPath
        }
        if let session, !session.isEmpty { return "\(home)/.config/herdr/sessions/\(session)/herdr.sock" }
        return "\(home)/.config/herdr/herdr.sock"
    }
}

/// Persists hosts as JSON in Application Support with complete file protection, excluded from backup.
public final class HostRepository: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hosts.json")
    }

    public func load() -> [HerdrHost] {
        lock.withLock {
            guard let d = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([HerdrHost].self, from: d)) ?? []
        }
    }

    public func save(_ hosts: [HerdrHost]) throws {
        try lock.withLock {
            let d = try JSONEncoder().encode(hosts)
            #if os(iOS)
                try d.write(to: url, options: [.atomic, .completeFileProtection])
            #else
                try d.write(to: url, options: .atomic)
            #endif
            var u = url
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? u.setResourceValues(rv)
        }
    }
}
