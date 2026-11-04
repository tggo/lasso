import LassoCore
import SwiftUI

/// A Claude Code conversation as chat: the person's messages in bubbles, the agent's replies
/// as plain text, tool calls as compact rows that expand to their output.
struct ChatView: View {
    let items: [ChatItem]
    let working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.group(items), id: \.first!.id) { run in
                if run.count >= 3 {
                    StepGroup(items: run, working: working, lastToolID: lastToolID)
                } else {
                    ForEach(run) { row($0) }
                }
            }
            if working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder func row(_ item: ChatItem) -> some View {
        Self.row(item, working: working, lastToolID: lastToolID)
    }

    @ViewBuilder static func row(_ item: ChatItem, working: Bool, lastToolID: String?) -> some View {
        switch item {
        case let .user(_, text): UserBubble(text: text)
        case let .assistant(_, text): AssistantText(text: text)
        case let .tool(_, name, summary, result, isError):
            ToolRow(name: name, summary: summary, result: result, isError: isError,
                    running: result == nil && working && item.id == lastToolID)
        }
    }

    /// Consecutive tool calls form one run; every other item is a run of one.
    static func group(_ items: [ChatItem]) -> [[ChatItem]] {
        var out: [[ChatItem]] = []
        for it in items {
            if case .tool = it, let last = out.last?.last, case .tool = last { out[out.count - 1].append(it) } else { out.append([it]) }
        }
        return out
    }

    private var lastToolID: String? {
        items.last { if case .tool = $0 { true } else { false } }?.id
    }
}

/// Several tool calls in a row, collapsed to one line; the newest step stays visible.
private struct StepGroup: View {
    let items: [ChatItem]
    let working: Bool
    let lastToolID: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("\(items.count - (open ? 0 : 1)) steps").font(.caption.weight(.semibold))
                    Text(names).font(.caption).lineLimit(1)
                    if failed > 0 { Text("· \(failed) failed").font(.caption).foregroundStyle(.red) }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            ForEach(open ? items : [items[items.count - 1]]) { ChatView.row($0, working: working, lastToolID: lastToolID) }
        }
    }

    private var names: String {
        var seen: [String] = []
        for case let .tool(_, n, _, _, _) in items where !seen.contains(n) { seen.append(n) }
        return seen.joined(separator: ", ")
    }

    private var failed: Int { items.count { if case let .tool(_, _, _, _, e) = $0 { e } else { false } } }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                .textSelection(.enabled)
        }
    }
}

private struct AssistantText: View {
    let text: String
    var body: some View {
        Text(Self.markdown(text))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Inline markdown (bold, code, links) with line breaks kept; falls back to plain text.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct ToolRow: View {
    let name: String
    let summary: String
    let result: String?
    let isError: Bool
    let running: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    Text(name).font(.caption.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if running { ProgressView().controlSize(.mini) }
                    else if isError { Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red) }
                    if result != nil {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(result == nil)
            .accessibilityLabel("\(name): \(summary)\(isError ? ", failed" : "")")
            if open, let result {
                Text(Self.clip(result))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(isError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
        }
    }

    private var icon: String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write", "Edit", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    static func clip(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 40 ? lines.prefix(40).joined(separator: "\n") + "\n… \(lines.count - 40) more lines" : s
    }
}
