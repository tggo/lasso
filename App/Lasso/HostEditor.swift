import HerdrKit
import LassoCore
import LassoSSH
import SwiftUI

/// Add/edit a host. Saving a new host requires a successful probe: the user sees the
/// host-key fingerprint and explicitly trusts it (TOFU), which pins it.
struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: HerdrHost
    @State private var port = "22"
    @State private var probing = false
    @State private var probed: (HostKey, PongInfo)?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $host.name)
                    TextField("Address (IP, hostname, Tailscale name)", text: $host.target.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("User", text: $host.target.user).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Session name (optional)", text: Binding($host.session, default: ""))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Socket path (optional)", text: Binding($host.socketPath, default: ""))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("herdr") } footer: {
                    Text("Leave empty for the default session (~/.config/herdr/herdr.sock).")
                }
                Section {
                    if let pinned = host.pinnedHostKey {
                        LabeledContent("Pinned", value: pinned.type)
                        Text(pinned.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Forget pinned key", role: .destructive) {
                            host.pinnedHostKey = nil
                            model.forgetHostKey(host.id)
                        }
                    } else if let (key, pong) = probed {
                        LabeledContent("herdr", value: "\(pong.version) (protocol \(pong.protocol))")
                        LabeledContent("Key type", value: key.type)
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        Text(
                            "Compare with `ssh-keygen -lf /etc/ssh/ssh_host_\(key.type.replacingOccurrences(of: "ssh-", with: ""))_key.pub` on the host."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await probe() }
                        } label: {
                            HStack { Text("Connect & show host key"); if probing { Spacer(); ProgressView() } }
                        }
                        .disabled(!isValid || probing)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                } header: { Text("Host key") }
            }
            .navigationTitle(host.name.isEmpty ? "New host" : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(host.pinnedHostKey == nil && probed != nil ? "Trust & save" : "Save") { save() }
                        .disabled(!isValid || (host.pinnedHostKey == nil && probed == nil))
                }
            }
            .onAppear { port = String(host.target.port) }
        }
    }

    private var isValid: Bool { !host.target.host.isEmpty && !host.target.user.isEmpty && Int(port) != nil }

    private func probe() async {
        host.target.port = Int(port) ?? 22
        probing = true
        error = nil
        defer { probing = false }
        do { probed = try await model.probe(host) } catch { self.error = String(describing: error) }
    }

    private func save() {
        host.target.port = Int(port) ?? 22
        if host.pinnedHostKey == nil, let (key, _) = probed { host.pinnedHostKey = key }
        if host.name.isEmpty { host.name = host.target.host }
        model.save(host)
        dismiss()
    }
}

extension Binding where Value == String {
    init(_ source: Binding<String?>, default d: String) {
        self.init(get: { source.wrappedValue ?? d }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
