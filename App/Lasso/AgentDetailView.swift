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
    @State private var pollNonce = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        let store = model.store(for: host)
        let agent = store.agent(paneID)
        VStack(spacing: 0) {
            ScrollView {
                TerminalText(blocks: OutputBlock.parse(output))
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            // Sticks to the bottom only while the user is already there; reading history is not interrupted.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            if let error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { pollNonce += 1 }.font(.caption)
                }
                .padding(.horizontal)
            }
            KeyBar(blocked: agent?.agentStatus == .blocked) { keys in send { try await store.client.sendKeys(paneID, keys) } }
            HStack(alignment: .bottom) {
                TextField(agent?.agentStatus == .blocked ? "Answer…" : "Message…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .focused($composerFocused)
                Button {
                    let text = draft
                    draft = ""
                    send(restoring: text) {
                        try await store.client.prompt(paneID, text: text, isAgent: agent != nil && agent?.agentStatus != .blocked)
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                    .accessibilityLabel("Send")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .navigationTitle(agent?.displayName ?? paneID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(agent?.displayName ?? paneID).font(.headline)
                    if let s = agent?.agentStatus { Text(s.rawValue).font(.caption.weight(.semibold)).foregroundStyle(s.textColor) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTerminal = true } label: { Image(systemName: "apple.terminal") }.accessibilityLabel("Open terminal")
            }
        }
        .fullScreenCover(isPresented: $showTerminal) { TerminalScreen(host: host, paneID: paneID, title: agent?.displayName ?? "Shell") }
        .task(id: "\(paneID)#\(pollNonce)") { await poll(store) }
    }

    private func poll(_ store: SessionStore) async {
        while !Task.isCancelled {
            do {
                let r = try await store.client.read(paneID, source: .recent, lines: 200)
                if r.text != output { output = r.text }
                error = nil
            } catch { self.error = friendly(error) }
            try? await Task.sleep(for: .seconds(store.agent(paneID)?.agentStatus == .working ? 1.5 : 4))
        }
    }

    private func send(restoring text: String? = nil, _ op: @escaping @MainActor () async throws -> Void) {
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do { try await op(); error = nil } catch {
                self.error = friendly(error)
                if let text, draft.isEmpty { draft = text } // don't lose what was typed
            }
        }
    }
}

/// Keys agents commonly need on a phone.
struct KeyBar: View {
    var blocked = false
    let send: ([String]) -> Void
    private typealias Key = (title: String, keys: [String], spoken: String)
    private static let answers: [Key] = [
        ("y", ["y"], "Y"), ("n", ["n"], "N"), ("1", ["1"], "1"), ("2", ["2"], "2"), ("3", ["3"], "3"),
    ]
    private static let control: [Key] = [
        ("esc", ["esc"], "Escape"), ("⏎", ["enter"], "Return"), ("⇥", ["tab"], "Tab"), ("⇧⇥", ["shift+tab"], "Shift Tab"),
        ("↑", ["up"], "Up"), ("↓", ["down"], "Down"), ("←", ["left"], "Left"), ("→", ["right"], "Right"),
        ("^C", ["ctrl+c"], "Control C"),
    ]
    /// A blocked agent usually wants an answer: put the answer keys first.
    private var keys: [Key] {
        blocked ? Self.answers + [Self.control[1], Self.control[0]] + Self.control.dropFirst(2) : Self.control + Self.answers
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.title) { k in
                    Button(k.title) { send(k.keys) }
                        .font(.system(.body, design: .monospaced))
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityLabel(k.spoken)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// Terminal text cleaned up for a phone: full-width rules (an agent's input box, separators)
/// become one thin line, trailing spaces go, and runs of blank lines collapse.
enum OutputBlock: Equatable {
    case text(String), rule

    static func parse(_ raw: String) -> [OutputBlock] {
        var out: [OutputBlock] = []
        var buf: [String] = []
        var blanks = 0
        func flush() {
            if !buf.isEmpty { out.append(.text(buf.joined(separator: "\n"))); buf = [] }
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            // Trailing padding goes; wide gaps (right-aligned prompts, status columns) shrink so
            // a 200-column line does not wrap into fragments on a phone.
            let l = String(line.reversed().drop { $0 == " " }.reversed())
                .replacingOccurrences(of: " {6,}", with: "   ", options: .regularExpression)
            if isRule(l) {
                flush()
                blanks = 0
                if out.last != .rule { out.append(.rule) }
            } else if l.isEmpty {
                blanks += 1
                if blanks == 1, !buf.isEmpty { buf.append("") }
            } else {
                blanks = 0
                buf.append(l)
            }
        }
        flush()
        while out.first == .rule { out.removeFirst() }
        return out
    }

    /// A line drawn only with box/rule characters, at least 8 of them.
    static func isRule(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 && t.allSatisfy { "─━═_—-╌┄╴╶▔▁".contains($0) }
    }
}

struct TerminalText: View {
    let blocks: [OutputBlock]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case let .text(t):
                    Text(t).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .rule:
                    Rectangle().fill(.separator).frame(height: 1).padding(.vertical, 2)
                }
            }
        }
    }
}
