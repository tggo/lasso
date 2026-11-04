import Foundation

/// Block-level markdown, enough to lay out an agent's reply like a chat app does:
/// paragraphs, headings, lists, quotes, code blocks and tables. Inline styling is left to the UI.
public enum MarkdownBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case code(language: String, text: String)
    case table(rows: [[String]])
    case rule

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func parse(_ src: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: (lang: String, fence: String, lines: [String])?

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { out.append(.table(rows: table)); table = [] }
        }

        for raw in src.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if t.hasPrefix(c.fence), t.allSatisfy({ $0 == c.fence.first }) {
                    out.append(.code(language: c.lang, text: c.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    c.lines.append(line)
                    code = c
                }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let ch = t.first!
                let fence = String(t.prefix { $0 == ch })
                code = (String(t.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces), fence, [])
                continue
            }
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("|") {
                if table.isEmpty { flush() }
                let cells = t.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
                if !isSeparator { table.append(cells) }
                continue
            }
            if !table.isEmpty { flush() }
            if t.hasPrefix(">") {
                if !para.isEmpty { flush() }
                quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if !quote.isEmpty { flush() }
            if let h = heading(t) { flush(); out.append(h); continue }
            if t.count >= 3, Set(t.filter { $0 != " " }).count == 1, let f = t.first, "-*_".contains(f) {
                flush(); out.append(.rule); continue
            }
            if let b = bullet(line) { flush(); out.append(b); continue }
            // A continuation line of a list item joins that item.
            if para.isEmpty, case let .bullet(i, m, text)? = out.last, line.hasPrefix("  ") {
                out[out.count - 1] = .bullet(indent: i, marker: m, text: text + "\n" + t)
                continue
            }
            para.append(t)
        }
        if let c = code { out.append(.code(language: c.lang, text: c.lines.joined(separator: "\n"))) }
        flush()
        return out
    }

    static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: t.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    static func bullet(_ line: String) -> MarkdownBlock? {
        let lead = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(lead)
        let indent = lead / 2
        if let f = rest.first, "-*+".contains(f), rest.dropFirst().first == " " {
            var text = String(rest.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) } else if text.lowercased().hasPrefix("[x] ") {
                marker = "☑"; text.removeFirst(4)
            }
            return .bullet(indent: indent, marker: marker, text: text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return .bullet(indent: indent, marker: "\(digits).", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }
}
