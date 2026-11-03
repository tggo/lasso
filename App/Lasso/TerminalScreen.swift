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
    @StateObject private var terminal = TerminalViewState()
    @State private var bridge = TerminalBridge()
    @State private var takeover = true

    var body: some View {
        NavigationStack {
            TerminalSurfaceView(context: terminal)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay {
                    if let e = bridge.error {
                        ContentUnavailableView {
                            Label("Terminal closed", systemImage: "xmark.octagon")
                        } description: { Text(e) } actions: {
                            Button("Reconnect") { Task { await connect() } }
                        }
                        .background(.background)
                    }
                }
                .navigationTitle(paneID)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { bridge.close(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $takeover) { Text("Takeover") }
                            .toggleStyle(.button)
                            .onChange(of: takeover) { _, _ in Task { await connect() } }
                            .accessibilityHint("Resize the pane to this screen instead of mirroring the desktop size")
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
    @ObservationIgnored private var pty: PTYChannel?
    @ObservationIgnored private let state = BridgeState()
    @ObservationIgnored lazy var session = InMemoryTerminalSession(
        write: { [state] data in state.pty?.write(data) },
        resize: { [state] vp in
            state.size = (Int(vp.columns), Int(vp.rows))
            state.pty?.resize(cols: Int(vp.columns), rows: Int(vp.rows))
        }
    )

    func open(link: HostLink, pane: String, takeover: Bool) async {
        error = nil
        let (cols, rows) = state.size ?? (80, 24)
        do {
            let p = try await link.attach(pane: pane, takeover: takeover, cols: cols, rows: rows)
            pty = p
            state.pty = p
            let session = session
            let filter = AttachFilter()
            p.start(output: { data in
                if let d = filter.feed(data) { session.receive(d) }
            }, exit: { [weak self] code in
                Task { @MainActor in self?.error = code == 0 ? "Detached." : "Connection ended (\(code.map(String.init) ?? "error"))." }
            })
            if let s = state.size { p.resize(cols: s.0, rows: s.1) }
        } catch {
            self.error = String(describing: error)
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
}
