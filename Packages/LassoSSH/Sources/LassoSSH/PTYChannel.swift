import CLibSSH2
import Darwin
import Foundation

/// Interactive PTY channel. A pump loop on the connection's queue interleaves reads,
/// queued writes and resizes using a non-blocking session and `poll` on the socket.
public final class PTYChannel: @unchecked Sendable {
    private let connection: SSHConnection
    private let channel: OpaquePointer
    private let lock = NSLock()
    private var pendingWrite = Data()
    private var pendingResize: (Int, Int)?
    private var stopped = false
    private var handlers: (output: @Sendable (Data) -> Void, exit: @Sendable (Int32?) -> Void)?

    init(connection: SSHConnection, channel: OpaquePointer) {
        self.connection = connection
        self.channel = channel
    }

    /// Begin pumping. `output` gets raw terminal bytes; `exit` fires once with the exit status (nil on error).
    public func start(output: @escaping @Sendable (Data) -> Void, exit: @escaping @Sendable (Int32?) -> Void) {
        handlers = (output, exit)
        connection.serialQueue.async { self.pump() }
    }

    public func write(_ data: Data) { lock.withLock { pendingWrite.append(data) } }

    public func resize(cols: Int, rows: Int) { lock.withLock { pendingResize = (cols, rows) } }

    public func close() { lock.withLock { stopped = true } }

    // swiftlint:disable:next cyclomatic_complexity
    private func pump() {
        var chunk = [CChar](repeating: 0, count: 32768)
        var exitCode: Int32?
        loop: while true {
            // swiftlint:disable:next large_tuple
            let (stop, toWrite, resize) = lock.withLock { () -> (Bool, Data, (Int, Int)?) in
                defer { pendingResize = nil }
                return (stopped, pendingWrite, pendingResize)
            }
            if stop { break }
            var progressed = false

            if let (c, r) = resize, libssh2_channel_request_pty_size_ex(channel, Int32(c), Int32(r), 0, 0) == LIBSSH2_ERROR_EAGAIN {
                lock.withLock { if pendingResize == nil { pendingResize = (c, r) } }
            }

            if !toWrite.isEmpty {
                let n = toWrite.withUnsafeBytes { p in
                    libssh2_channel_write_ex(channel, 0, p.baseAddress!.assumingMemoryBound(to: CChar.self), p.count)
                }
                if n > 0 {
                    lock.withLock { pendingWrite.removeFirst(n) }
                    progressed = true
                } else if n < 0, n != LIBSSH2_ERROR_EAGAIN { break loop }
            }

            for stream: Int32 in [0, 1] {
                while true {
                    let n = libssh2_channel_read_ex(channel, stream, &chunk, chunk.count)
                    if n > 0 {
                        handlers?.output(chunk.withUnsafeBytes { Data($0.prefix(n)) })
                        progressed = true
                    } else if n == 0 || n == LIBSSH2_ERROR_EAGAIN {
                        break
                    } else { break loop }
                }
            }

            if libssh2_channel_eof(channel) != 0 {
                exitCode = libssh2_channel_get_exit_status(channel)
                break
            }
            if !progressed {
                var pfd = pollfd(fd: connection.socket, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, 30)
            }
        }
        libssh2_session_set_blocking(connection.rawSession, 1)
        libssh2_channel_close(channel)
        libssh2_channel_free(channel)
        handlers?.exit(exitCode)
        connection.close()
    }
}
