import Foundation
import HerdrKit
import LassoCore
import LassoSSH
import Observation
import UIKit

/// App-wide state: configured hosts and one live session store per host.
@MainActor @Observable
final class AppModel {
    private(set) var hosts: [HerdrHost]
    private(set) var stores: [UUID: SessionStore] = [:]
    private(set) var links: [UUID: HostLink] = [:]
    var lastError: String?
    /// Set by a notification tap; SessionView navigates to it.
    var pendingAgent: (host: UUID, pane: String)?

    let keys: KeyStore
    private let repo: HostRepository
    let notifier = Notifier()

    init(keys: KeyStore = KeychainKeyStore(), repo: HostRepository = HostRepository()) {
        var keys = keys
        var seeded: [HerdrHost] = []
        #if DEBUG
            // Test seam for `make sim-demo` / UI tests only; compiled out of Release builds.
            let env = ProcessInfo.processInfo.environment
            if let path = env["LASSO_SEED_KEY"], let pem = try? String(contentsOfFile: path, encoding: .utf8),
               let key = try? SSHKey(openSSHPEM: pem) { keys = MemoryKeyStore(key: key) }
            if let spec = env["LASSO_SEED_HOST"] { // host:port:user:socket
                let f = spec.split(separator: ":", maxSplits: 3).map(String.init)
                if f.count == 4, let port = Int(f[1]) {
                    seeded = [HerdrHost(name: "Local herdr", target: SSHTarget(host: f[0], port: port, user: f[2]), socketPath: f[3])]
                }
            }
        #endif
        self.keys = keys
        self.repo = repo
        hosts = seeded.isEmpty ? repo.load() : seeded
    }

    var publicKeyLine: String { (try? keys.deviceKey().authorizedKeysLine) ?? "—" }
    var publicKeyFingerprint: String { (try? keys.deviceKey().fingerprint) ?? "—" }

    // MARK: hosts

    func save(_ host: HerdrHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            let changedTarget = hosts[i].target != host.target || hosts[i].session != host.session || hosts[i].socketPath != host.socketPath
            hosts[i] = host
            if changedTarget { drop(host.id) }
        } else {
            hosts.append(host)
        }
        persist()
    }

    func delete(_ id: UUID) {
        drop(id)
        hosts.removeAll { $0.id == id }
        persist()
    }

    func forgetHostKey(_ id: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].pinnedHostKey = nil
        drop(id)
        persist()
    }

    private func persist() {
        do { try repo.save(hosts) } catch { lastError = "Could not save hosts: \(error)" }
    }

    // MARK: sessions

    func store(for host: HerdrHost) -> SessionStore {
        if let s = stores[host.id] { return s }
        let link = link(for: host)
        let s = SessionStore(hostID: host.id, transport: link)
        s.onStatusChange = { [weak self] agent, old in
            self?.notifier.statusChanged(host: host, agent: agent, from: old)
        }
        stores[host.id] = s
        return s
    }

    func link(for host: HerdrHost) -> HostLink {
        if let l = links[host.id] { return l }
        let id = host.id
        let l = HostLink(host: host, keys: keys, onPin: { [weak self] key in
            Task { @MainActor in self?.pin(key, for: id) }
        })
        links[host.id] = l
        return l
    }

    private func pin(_ key: HostKey, for id: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == id }), hosts[i].pinnedHostKey == nil else { return }
        hosts[i].pinnedHostKey = key
        persist()
    }

    private func drop(_ id: UUID) {
        stores[id]?.stop()
        stores[id] = nil
        if let l = links[id] { Task { await l.disconnect() } }
        links[id] = nil
    }

    /// Probe a host before saving it: connect, return the presented host key (TOFU step).
    /// SSH-level failures throw. If SSH works but herdr does not answer, the host key is still
    /// returned (so it can be trusted) together with the herdr error.
    func probe(_ host: HerdrHost) async throws -> (HostKey, Result<PongInfo, Error>) {
        let link = HostLink(host: host, keys: keys)
        let pong: Result<PongInfo, Error>
        do { pong = try await .success(HerdrClient(transport: link).ping()) } catch { pong = .failure(error) }
        let key = await link.host.pinnedHostKey ?? host.pinnedHostKey
        await link.disconnect()
        guard let key else {
            if case let .failure(e) = pong { throw e }
            throw SSHError.handshake("no host key")
        }
        return (key, pong)
    }

    // MARK: app lifecycle

    func enterForeground() {
        for s in stores.values {
            s.reconnectNow()
        }
    }

    func enterBackground() {
        notifier.rememberStatuses(stores.values.flatMap { s in s.snapshot.agents.map { ("\(s.hostID)|\($0.paneId)", $0.agentStatus) } })
    }
}
