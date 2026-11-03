import CryptoKit
import Foundation

/// Ed25519 client key. Serialised to the unencrypted OpenSSH format libssh2 reads from memory.
public struct SSHKey: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let comment: String

    public init(privateKey: Curve25519.Signing.PrivateKey = .init(), comment: String = "lasso") {
        self.privateKey = privateKey
        self.comment = comment
    }

    public init(rawRepresentation: Data, comment: String = "lasso") throws {
        try self.init(privateKey: .init(rawRepresentation: rawRepresentation), comment: comment)
    }

    var publicBytes: Data { privateKey.publicKey.rawRepresentation }

    /// `ssh-ed25519 AAAA… comment` — what the user pastes into authorized_keys.
    public var authorizedKeysLine: String {
        "ssh-ed25519 \(publicBlob.base64EncodedString()) \(comment)"
    }

    var publicBlob: Data {
        var b = SSHBuffer(); b.string("ssh-ed25519"); b.bytes(publicBytes); return b.data
    }

    /// Fingerprint in `ssh-keygen -l` form: `SHA256:…` (unpadded base64).
    public var fingerprint: String { HostKey.fingerprint(of: publicBlob) }

    var openSSHPrivateKeyPEM: String {
        var priv = SSHBuffer()
        let check = UInt32.random(in: .min ... .max)
        priv.uint32(check); priv.uint32(check)
        priv.string("ssh-ed25519")
        priv.bytes(publicBytes)
        priv.bytes(privateKey.rawRepresentation + publicBytes)
        priv.string(comment)
        var pad: UInt8 = 1
        while priv.data.count % 8 != 0 { priv.data.append(pad); pad += 1 }

        var out = SSHBuffer()
        out.data.append(contentsOf: Array("openssh-key-v1".utf8) + [0])
        out.string("none"); out.string("none"); out.string("")
        out.uint32(1)
        out.bytes(publicBlob)
        out.bytes(priv.data)
        let b64 = out.data.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let s = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[s ..< (b64.index(s, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// Parse an unencrypted OpenSSH ed25519 private key (used by tests and key import).
    public init(openSSHPEM pem: String) throws {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { throw SSHError.badKey("base64") }
        var r = SSHReader(data)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard try r.raw(magic.count) == Data(magic) else { throw SSHError.badKey("magic") }
        guard try r.string() == "none", try r.string() == "none" else { throw SSHError.badKey("encrypted keys unsupported") }
        _ = try r.bytes(); _ = try r.uint32(); _ = try r.bytes()
        var p = SSHReader(try r.bytes())
        _ = try p.uint32(); _ = try p.uint32()
        guard try p.string() == "ssh-ed25519" else { throw SSHError.badKey("not ed25519") }
        _ = try p.bytes()
        let sk = try p.bytes()
        let comment = try p.string()
        try self.init(rawRepresentation: sk.prefix(32), comment: comment)
    }
}

struct SSHBuffer {
    var data = Data()
    mutating func uint32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { uint32(UInt32(d.count)); data.append(d) }
    mutating func string(_ s: String) { bytes(Data(s.utf8)) }
}

struct SSHReader {
    let data: Data; var pos: Int
    init(_ d: Data) { data = Data(d); pos = 0 }
    mutating func raw(_ n: Int) throws -> Data {
        guard pos + n <= data.count else { throw SSHError.badKey("truncated") }
        defer { pos += n }; return data.subdata(in: pos ..< pos + n)
    }
    mutating func uint32() throws -> UInt32 { try raw(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func bytes() throws -> Data { try raw(Int(uint32())) }
    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
}
