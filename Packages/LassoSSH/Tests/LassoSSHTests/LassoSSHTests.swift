import Foundation
@testable import LassoSSH
import Testing

@Test func keyRoundTripsThroughOpenSSHFormat() throws {
    let key = SSHKey(comment: "test")
    let parsed = try SSHKey(openSSHPEM: key.openSSHPrivateKeyPEM)
    #expect(parsed.privateKey.rawRepresentation == key.privateKey.rawRepresentation)
    #expect(key.authorizedKeysLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
}

@Test func fingerprintMatchesSSHKeygen() throws {
    // Write the public key, ask ssh-keygen for its fingerprint, compare.
    let key = SSHKey(comment: "fp")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-fp-\(UUID()).pub")
    try key.authorizedKeysLine.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    p.arguments = ["-l", "-f", url.path]
    let pipe = Pipe(); p.standardOutput = pipe
    try p.run(); p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(out.contains(key.fingerprint))
}

// MARK: integration — needs `scripts/it-sshd.sh start` (run via `make test-integration`)

enum IT {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["LASSO_IT_HOST"] != nil }
    static var target: SSHTarget {
        SSHTarget(host: env["LASSO_IT_HOST"]!, port: Int(env["LASSO_IT_PORT"]!)!, user: env["LASSO_IT_USER"]!)
    }

    static func key() throws -> SSHKey { try SSHKey(openSSHPEM: String(contentsOfFile: env["LASSO_IT_KEY"]!, encoding: .utf8)) }
    static var hostKeyLine: String { (try? String(contentsOfFile: env["LASSO_IT_HOSTKEY"]!, encoding: .utf8)) ?? "" }
    static var sock: String { env["LASSO_IT_SOCK"]! }
    static func trustPinned(_ hk: HostKey) -> Bool { hostKeyLine.contains(hk.blob.base64EncodedString()) }
    static func connect() async throws -> SSHConnection {
        try await SSHConnection.connect(to: target, key: key(), trust: trustPinned)
    }
}

@Suite(.enabled(if: IT.enabled)) struct Integration {
    @Test func execRunsCommand() async throws {
        let c = try await IT.connect()
        let r = try await c.exec("echo hello; echo err 1>&2; exit 3")
        #expect(r.output == "hello\n")
        #expect(String(decoding: r.stderr, as: UTF8.self) == "err\n")
        #expect(r.exitCode == 3)
    }

    @Test func wrongHostKeyIsRejected() async throws {
        await #expect(throws: SSHError.self) {
            _ = try await SSHConnection.connect(to: IT.target, key: IT.key(), trust: { _ in false })
        }
    }

    @Test func unknownClientKeyFailsAuth() async throws {
        await #expect {
            _ = try await SSHConnection.connect(to: IT.target, key: SSHKey(), trust: IT.trustPinned)
        } throws: { ($0 as? SSHError).map { if case .auth = $0 { true } else { false } } ?? false }
    }

    @Test func pingsHerdrOverStreamlocal() async throws {
        let c = try await IT.connect()
        let line = try await c.unixRequest(path: IT.sock, line: Data(#"{"id":"1","method":"ping","params":{}}"#.utf8 + [0x0A]))
        #expect(String(decoding: line, as: UTF8.self).contains(#""type":"pong""#))
    }

    @Test func manySequentialRequestsReuseOneConnection() async throws {
        let c = try await IT.connect()
        for i in 0 ..< 25 {
            let line = try await c.unixRequest(path: IT.sock, line: Data(#"{"id":"\#(i)","method":"ping","params":{}}"#.utf8 + [0x0A]))
            #expect(String(decoding: line, as: UTF8.self).contains(#""id":"\#(i)""#))
        }
    }

    @Test func ptyEchoesInput() async throws {
        let c = try await IT.connect()
        let pty = try await c.pty(command: "/bin/cat", cols: 80, rows: 24)
        let got = Collector()
        pty.start(output: { got.append($0) }, exit: { _ in })
        pty.write(Data("lasso-pty\n".utf8))
        for _ in 0 ..< 50 where !got.text.contains("lasso-pty") {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(got.text.contains("lasso-pty"))
        pty.resize(cols: 100, rows: 30)
        pty.close()
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
