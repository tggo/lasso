import HerdrKit
import LassoCore
import LassoSSH
import SwiftUI

struct HostsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: HerdrHost?
    @State private var showKey = false
    @State private var path = NavigationPath()
    @State private var deleting: HerdrHost?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(model.hosts) { host in
                    Group {
                        if host.pinnedHostKey == nil {
                            Button { editing = host } label: { HostRow(host: host) }.foregroundStyle(.primary)
                        } else {
                            NavigationLink(value: host.id) { HostRow(host: host) }
                        }
                    }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deleting = host } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                }
            }
            .overlay {
                if model.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No hosts yet", systemImage: "server.rack")
                    } description: {
                        Text("Add a machine running herdr. Lasso connects over SSH with a key that never leaves this phone.")
                    } actions: {
                        Button("Show device key") { showKey = true }.buttonStyle(.bordered)
                        Button("Add host") { editing = newHost() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Lasso")
            .navigationDestination(for: UUID.self) { id in
                if let host = model.hosts.first(where: { $0.id == id }) { SessionView(host: host) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showKey = true } label: { Image(systemName: "key") }.accessibilityLabel("Device key")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = newHost() } label: { Image(systemName: "plus") }.accessibilityLabel("Add host")
                }
            }
            .sheet(item: $editing) { HostEditor(host: $0) }
            .sheet(isPresented: $showKey) { DeviceKeyView() }
            .onChange(of: model.pendingAgent?.pane) { _, _ in openPending() }
            .onAppear { openPending() }
            .confirmationDialog("Delete \(deleting?.name ?? "host")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let d = deleting { model.delete(d.id) } }
            } message: { Text("Removes the host and its pinned host key from this phone. Nothing changes on the host.") }
        }
    }

    private func openPending() {
        if let p = model.pendingAgent, model.hosts.contains(where: { $0.id == p.host }) { path = NavigationPath([p.host]) }
    }

    private func newHost() -> HerdrHost { HerdrHost(name: "", target: SSHTarget(host: "", port: 22, user: "")) }
}

struct HostRow: View {
    @Environment(AppModel.self) private var model
    let host: HerdrHost

    var body: some View {
        let store = model.stores[host.id]
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name.isEmpty ? host.target.host : host.name).font(.headline)
                Text(verbatim: "\(host.target.user)@\(host.target.host):\(host.target.port)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if host.pinnedHostKey == nil {
                Text("Not verified").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else if let store, store.blockedCount > 0 {
                Text("\(store.blockedCount)")
                    .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(AgentStatus.blocked.textColor, in: Capsule()).foregroundStyle(.white)
                    .accessibilityLabel("\(store.blockedCount) blocked")
            }
        }
    }
}

struct DeviceKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var installCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(model.publicKeyLine)' >> ~/.ssh/authorized_keys"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.publicKeyLine).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy public key") { UIPasteboard.general.string = model.publicKeyLine }
                    ShareLink(item: model.publicKeyLine)
                } header: { Text("Public key") } footer: {
                    Text(
                        "Append this line to ~/.ssh/authorized_keys on each host. The private key stays in this device's Keychain and is never synced or backed up."
                    )
                }
                Section("Fingerprint") { Text(model.publicKeyFingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                Section {
                    Text(verbatim: installCommand).font(.caption2.monospaced()).textSelection(.enabled)
                    Button("Copy command") { UIPasteboard.general.string = installCommand }
                } header: { Text("One-liner for the host") }
            }
            .navigationTitle("Device key")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
