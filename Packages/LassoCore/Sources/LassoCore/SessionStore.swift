import Foundation
import HerdrKit
import Observation

/// Live view of one host's herdr session.
///
/// Bootstrap: open the event stream, then take a snapshot. Every event is treated as an
/// invalidation and triggers a debounced re-snapshot, so the store never drifts from herdr.
/// On any failure it backs off and reconnects; `reconnectNow()` skips the wait.
@MainActor @Observable
public final class SessionStore {
    public enum Phase: Equatable { case idle, connecting, live, failed(String) }

    public let hostID: UUID
    public private(set) var phase: Phase = .idle
    public private(set) var snapshot: Snapshot = .empty
    public private(set) var lastUpdate: Date?
    /// Known after the first successful snapshot.
    public private(set) var backend: HerdrBackend?

    public let client: HerdrClient
    /// Fired for every agent whose status changed between two snapshots.
    public var onStatusChange: (@MainActor (Agent, AgentStatus?) -> Void)?

    private var loop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshDirty = false
    private var refreshGeneration = 0
    private var wake: CheckedContinuation<Void, Never>?

    public init(hostID: UUID, transport: HerdrTransport) {
        self.hostID = hostID
        client = HerdrClient(transport: transport)
    }

    // MARK: derived

    /// Agents ordered for attention: blocked > working > done > idle, then by workspace number.
    public var agentsByAttention: [Agent] {
        let wsNumber = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceId, $0.number) })
        return snapshot.agents.sorted {
            ($0.agentStatus, wsNumber[$0.workspaceId] ?? .max, $0.paneId) < ($1.agentStatus, wsNumber[$1.workspaceId] ?? .max, $1.paneId)
        }
    }

    public var blockedCount: Int { snapshot.agents.count { $0.agentStatus == .blocked } }

    public func agents(in workspace: String) -> [Agent] { agentsByAttention.filter { $0.workspaceId == workspace } }
    public func tabs(in workspace: String) -> [Tab] { snapshot.tabs.filter { $0.workspaceId == workspace }.sorted { $0.number < $1.number } }
    public func agent(_ pane: String) -> Agent? { snapshot.agents.first { $0.paneId == pane } }
    public func pane(_ id: String) -> Pane? { snapshot.panes.first { $0.paneId == id } }

    // MARK: lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        refreshTask?.cancel()
        refreshTask = nil
        phase = .idle
    }

    public func reconnectNow() {
        if let wake { self.wake = nil; wake.resume() } else if loop == nil { start() }
    }

    /// Force a snapshot now (pull-to-refresh, after a user action).
    public func refresh() async {
        do { try await apply(client.snapshot()) } catch { phase = .failed(String(describing: error)) }
    }

    private func run() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            phase = .connecting
            do {
                backend = try await client.transport.backend()
                let first = try await client.snapshot()
                apply(first)
                phase = .live
                backoff = 1
                try await followEvents()
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(String(describing: error))
            }
            guard !Task.isCancelled else { return }
            await sleepOrWake(seconds: backoff)
            backoff = min(backoff * 2, 30)
        }
    }

    /// Follows events until the stream ends or the set of panes changes (resubscribe).
    private func followEvents() async throws {
        if try await client.transport.backend() == .core {
            // One stream covers all terminals; the 15 s heartbeat keeps it honest.
            let stream = client.coreEvents()
            scheduleRefresh(delay: 0)
            for try await _ in stream { scheduleRefresh(delay: 0.15) }
            throw HerdrClientError.unexpected("event stream closed")
        }
        while !Task.isCancelled {
            let panes = snapshot.panes.map(\.paneId)
            let stream = client.events(statusOf: panes)
            // Re-snapshot right after subscribing: closes the gap between snapshot and subscribe.
            scheduleRefresh(delay: 0)
            var resubscribe = false
            for try await _ in stream {
                scheduleRefresh(delay: 0.15)
                if Set(snapshot.panes.map(\.paneId)) != Set(panes) { resubscribe = true; break }
            }
            if !resubscribe { throw HerdrClientError.unexpected("event stream closed") }
        }
    }

    /// Coalesce events into snapshots. A snapshot already on the wire is never cancelled (on a slow link a
    /// steady event flow would otherwise cancel every one); events during it mark the store dirty and one
    /// more snapshot follows.
    private func scheduleRefresh(delay: Double) {
        if refreshTask != nil { refreshDirty = true; return }
        let gen = refreshGeneration &+ 1
        refreshGeneration = gen
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while let self, !Task.isCancelled {
                refreshDirty = false
                if let s = try? await client.snapshot(), !Task.isCancelled { apply(s) }
                if !refreshDirty { break }
            }
            // A task cancelled by stop() must not clear the handle of one started after it.
            if let self, refreshGeneration == gen { refreshTask = nil }
        }
    }

    func apply(_ new: Snapshot) {
        let old = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.paneId, $0.agentStatus) })
        let hadData = !snapshot.version.isEmpty
        snapshot = new
        lastUpdate = Date()
        guard hadData else { return }
        for a in new.agents where old[a.paneId] != a.agentStatus {
            onStatusChange?(a, old[a.paneId])
        }
    }

    private func sleepOrWake(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await MainActor.run { if let w = self?.wake { self?.wake = nil; w.resume() } }
            }
        }
    }
}
