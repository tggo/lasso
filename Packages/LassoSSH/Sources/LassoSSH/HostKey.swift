import CryptoKit
import Foundation

/// Server host key as presented during the handshake.
public struct HostKey: Sendable, Equatable, Codable {
    public let type: String
    public let blob: Data

    public var fingerprint: String { Self.fingerprint(of: blob) }

    static func fingerprint(of blob: Data) -> String {
        let b64 = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + b64.replacingOccurrences(of: "=", with: "")
    }
}

/// Decides whether a host key is trusted. Return `false` to abort the connection.
public typealias HostKeyPolicy = @Sendable (HostKey) -> Bool

public enum SSHError: Error, Equatable, CustomStringConvertible {
    case resolve(String)
    case connect(String)
    case handshake(String)
    case hostKeyRejected(fingerprint: String)
    case auth(String)
    case channel(String)
    case io(String)
    case badKey(String)
    case closed

    public var description: String {
        switch self {
        case let .resolve(s): "Cannot resolve host: \(s)"
        case let .connect(s): "Cannot connect: \(s)"
        case let .handshake(s): "SSH handshake failed: \(s)"
        case let .hostKeyRejected(fp): "Host key not trusted: \(fp)"
        case let .auth(s): "Authentication failed: \(s)"
        case let .channel(s): "Channel error: \(s)"
        case let .io(s): "I/O error: \(s)"
        case let .badKey(s): "Invalid key: \(s)"
        case .closed: "Connection closed"
        }
    }
}
