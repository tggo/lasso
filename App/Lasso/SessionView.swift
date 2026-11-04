import HerdrKit
import LassoCore
import SwiftUI

/// One host: agents grouped by workspace, most urgent first.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let host: HerdrHost
    @State private var selected: String?
    @State private var prompt: NamePrompt?
    @State private var actionError: String?
    @State private var confirm: CloseConfirm?

    var body: some View {
        let store = model.store(for: host)
        List {
            if case let .failed(msg) = store.phase {
                Section { ConnectionError(message: msg) { store.reconnectNow() } }
            }
            let blocked = store.agentsByAttention.filter { $0.agentStatus == .blocked }
            if !blocked.isEmpty {
                Section {
                    ForEach(blocked) { agent in
                        NavigationLink(value: agent.paneId) { AgentRow(agent: agent) }
                    }
                } header: {
                    Label("Needs you", systemImage: "hand.raised.fill").foregroundStyle(AgentStatus.blocked.textColor)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            ForEach(sortedWorkspaces(store)) { ws in
                Section {
                    ForEach(store.agents(in: ws.workspaceId)) { agent in
                        NavigationLink(value: agent.paneId) { AgentRow(agent: agent) }
                            .contextMenu {
                                if store.backend != .core {
                                    Button("Rename agent") { prompt = .renameAgent(agent.paneId, agent.name ?? "") }
                                }
                            }
                    }
                    let shells = store.snapshot.panes.filter { p in p.workspaceId == ws.workspaceId && store.agent(p.paneId) == nil }
                    ForEach(shells) { pane in
                        NavigationLink(value: pane.paneId) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(pane.label ?? "Shell")
                                    Text(pane.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? pane.paneId)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "terminal") }
                        }
                        .contextMenu { startAgentMenu(store, pane: pane.paneId) }
                        .swipeActions { Menu { startAgentMenu(store, pane: pane.paneId) } label: { Label("Start agent", systemImage: "play") } }
                    }
                } header: {
                    HStack {
                        WorkspaceHeader(ws: ws, tabs: store.tabs(in: ws.workspaceId))
                        Menu {
                            Button("New tab", systemImage: "plus.square") {
                                run { try await store.client.createTab(workspace: ws.workspaceId, label: nil) }
                            }
                            Button("Rename workspace", systemImage: "pencil") { prompt = .renameWorkspace(ws.workspaceId, ws.label) }
                            Menu("Tabs") {
                                ForEach(store.tabs(in: ws.workspaceId)) { tab in
                                    Button("Rename \(tab.label)") { prompt = .renameTab(tab.tabId, tab.label) }
                                    Button("Close \(tab.label)", role: .destructive) { confirm = .tab(tab.tabId, tab.label) }
                                }
                            }
                            Button("Close workspace", systemImage: "xmark", role: .destructive) { confirm = .workspace(ws.workspaceId, ws.label) }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 32)
                        }
                        .accessibilityLabel("Workspace actions for \(ws.label)")
                    }
                }
            }
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button("Close", role: .destructive) {
                switch c {
                case let .workspace(id, _): run { try await store.client.closeWorkspace(id) }
                case let .tab(id, _): run { try await store.client.closeTab(id) }
                }
            }
        } message: { _ in Text("Processes running in it are terminated on the host.") }
        .overlay {
            if store.phase == .connecting, store.snapshot.version.isEmpty { ProgressView("Connecting…") }
            else if store.phase == .live, store.snapshot.workspaces.isEmpty {
                ContentUnavailableView("No workspaces", systemImage: "rectangle.stack", description: Text("Create one with +"))
            }
        }
        .refreshable { await store.refresh() }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { pane in AgentDetailView(host: host, paneID: pane) }
        .navigationDestination(item: $selected) { pane in AgentDetailView(host: host, paneID: pane) }
        .toolbar {
            ToolbarItem(placement: .principal) { PhaseBadge(phase: store.phase, title: host.name) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { prompt = .newWorkspace } label: { Image(systemName: "plus") }.accessibilityLabel("New workspace")
            }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            NamePromptField(prompt: p) { name in
                switch p {
                case .newWorkspace: run { try await store.client.createWorkspace(label: name.isEmpty ? nil : name) }
                case let .renameWorkspace(id, _): run { try await store.client.renameWorkspace(id, to: name) }
                case let .renameTab(id, _): run { try await store.client.renameTab(id, to: name) }
                case let .renameAgent(id, _): run { try await store.client.renameAgent(id, to: name) }
                }
            }
        }
        .alert("Action failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: { Text(actionError ?? "") }
        .onAppear {
            store.start()
            consumePending()
        }
        .onChange(of: model.pendingAgent?.pane) { _, _ in consumePending() }
    }

    private func sortedWorkspaces(_ store: SessionStore) -> [Workspace] {
        store.snapshot.workspaces.sorted { ($0.agentStatus, $0.number) < ($1.agentStatus, $1.number) }
    }

    @ViewBuilder private func startAgentMenu(_ store: SessionStore, pane: String) -> some View {
        ForEach(["claude", "codex", "pi", "opencode"], id: \.self) { kind in
            Button("Start \(kind)") { run { try await store.client.startAgent(kind: kind, name: kind, pane: pane) } }
        }
    }

    private func consumePending() {
        guard let p = model.pendingAgent, p.host == host.id else { return }
        model.pendingAgent = nil
        selected = p.pane
    }

    private func run(_ op: @escaping @MainActor () async throws -> some Sendable) {
        Task { @MainActor in
            do {
                _ = try await op()
                await model.store(for: host).refresh()
            } catch { actionError = friendly(error) }
        }
    }
}

