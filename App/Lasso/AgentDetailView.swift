import HerdrKit
import LassoCore
import PhotosUI
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
    @State private var transcript = ClaudeTranscript()
    @State private var cursor = TranscriptCursor()
    @State private var hasChat = false
    @State private var showScreen = false
    @FocusState private var composerFocused: Bool
    @State private var images: [Attachment] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showPasteHint = false
    @AppStorage("pasteHintShown") private var pasteHintShown = false

    var body: some View {
        let store = model.store(for: host)
        let agent = store.agent(paneID)
        VStack(spacing: 0) {
            ScrollView {
                if hasChat && !showScreen {
                    ChatView(items: transcript.items, working: agent?.agentStatus == .working)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                } else {
                    TerminalText(blocks: OutputBlock.parse(output))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            // Sticks to the bottom only while the user is already there; reading history is not interrupted.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            if let error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { pollNonce += 1 }.font(.caption)
                }
                .padding(.horizontal)
            }
            if hasChat, !showScreen, agent?.agentStatus == .blocked {
                BlockedCard(screen: output)
            }
            KeyBar(blocked: agent?.agentStatus == .blocked) { keys in send { try await store.client.sendKeys(paneID, keys) } }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images) { att in
                            Image(uiImage: att.image).resizable().scaledToFill()
                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.removeAll { $0.id == att.id } } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .accessibilityLabel("Remove image")
                                    .padding(2)
                                }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button { showPicker = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
                    Button {
                        guard let img = UIPasteboard.general.image else { error = "No image on the clipboard."; return }
                        images.append(Attachment(image: img))
                        if !pasteHintShown { pasteHintShown = true; showPasteHint = true }
                    } label: { Label("Paste image from clipboard", systemImage: "doc.on.clipboard") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title).foregroundStyle(.secondary)
                        .frame(minWidth: 40, minHeight: 44)
                }
                .accessibilityLabel("Attach")
                TextField(agent?.agentStatus == .blocked ? "Answer…" : "Message…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .focused($composerFocused)
                if composerFocused {
                    Button { composerFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.title3)
                            .frame(minWidth: 40, minHeight: 44)
                    }
                    .accessibilityLabel("Hide keyboard")
                }
                Button {
                    let text = draft, imgs = images
                    draft = ""
                    images = []
                    send(restoring: text, images: imgs) {
                        var paths: [String] = []
                        if !imgs.isEmpty {
                            guard let link = store.client.transport as? HostLink else { throw HerdrClientError.unsupported("image upload needs SSH") }
                            for att in imgs {
                                guard let data = att.image.jpegData(compressionQuality: 0.85) else {
                                    throw HerdrClientError.unexpected("could not encode an image")
                                }
                                paths.append(try await link.upload(data, name: "\(UUID().uuidString).jpg"))
                            }
                        }
                        let full = (paths + [text]).filter { !$0.isEmpty }.joined(separator: " ")
                        try await store.client.prompt(paneID, text: full, isAgent: agent != nil && agent?.agentStatus != .blocked)
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                    .disabled((draft.trimmingCharacters(in: .whitespaces).isEmpty && images.isEmpty) || sending)
                    .accessibilityLabel("Send")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .alert("Paste without asking", isPresented: $showPasteHint) {
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("iOS asks before every paste. To stop it: Settings → Lasso → Paste from Other Apps → Allow. "
                + "This also covers pasting images in the terminal.")
        }
        .photosPicker(isPresented: $showPicker, selection: $picked, maxSelectionCount: 5, matching: .images)
        .onChange(of: picked) { _, items in
            Task { @MainActor in
                for it in items {
                    if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) { images.append(Attachment(image: img)) }
                }
                picked = []
            }
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
            if hasChat {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showScreen.toggle() } label: {
                        Image(systemName: showScreen ? "bubble.left.and.bubble.right" : "rectangle.and.text.magnifyingglass")
                    }
                    .accessibilityLabel(showScreen ? "Show chat" : "Show screen")
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
                let a = store.agent(paneID)
                if let pid = a?.pid, a?.agent == "claude-code", let link = store.client.transport as? HostLink {
                    var t = transcript, c = cursor
                    // A failed or empty read keeps the chat already shown instead of flipping to the screen.
                    if (try? await link.readTranscript(pid: pid, into: &t, cursor: &c)) == true {
                        if t != transcript { transcript = t }
                        cursor = c
                        hasChat = true
                    }
                }
                // The screen is still needed for a blocked dialog, the Screen view, and non-Claude panes.
                if !hasChat || showScreen || a?.agentStatus == .blocked {
                    let r = try await store.client.read(paneID, source: .recent, lines: 200)
                    if r.text != output { output = r.text }
                }
                error = nil
            } catch { self.error = friendly(error) }
            try? await Task.sleep(for: .seconds(store.agent(paneID)?.agentStatus == .working ? 1.5 : 4))
        }
    }

    private func send(restoring text: String? = nil, images restore: [Attachment] = [], _ op: @escaping @MainActor () async throws -> Void) {
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do { try await op(); error = nil } catch {
                self.error = friendly(error)
                if let text, draft.isEmpty { draft = text } // don't lose what was typed
                if images.isEmpty { images = restore } // nor what was attached
            }
        }
    }
}

/// What a blocked agent is asking, taken from the bottom of its screen.
struct BlockedCard: View {
    let screen: String
    var body: some View {
        let lines = OutputBlock.parse(screen).suffix(4)
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs you", systemImage: "hand.raised.fill").font(.caption.weight(.semibold))
                .foregroundStyle(AgentStatus.blocked.textColor)
            ScrollView { TerminalText(blocks: Array(lines)) }.frame(maxHeight: 180)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10).padding(.bottom, 6)
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

/// An image waiting in the composer; the id keeps thumbnails stable while others are removed.
struct Attachment: Identifiable {
    let id = UUID()
    let image: UIImage
}
