import BackgroundTasks
import LassoCore
import SwiftUI

@main
struct LassoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Notifier.refreshTask, using: nil) { task in
            Task { @MainActor in
                let m = AppModel()
                m.notifier.scheduleRefresh()
                await m.notifier.backgroundPass(hosts: m.hosts, keys: m.keys)
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            HostsView()
                .environment(model)
                .task {
                    model.notifier.onOpen = { host, pane in model.pendingAgent = (host, pane) }
                    model.notifier.requestPermission()
                }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: model.enterForeground()
            case .background:
                model.enterBackground()
                model.notifier.scheduleRefresh()
            default: break
            }
        }
    }
}