enum CloseConfirm {
    case workspace(String, String), tab(String, String)
    var title: String {
        switch self {
        case let .workspace(_, l): "Close workspace “\(l)”?"
        case let .tab(_, l): "Close tab “\(l)”?"
        }
    }
}

/// Human-readable error text instead of a Swift dump.
func friendly(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    let text = String(describing: error)
    if text.contains("streamlocal"), text.contains("connect failed") {
        return "SSH works, but herdr isn't running on the host (no socket). Start `herdr` there, "
            + "or set the Session name / Socket path. Details: \(text)"
    }
    // Lasso's own errors implement CustomStringConvertible with readable text.
    return String(describing: error)
}

enum NamePrompt: Identifiable {
    case newWorkspace, renameWorkspace(String, String), renameTab(String, String), renameAgent(String, String)
    var id: String { title }
    var title: String {
        switch self {
        case .newWorkspace: "New workspace"
        case .renameWorkspace: "Rename workspace"
        case .renameTab: "Rename tab"
        case .renameAgent: "Rename agent"
        }
    }

    var initial: String {
        switch self {
        case .newWorkspace: ""
        case let .renameWorkspace(_, s), let .renameTab(_, s), let .renameAgent(_, s): s
        }
    }
}

struct NamePromptField: View {
    let prompt: NamePrompt
    let done: (String) -> Void
    @State private var text = ""
    var body: some View {
        TextField("Name", text: $text).onAppear { text = prompt.initial }
        Button("OK") { done(text) }
        Button("Cancel", role: .cancel) {}
    }
}

struct WorkspaceHeader: View {
    let ws: Workspace
    let tabs: [HerdrKit.Tab]
    var body: some View {
        HStack {
            StatusDot(status: ws.agentStatus)
            Text(ws.label)
            Spacer()
            Text("\(tabs.count) tab\(tabs.count == 1 ? "" : "s")").font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ws.label), \(ws.agentStatus.rawValue), \(tabs.count) tabs")
        .accessibilityAddTraits(.isHeader)
    }
}

struct AgentRow: View {
    let agent: Agent
    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: agent.agentStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).font(.body.weight(agent.agentStatus == .blocked ? .semibold : .regular))
                Text(agent.cwd.map { ($0 as NSString).lastPathComponent } ?? agent.paneId).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(agent.agentStatus.rawValue).font(.caption.weight(.semibold)).foregroundStyle(agent.agentStatus.textColor)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var body: some View {
        Circle().fill(status.color).frame(width: 10, height: 10)
            .overlay { if status == .working { Circle().stroke(status.color.opacity(0.4), lineWidth: 4) } }
    }
}

struct PhaseBadge: View {
    let phase: SessionStore.Phase
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.headline)
        }
        .accessibilityLabel("\(title), \(label)")
    }

    private var color: Color {
        switch phase {
        case .live: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    private var label: String {
        switch phase {
        case .live: "connected"
        case .connecting: "connecting"
        case .failed: "disconnected"
        case .idle: "idle"
        }
    }
}

struct ConnectionError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not connected", systemImage: "wifi.exclamationmark").font(.headline).foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Retry now", action: retry).buttonStyle(.bordered)
        }
    }
}

extension AgentStatus {
    /// Text-safe variant (≥4.5:1 on system backgrounds in both modes).
    var textColor: Color {
        switch self {
        case .blocked: Color(light: .init(red: 0.70, green: 0.30, blue: 0), dark: .orange)
        case .working: Color(light: .init(red: 0, green: 0.38, blue: 0.80), dark: .init(red: 0.4, green: 0.7, blue: 1))
        case .done: Color(light: .init(red: 0.10, green: 0.48, blue: 0.20), dark: .green)
        case .idle, .unknown: .secondary
        }
    }

    var color: Color {
        switch self {
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle: .gray
        case .unknown: .secondary
        }
    }
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}
