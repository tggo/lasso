import BackgroundTasks
import Foundation
import HerdrKit
import LassoCore
import UIKit
import UserNotifications

/// Local notifications for agents that become blocked or finish. No push, no relay:
/// fires from the live store while the app runs, and from a background refresh
/// that takes one snapshot per host and compares it with the last known statuses.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let refreshTask = "dev.lasso.refresh"
    private let defaultsKey = "lasso.lastStatuses"
    var onOpen: ((UUID, String) -> Void)?

    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func statusChanged(host: HerdrHost, agent: Agent, from old: AgentStatus?) {
        guard agent.agentStatus == .blocked || (agent.agentStatus == .done && old == .working) else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        post(host: host, agent: agent)
    }

    func post(host: HerdrHost, agent: Agent) {
        let c = UNMutableNotificationContent()
        c.title = agent.agentStatus == .blocked ? "\(agent.displayName) needs you" : "\(agent.displayName) is done"
        c.body = "\(host.name) · \(agent.cwd ?? agent.paneId)"
        c.sound = .default
        c.threadIdentifier = host.id.uuidString
        c.userInfo = ["host": host.id.uuidString, "pane": agent.paneId]
        let id = "\(host.id)|\(agent.paneId)|\(agent.agentStatus.rawValue)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: background refresh

    func rememberStatuses(_ pairs: [(String, AgentStatus)]) {
        var d = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        for (k, v) in pairs {
            d[k] = v.rawValue
        }
        UserDefaults.standard.set(d, forKey: defaultsKey)
    }

    func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// One pass: snapshot every host, notify on new blocked/done, store statuses.
    func backgroundPass(hosts: [HerdrHost], keys: KeyStore) async {
        let last = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        var seen: [(String, AgentStatus)] = []
        for host in hosts where host.pinnedHostKey != nil {
            let link = HostLink(host: host, keys: keys)
            guard let snap = try? await HerdrClient(transport: link).snapshot() else { continue }
            await link.disconnect()
            for a in snap.agents {
                let k = "\(host.id)|\(a.paneId)"
                let old = last[k].flatMap(AgentStatus.init(rawValue:))
                if old != a.agentStatus, a.agentStatus == .blocked || (a.agentStatus == .done && old == .working) {
                    post(host: host, agent: a)
                }
                seen.append((k, a.agentStatus))
            }
        }
        rememberStatuses(seen)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let h = (info["host"] as? String).flatMap(UUID.init(uuidString:)), let p = info["pane"] as? String else { return }
        await MainActor.run { onOpen?(h, p) }
    }
}
