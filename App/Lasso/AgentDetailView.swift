import HerdrKit
import LassoCore
import SwiftUI

/// Recent output of one pane plus a composer and key bar. Polls `pane.read` while visible
/// (herdr has no output stream in its API; the live terminal covers real-time use).
struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    let host: HerdrHost
    let paneID: String
    @State private var output = ""
    @State private var draft = ""
    @State private var error: String?
    @State private var showTerminal = false
    @State private var sending = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        let store = model.store(for: host)
        let agent = store.agent(paneID)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? " " : output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            KeyBar { keys in send { try await store.client.sendKeys(paneID, keys) } }
            HStack(alignment: .bottom) {
                TextField(agent?.agentStatus == .blocked ? "Answer…" : "Prompt…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                Button {
                    let text = draft
                    draft = ""
                    send { try await store.client.prompt(paneID, text: text, isAgent: agent != nil && agent?.agentStatus != .blocked) }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                    .accessibilityLabel("Send")
            }
            .padding(8)
        }
        .navigationTitle(agent?.displayName ?? paneID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(agent?.displayName ?? paneID).font(.headline)
                    if let s = agent?.agentStatus { Text(s.rawValue).font(.caption2).foregroundStyle(s.color) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTerminal = true } label: { Image(systemName: "apple.terminal") }.accessibilityLabel("Open terminal")
            }
        }
        .fullScreenCover(isPresented: $showTerminal) { TerminalScreen(host: host, paneID: paneID) }
        .task(id: paneID) { await poll(store) }
    }

    private func poll(_ store: SessionStore) async {
        while !Task.isCancelled {
            do {
                let r = try await store.client.read(paneID, source: .recent, lines: 400)
                if r.text != output { output = r.text }
                error = nil
            } catch { self.error = String(describing: error) }
            try? await Task.sleep(for: .seconds(store.agent(paneID)?.agentStatus == .working ? 1 : 2.5))
        }
    }

    private func send(_ op: @escaping @MainActor () async throws -> Void) {
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do { try await op(); error = nil } catch { self.error = String(describing: error) }
        }
    }
}

/// Keys agents commonly need on a phone.
struct KeyBar: View {
    let send: ([String]) -> Void
    private let keys: [(String, [String])] = [
        ("esc", ["esc"]), ("⏎", ["enter"]), ("⇥", ["tab"]), ("⇧⇥", ["shift+tab"]),
        ("↑", ["up"]), ("↓", ["down"]), ("←", ["left"]), ("→", ["right"]),
        ("^C", ["ctrl+c"]), ("1", ["1"]), ("2", ["2"]), ("3", ["3"]), ("y", ["y"]), ("n", ["n"]),
    ]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.0) { k in
                    Button(k.0) { send(k.1) }
                        .font(.system(.callout, design: .monospaced))
                        .buttonStyle(.bordered)
                        .accessibilityLabel(k.1.joined())
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }
}
