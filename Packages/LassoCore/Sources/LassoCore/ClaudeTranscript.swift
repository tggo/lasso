import Foundation
import HerdrKit

/// One entry of a Claude Code conversation, as a chat UI shows it.
public enum ChatItem: Sendable, Equatable, Identifiable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)
    case tool(id: String, name: String, summary: String, result: String?, isError: Bool)

    public var id: String {
        switch self {
        case let .user(id, _), let .assistant(id, _), let .tool(id, _, _, _, _): id
        }
    }
}

/// Reads Claude Code's own session log (`~/.claude/projects/<dir>/<session>.jsonl`), the
/// same source Heeler uses: real messages and tool calls instead of a scraped screen.
/// Pure and incremental: feed it bytes as the file grows.
public struct ClaudeTranscript: Sendable, Equatable {
    public private(set) var items: [ChatItem] = []
    private var toolIndex: [String: Int] = [:]
    /// Bytes of an unfinished last line, kept until its newline arrives.
    private var pending = Data()
    public var maxItems = 300

    public init() {}

    /// Append newly read bytes. `dropFirstLine` skips a partial line when reading starts mid-file.
    public mutating func feed(_ data: Data, dropFirstLine: Bool = false) {
        var buf = pending + data
        if dropFirstLine, let nl = buf.firstIndex(of: 0x0A) { buf = buf[(nl + 1)...] }
        guard let last = buf.lastIndex(of: 0x0A) else { pending = Data(buf); return }
        pending = Data(buf[(last + 1)...])
        for line in buf[..<last].split(separator: 0x0A) {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            apply(v)
        }
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems)
            reindex()
        }
    }

    mutating func apply(_ v: JSONValue) {
        guard let type = v["type"]?.stringValue, type == "user" || type == "assistant",
              v["isSidechain"]?.boolValue != true, v["isMeta"]?.boolValue != true,
              let msg = v["message"] else { return }
        let uuid = v["uuid"]?.stringValue ?? UUID().uuidString
        let content = msg["content"]
        if let s = content?.stringValue {
            if type == "user" { addUser(uuid, s) } else { add(.assistant(id: uuid, text: s)) }
            return
        }
        guard case let .array(parts)? = content else { return }
        for (i, p) in parts.enumerated() {
            let pid = "\(uuid)#\(i)"
            switch p["type"]?.stringValue {
            case "text":
                guard let t = p["text"]?.stringValue else { continue }
                if type == "user" { addUser(pid, t) } else { add(.assistant(id: pid, text: t)) }
            case "tool_use":
                let toolID = p["id"]?.stringValue ?? pid
                let name = p["name"]?.stringValue ?? "tool"
                toolIndex[toolID] = items.count
                add(.tool(id: toolID, name: name, summary: Self.summary(name, p["input"]), result: nil, isError: false))
            case "tool_result":
                guard let toolID = p["tool_use_id"]?.stringValue, let idx = toolIndex[toolID], idx < items.count,
                      case let .tool(id, name, summary, _, _) = items[idx] else { continue }
                items[idx] = .tool(id: id, name: name, summary: summary, result: Self.text(p["content"]),
                                   isError: p["is_error"]?.boolValue ?? false)
            default: continue // thinking, images
            }
        }
    }

    private mutating func addUser(_ id: String, _ text: String) {
        // Claude Code wraps slash commands, hook output and reminders in tags; those are not the person typing.
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted") else { return }
        add(.user(id: id, text: t))
    }

    private mutating func add(_ item: ChatItem) { items.append(item) }

    private mutating func reindex() {
        toolIndex = [:]
        for (i, it) in items.enumerated() {
            if case let .tool(id, _, _, _, _) = it { toolIndex[id] = i }
        }
    }

    static func text(_ v: JSONValue?) -> String {
        switch v {
        case let .string(s)?: return s
        case let .array(a)?: return a.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return ""
        }
    }

    /// One line saying what a tool call does.
    static func summary(_ name: String, _ input: JSONValue?) -> String {
        func s(_ k: String) -> String? { input?[k]?.stringValue }
        let line: String? = switch name {
        case "Bash": s("description") ?? s("command")
        case "Read", "Write", "Edit", "NotebookEdit": s("file_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob": s("pattern")
        case "WebFetch": s("url")
        case "WebSearch": s("query")
        case "Agent", "Task": s("description")
        case "Skill": s("skill")
        default: nil
        }
        if let line { return line.components(separatedBy: "\n").first ?? line }
        if case let .object(o)? = input, let first = o.values.compactMap(\.stringValue).first {
            return first.components(separatedBy: "\n").first ?? first
        }
        return ""
    }
}

/// Where a Claude session's log is and how far it has been read.
public struct TranscriptCursor: Sendable, Equatable {
    public var path: String?
    public var offset: Int = 0
    public init() {}
}

public extension HostLink {
    /// Shell that finds the log of the Claude Code process `pid` (via `~/.claude/sessions/<pid>.json`)
    /// and prints `path size start`, a newline, then the bytes from `start` to `size`. A new path (first
    /// read, or `/clear` started a new session) starts at the last `window` bytes. Base64 payloads
    /// (screenshots) are blanked on the host so a few images don't crowd out the conversation.
    static func transcriptScript(pid: Int, path: String?, offset: Int, window: Int = 3_000_000) -> String {
        """
        s="$HOME/.claude/sessions/\(pid).json"; [ -f "$s" ] || exit 3
        id=$(sed -n 's/.*"sessionId":"\\([^"]*\\)".*/\\1/p' "$s"); [ -n "$id" ] || exit 3
        p=""; for f in "$HOME"/.claude/projects/*/"$id".jsonl; do [ -f "$f" ] && p="$f" && break; done
        [ -n "$p" ] || exit 4
        sz=$(wc -c < "$p" | tr -d ' ')
        if [ "$p" = \(shellQuote(path ?? "")) ] && [ \(offset) -le "$sz" ]; then st=\(offset); else st=$((sz > \(window) ? sz - \(window) : 0)); fi
        echo "$p $sz $st"; tail -c +$((st + 1)) "$p" | head -c $((sz - st)) | LC_ALL=C sed -E 's|"data":"[A-Za-z0-9+/=]{255}[A-Za-z0-9+/=]*"|"data":""|g'
        """
    }

    /// Read what is new in the Claude log for `pid`. Returns nil when that process has no log yet.
    func readTranscript(pid: Int, into t: inout ClaudeTranscript, cursor: inout TranscriptCursor) async throws -> Bool {
        let r = try await exec(Self.transcriptScript(pid: pid, path: cursor.path, offset: cursor.offset))
        guard r.exitCode == 0, let nl = r.stdout.firstIndex(of: 0x0A) else { return false }
        let head = String(decoding: r.stdout[..<nl], as: UTF8.self).split(separator: " ")
        guard head.count >= 3, let start = Int(head[head.count - 1]), let size = Int(head[head.count - 2]) else { return false }
        let path = head.dropLast(2).joined(separator: " ")
        let body = r.stdout[(nl + 1)...]
        let fresh = path != cursor.path || start != cursor.offset
        if fresh { t = ClaudeTranscript() }
        t.feed(Data(body), dropFirstLine: fresh && start > 0)
        cursor.path = path
        cursor.offset = size // body is filtered, so the raw end position comes from the host
        return true
    }
}
