import Foundation
import HerdrKit
import LassoSSH

/// Thrown when the host presents a key different from the pinned one.
public struct HostKeyMismatch: Error, CustomStringConvertible {
    public let expected: String
    public let presented: String
    public var description: String {
        "HerdrHost key changed! Expected \(expected), got \(presented). Refusing to connect."
    }
}

/// SSH link to one host. Owns a request connection (lazy, reconnects once on failure)
/// and opens dedicated connections for event streams and terminals.
public actor HostLink: HerdrTransport {
    public private(set) var host: HerdrHost
    private let keys: KeyStore
    private var conn: SSHConnection?
    private var resolvedSocket: String?
    private var resolvedHome: String?
    private var resolvedBackend: HerdrBackend?
    /// Called once when an unpinned host key gets pinned (TOFU), so callers can persist it.
    private let onPin: @Sendable (HostKey) -> Void
    /// Decides trust for an unpinned host. Default: accept (TOFU) — UI shows the fingerprint first.
    private let firstUse: @Sendable (HostKey) -> Bool

    public init(host: HerdrHost, keys: KeyStore,
                firstUse: @escaping @Sendable (HostKey) -> Bool = { _ in true },
                onPin: @escaping @Sendable (HostKey) -> Void = { _ in })
    {
        self.host = host
        self.keys = keys
        self.firstUse = firstUse
        self.onPin = onPin
    }

    /// Open a fresh SSH connection enforcing the pin.
    public func openConnection() async throws -> SSHConnection {
        let key = try keys.deviceKey()
        let pinned = host.pinnedHostKey
        let firstUse = firstUse
        let seen = HostKeyBox()
        do {
            let c = try await SSHConnection.connect(to: host.target, key: key) { hk in
                seen.set(hk)
                if let pinned { return pinned.blob == hk.blob }
                return firstUse(hk)
            }
            if pinned == nil {
                host.pinnedHostKey = c.hostKey
                onPin(c.hostKey)
            }
            return c
        } catch let SSHError.hostKeyRejected(fp) where pinned != nil {
            throw HostKeyMismatch(expected: pinned!.fingerprint, presented: seen.value?.fingerprint ?? fp)
        }
    }

    private func connection() async throws -> SSHConnection {
        if let conn { return conn }
        let c = try await openConnection()
        conn = c
        return c
    }

    /// `$HOME` on the host.
    public func home() async throws -> String {
        if let resolvedHome { return resolvedHome }
        let r = try await withRetry { try await $0.exec(#"printf %s "$HOME""#) }
        guard r.exitCode == 0, !r.output.isEmpty else { throw SSHError.channel("cannot resolve $HOME") }
        resolvedHome = r.output
        return r.output
    }

    /// Herdr.app (herdr-core) when its socket exists and nothing herdr-specific was configured;
    /// otherwise the herdr TUI. Detected once per link.
    public func backend() async throws -> HerdrBackend {
        if let resolvedBackend { return resolvedBackend }
        var b = HerdrBackend.herdr
        if host.wantsCore {
            b = .core
        } else if !host.pinsHerdrSocket {
            let h = try await home()
            let r = try await withRetry { try await $0.exec("test -S \(shellQuote(HerdrHost.coreSocket(home: h))) && echo core") }
            if r.output.contains("core") { b = .core }
        }
        resolvedBackend = b
        return b
    }

    public func appRequest(_ line: Data) async throws -> Data {
        let path = try await HerdrHost.appSocket(home: home())
        return try await withRetry { try await $0.unixRequest(path: path, line: line) }
    }

    public func socketPath() async throws -> String {
        if let resolvedSocket { return resolvedSocket }
        let p = try await backend() == .core && !host.wantsCore
            ? HerdrHost.coreSocket(home: home())
            : host.socketPath(home: home())
        resolvedSocket = p
        return p
    }

    public func disconnect() {
        conn?.close()
        conn = nil
    }

    // MARK: HerdrTransport

    public func request(_ line: Data) async throws -> Data {
        let path = try await socketPath()
        return try await withRetry { try await $0.unixRequest(path: path, line: line) }
    }

    public nonisolated func stream(_ line: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let path = try await self.socketPath()
                    let c = try await self.openConnection()
                    defer { c.close() }
                    for try await l in c.unixLines(path: path, line: line) {
                        cont.yield(l)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: terminal

    /// Shell prefix so non-login sshd sessions find herdr installed via Homebrew, ~/.local/bin, cargo or mise.
    static let pathPrefix =
        #"export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/share/mise/shims:$PATH"; "#
    static let startMarker = "\u{1B}]lasso-start\u{07}"

    /// Live terminal attached to a pane on a dedicated connection.
    public func attach(pane: String, takeover: Bool, cols: Int, rows: Int) async throws -> PTYChannel {
        if try await backend() == .core {
            let c = try await openConnection()
            // `hc` ships with Herdr.app in ~/.local/bin; ctrl+\ detaches, closing the sheet ends it.
            let cmd = Self.pathPrefix + "printf '\\033]lasso-start\\007'; exec hc attach \(shellQuote(pane))"
            return try await c.pty(command: cmd, cols: cols, rows: rows)
        }
        let c = try await openConnection()
        var cmd = Self.pathPrefix
        if let s = host.session, !s.isEmpty, host.socketPath == nil { cmd += "export HERDR_SESSION=\(shellQuote(s)); " }
        if let p = host.socketPath, !p.isEmpty { try await cmd += "export HERDR_SOCKET_PATH=\(shellQuote(socketPath())); " }
        cmd += "printf '\\033]lasso-start\\007'; exec herdr agent attach \(shellQuote(pane))\(takeover ? " --takeover" : "")"
        return try await c.pty(command: cmd, cols: cols, rows: rows)
    }

    private func withRetry<T: Sendable>(_ op: (SSHConnection) async throws -> T) async throws -> T {
        do { return try await op(connection()) } catch let e as SSHError {
            switch e {
            case .closed, .io, .channel, .connect:
                disconnect()
                return try await op(connection())
            default: throw e
            }
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

final class HostKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: HostKey?
    func set(_ k: HostKey) { lock.withLock { v = k } }
    var value: HostKey? { lock.withLock { v } }
}
