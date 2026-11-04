import GhosttyTerminal
import LassoCore
import LassoSSH
import SwiftUI

/// Live terminal: `herdr agent attach` on a dedicated SSH PTY, rendered by libghostty.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HerdrHost
    let paneID: String
    var title: String = "Terminal"
    @StateObject private var terminal = TerminalViewState()
    @State private var bridge = TerminalBridge()
    @State private var takeover = true

    var body: some View {
        NavigationStack {
            TerminalSurfaceView(context: terminal)
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityLabel("Terminal")
                .overlay {
                    if bridge.connecting { ProgressView("Attaching…") }
                    if let e = bridge.error {
                        ContentUnavailableView {
                            Label("Terminal closed", systemImage: "xmark.octagon")
                        } description: { Text(e) } actions: {
                            Button("Reconnect") { Task { await connect() } }
                        }
                        .background(.background)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { bridge.close(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Toggle(isOn: $takeover) {
                                Label("Fit pane to phone", systemImage: "iphone")
                                Text("Takeover: the pane resizes to this screen. Off: mirror the desktop size.")
                            }
                        } label: { Image(systemName: takeover ? "iphone" : "desktopcomputer") }
                            .accessibilityLabel(takeover ? "Fit to phone, on" : "Fit to phone, off")
                            .onChange(of: takeover) { _, _ in Task { await connect() } }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task { await connect() }
        .onDisappear { bridge.close() }
    }

    private func connect() async {
        bridge.close()
        let link = model.link(for: host)
        let b = TerminalBridge()
        bridge = b
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(b.session))
        await b.open(link: link, pane: paneID, takeover: takeover)
        terminal.requestFocus()
    }
}

/// Glue between the PTY channel and libghostty's in-memory session.
@MainActor @Observable
final class TerminalBridge {
    private(set) var error: String?
    private(set) var connecting = false
    @ObservationIgnored private var pty: PTYChannel?
    @ObservationIgnored private let state = BridgeState()
    @ObservationIgnored lazy var session = InMemoryTerminalSession(
        write: { [state] data in state.write(data) },
        resize: { [state] vp in
            state.size = (Int(vp.columns), Int(vp.rows))
            state.pty?.resize(cols: Int(vp.columns), rows: Int(vp.rows))
        }
    )

    func open(link: HostLink, pane: String, takeover: Bool) async {
        error = nil
        connecting = true
        defer { connecting = false }
        let (cols, rows) = state.size ?? (80, 24)
        do {
            let p = try await link.attach(pane: pane, takeover: takeover, cols: cols, rows: rows)
            pty = p
            state.pty = p
            state.link = link
            let session = session
            let filter = AttachFilter()
            p.start(output: { data in
                if let d = filter.feed(data) { session.receive(d) }
            }, exit: { [weak self] code in
                Task { @MainActor in self?.error = code == 0 ? "Detached." : "Connection ended (\(code.map(String.init) ?? "error"))." }
            })
            if let s = state.size { p.resize(cols: s.0, rows: s.1) }
        } catch {
            self.error = friendly(error)
        }
    }

    func close() {
        pty?.close()
        pty = nil
        state.pty = nil
    }
}

final class BridgeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _pty: PTYChannel?
    private var _size: (Int, Int)?
    var pty: PTYChannel? { get { lock.withLock { _pty } } set { lock.withLock { _pty = newValue } } }
    var size: (Int, Int)? { get { lock.withLock { _size } } set { lock.withLock { _size = newValue } } }
    private var _link: HostLink?
    var link: HostLink? { get { lock.withLock { _link } } set { lock.withLock { _link = newValue } } }
    private var chain: Task<Void, Never>?

    /// Keystrokes go straight to the PTY, except a pasted image: its phone-local file is uploaded to the
    /// host first and the host path is typed instead. Later input waits behind it so order is kept.
    func write(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let paths = text.contains("ghostty-paste") ? PastedFiles.localPaths(in: text) : []
        lock.lock()
        let prev = chain
        if paths.isEmpty, prev == nil { lock.unlock(); pty?.write(data); return }
        let t = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            var out = text
            for p in paths {
                guard let link, var d = FileManager.default.contents(atPath: p) else { continue }
                var ext = (p as NSString).pathExtension.lowercased()
                // Agents read png/jpeg/gif/webp; HEIC from the photo library is converted.
                if !["png", "jpg", "jpeg", "gif", "webp"].contains(ext), let j = UIImage(data: d)?.jpegData(compressionQuality: 0.85) {
                    d = j
                    ext = "jpg"
                }
                let name = UUID().uuidString + "." + ext
                if let remote = try? await link.upload(d, name: name) { out = out.replacingOccurrences(of: p, with: remote) }
            }
            pty?.write(paths.isEmpty ? data : Data(out.utf8))
        }
        chain = t
        lock.unlock()
        Task { [weak self] in
            await t.value
            guard let self else { return }
            lock.withLock { if chain == t { chain = nil } }
        }
    }
}
