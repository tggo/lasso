import Foundation
import LassoSSH
import Security

/// The device's SSH identity: one Ed25519 key, created on first use, stored in the Keychain
/// as `AfterFirstUnlockThisDeviceOnly` (never synced, never in backups).
public protocol KeyStore: Sendable {
    func deviceKey() throws -> SSHKey
    func resetDeviceKey() throws -> SSHKey
}

public struct KeychainKeyStore: KeyStore {
    let service: String
    let account = "device-ed25519"

    public init(service: String = "dev.lasso.ssh") { self.service = service }

    public func deviceKey() throws -> SSHKey {
        if let raw = try read() { return try SSHKey(rawRepresentation: raw, comment: comment) }
        return try resetDeviceKey()
    }

    @discardableResult
    public func resetDeviceKey() throws -> SSHKey {
        let key = SSHKey(comment: comment)
        try delete()
        let q: [String: Any] = base.merging([
            kSecValueData as String: key.privateKey.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw KeychainError(status: st) }
        return key
    }

    private var comment: String { "lasso@\(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "iphone")" }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    private func read() throws -> Data? {
        var out: AnyObject?
        let q = base.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
        return out as? Data
    }

    private func delete() throws {
        let st = SecItemDelete(base as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeychainError(status: st) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")" }
}

/// In-memory store for tests and previews.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SSHKey?
    public init(key: SSHKey? = nil) { self.key = key }
    public func deviceKey() throws -> SSHKey { lock.withLock { if key == nil { key = SSHKey() }; return key! } }
    public func resetDeviceKey() throws -> SSHKey { lock.withLock { key = SSHKey(); return key! } }
}
