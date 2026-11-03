import CLibSSH2
import Darwin
import Foundation

public struct SSHTarget: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int
    public var user: String
    public init(host: String, port: Int = 22, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }
}

public struct ExecResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public var output: String { String(decoding: stdout, as: UTF8.self) }
}

private let libssh2Ready: Bool = { libssh2_init(0) == 0 }()

private let windowDefault: UInt32 = 2 * 1024 * 1024
private let packetDefault: UInt32 = 32768

/// One TCP + SSH session. libssh2 sessions are not thread-safe, so every call is
/// serialised on `queue`. Long-running calls (`lines`, `pty`) take the connection
/// over for their lifetime — open a dedicated connection for them.
public final class SSHConnection: @unchecked Sendable {
    public let target: SSHTarget
    public let hostKey: HostKey
    private let queue: DispatchQueue
    private let sock: Int32
    private let session: OpaquePointer
    private var isClosed = false

    private init(target: SSHTarget, sock: Int32, session: OpaquePointer, hostKey: HostKey, queue: DispatchQueue) {
        self.target = target
        self.sock = sock
        self.session = session
        self.hostKey = hostKey
        self.queue = queue
    }

    deinit { closeNow() }

    // MARK: connect

    public static func connect(
        to target: SSHTarget, key: SSHKey, timeout: TimeInterval = 10, trust: @escaping HostKeyPolicy
    ) async throws -> SSHConnection {
        let queue = DispatchQueue(label: "lasso.ssh.\(target.host)")
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try connectSync(target: target, key: key, timeout: timeout, trust: trust, queue: queue) })
            }
        }
    }

    private static func connectSync(
        target: SSHTarget, key: SSHKey, timeout: TimeInterval, trust: HostKeyPolicy, queue: DispatchQueue
    ) throws -> SSHConnection {
        guard libssh2Ready else { throw SSHError.handshake("libssh2_init failed") }
        let fd = try openSocket(host: target.host, port: target.port, timeout: timeout)
        guard let s = libssh2_session_init_ex(nil, nil, nil, nil) else {
            Darwin.close(fd); throw SSHError.handshake("session_init")
        }
        libssh2_session_set_blocking(s, 1)
        libssh2_session_set_timeout(s, Int(timeout * 1000))
        func fail(_ make: (String) -> SSHError) -> SSHError {
            let e = make(lastError(s))
            libssh2_session_free(s); Darwin.close(fd)
            return e
        }
        guard libssh2_session_handshake(s, fd) == 0 else { throw fail(SSHError.handshake) }

        var len = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(s, &len, &type) else { throw fail(SSHError.handshake) }
        let blob = Data(bytes: raw, count: len)
        let hk = HostKey(type: hostKeyTypeName(blob: blob), blob: blob)
        guard trust(hk) else {
            libssh2_session_disconnect_ex(s, SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE, "host key rejected", "")
            libssh2_session_free(s); Darwin.close(fd)
            throw SSHError.hostKeyRejected(fingerprint: hk.fingerprint)
        }

        let pem = key.openSSHPrivateKeyPEM
        let pub = key.authorizedKeysLine
        let rc = target.user.withCString { u in
            pem.withCString { p in
                pub.withCString { k in
                    libssh2_userauth_publickey_frommemory(
                        s, u, target.user.utf8.count, k, pub.utf8.count, p, pem.utf8.count, nil)
                }
            }
        }
        guard rc == 0 else { throw fail(SSHError.auth) }
        libssh2_session_set_timeout(s, 0)
        return SSHConnection(target: target, sock: fd, session: s, hostKey: hk, queue: queue)
    }

    // MARK: operations

    /// Run a command (no PTY) and collect stdout / stderr / exit code.
    public func exec(_ command: String, stdin: Data? = nil) async throws -> ExecResult {
        try await run {
            let ch = try self.openSessionChannel()
            defer { libssh2_channel_free(ch) }
            let rc = command.withCString { libssh2_channel_process_startup(ch, "exec", 4, $0, UInt32(command.utf8.count)) }
            guard rc == 0 else { throw SSHError.channel(self.err()) }
            if let stdin { try self.writeAll(ch, stdin) }
            libssh2_channel_send_eof(ch)
            let out = try self.readToEOF(ch, stream: 0)
            let errOut = try self.readToEOF(ch, stream: 1)
            libssh2_channel_close(ch)
            libssh2_channel_wait_closed(ch)
            return ExecResult(stdout: out, stderr: errOut, exitCode: libssh2_channel_get_exit_status(ch))
        }
    }

    /// Open `direct-streamlocal` to a Unix socket on the host, write one line, read one line back.
    public func unixRequest(path: String, line: Data) async throws -> Data {
        try await run {
            let ch = try self.openStreamlocal(path)
            defer { libssh2_channel_close(ch); libssh2_channel_free(ch) }
            try self.writeAll(ch, line)
            return try self.readLine(ch) ?? { throw SSHError.closed }()
        }
    }

    /// Open `direct-streamlocal`, write one line, then stream every line until the channel
    /// closes or the stream is cancelled. Occupies this connection.
    public func unixLines(path: String, line: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let cancelled = Flag()
            cont.onTermination = { _ in cancelled.set() }
            queue.async {
                do {
                    let ch = try self.openStreamlocal(path)
                    defer { libssh2_channel_close(ch); libssh2_channel_free(ch) }
                    try self.writeAll(ch, line)
                    // Short timeout so cancellation is noticed; timeouts are not errors here.
                    libssh2_session_set_timeout(self.session, 500)
                    defer { libssh2_session_set_timeout(self.session, 0) }
                    var buf = Data()
                    var chunk = [UInt8](repeating: 0, count: 16384)
                    while !cancelled.isSet {
                        let n = libssh2_channel_read_ex(ch, 0, &chunk, chunk.count)
                        if n == LIBSSH2_ERROR_TIMEOUT || n == LIBSSH2_ERROR_EAGAIN { continue }
                        if n < 0 { throw SSHError.io(self.err()) }
                        if n == 0 { if libssh2_channel_eof(ch) != 0 { break } else { continue } }
                        buf.append(contentsOf: chunk[0 ..< n])
                        while let nl = buf.firstIndex(of: 0x0A) {
                            cont.yield(buf.subdata(in: buf.startIndex ..< nl))
                            buf.removeSubrange(buf.startIndex ... nl)
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
        }
    }

    /// Start `command` under a PTY. The connection switches to non-blocking mode and is
    /// owned by the returned channel until it closes.
    public func pty(command: String, cols: Int, rows: Int, term: String = "xterm-256color") async throws -> PTYChannel {
        try await run {
            let ch = try self.openSessionChannel()
            let rc = term.withCString {
                libssh2_channel_request_pty_ex(ch, $0, UInt32(term.utf8.count), nil, 0, Int32(cols), Int32(rows), 0, 0)
            }
            guard rc == 0 else { libssh2_channel_free(ch); throw SSHError.channel(self.err()) }
            let rc2 = command.withCString { libssh2_channel_process_startup(ch, "exec", 4, $0, UInt32(command.utf8.count)) }
            guard rc2 == 0 else { libssh2_channel_free(ch); throw SSHError.channel(self.err()) }
            libssh2_session_set_blocking(self.session, 0)
            return PTYChannel(connection: self, channel: ch)
        }
    }

    public func close() { queue.async { self.closeNow() } }

    // MARK: internals (call on queue only)

    var rawSession: OpaquePointer { session }
    var socket: Int32 { sock }
    var serialQueue: DispatchQueue { queue }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard !self.isClosed else { cont.resume(throwing: SSHError.closed); return }
                cont.resume(with: Result { try body() })
            }
        }
    }

    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
        libssh2_session_free(session)
        Darwin.close(sock)
    }

    func err() -> String { Self.lastError(session) }

    private func openSessionChannel() throws -> OpaquePointer {
        guard let ch = libssh2_channel_open_ex(session, "session", 7, windowDefault, packetDefault, nil, 0) else {
            throw SSHError.channel(err())
        }
        return ch
    }

    private func openStreamlocal(_ path: String) throws -> OpaquePointer {
        guard let ch = libssh2_channel_direct_streamlocal_ex(session, path, "127.0.0.1", 0) else {
            throw SSHError.channel("streamlocal \(path): \(err())")
        }
        return ch
    }

    private func writeAll(_ ch: OpaquePointer, _ data: Data) throws {
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = libssh2_channel_write_ex(ch, 0, p.baseAddress!.advanced(by: off).assumingMemoryBound(to: CChar.self), p.count - off)
                if n == LIBSSH2_ERROR_EAGAIN { continue }
                guard n >= 0 else { throw SSHError.io(err()) }
                off += n
            }
        }
    }

    private func readToEOF(_ ch: OpaquePointer, stream: Int32) throws -> Data {
        var out = Data()
        var chunk = [CChar](repeating: 0, count: 16384)
        while true {
            let n = libssh2_channel_read_ex(ch, stream, &chunk, chunk.count)
            if n == LIBSSH2_ERROR_EAGAIN { continue }
            guard n >= 0 else { throw SSHError.io(err()) }
            if n == 0 { break }
            chunk.withUnsafeBytes { out.append(contentsOf: $0.prefix(n)) }
        }
        return out
    }

    private func readLine(_ ch: OpaquePointer) throws -> Data? {
        var buf = Data()
        var chunk = [CChar](repeating: 0, count: 65536)
        while true {
            if let nl = buf.firstIndex(of: 0x0A) { return buf.subdata(in: buf.startIndex ..< nl) }
            let n = libssh2_channel_read_ex(ch, 0, &chunk, chunk.count)
            if n == LIBSSH2_ERROR_EAGAIN { continue }
            guard n >= 0 else { throw SSHError.io(err()) }
            if n == 0 { return buf.isEmpty ? nil : buf }
            chunk.withUnsafeBytes { buf.append(contentsOf: $0.prefix(n)) }
        }
    }

    static func lastError(_ s: OpaquePointer) -> String {
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        let code = libssh2_session_last_error(s, &msg, &len, 0)
        return "\(msg.map { String(cString: $0) } ?? "unknown") (\(code))"
    }

    private static func hostKeyTypeName(blob: Data) -> String {
        guard blob.count > 4 else { return "unknown" }
        let n = Int(blob.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        guard blob.count >= 4 + n else { return "unknown" }
        return String(decoding: blob.subdata(in: 4 ..< 4 + n), as: UTF8.self)
    }

    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &res)
        guard gai == 0, let first = res else { throw SSHError.resolve(String(cString: gai_strerror(gai))) }
        defer { freeaddrinfo(res) }
        var lastErr = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = Darwin.socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            if connectWithTimeout(fd, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout) { return fd }
            lastErr = String(cString: strerror(errno))
            Darwin.close(fd)
        }
        throw SSHError.connect(lastErr)
    }

    private static func connectWithTimeout(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t, _ timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if Darwin.connect(fd, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { errno = ETIMEDOUT; return false }
        var soErr: Int32 = 0
        var l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &l)
        errno = soErr
        return soErr == 0
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
