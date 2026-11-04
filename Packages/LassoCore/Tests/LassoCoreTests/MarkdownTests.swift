import Foundation
@testable import LassoCore
import Testing

@Test func markdownBlocks() {
    let md = """
    # Title
    Intro line one
    line two

    - first
      continued
    - [x] done
    2. second

    ```swift
    let a = 1

    print(a)
    ```
    > quoted
    | a | b |
    |---|---|
    | 1 | 2 |
    ---
    """
    #expect(MarkdownBlock.parse(md) == [
        .heading(level: 1, text: "Title"),
        .paragraph("Intro line one\nline two"),
        .bullet(indent: 0, marker: "•", text: "first\ncontinued"),
        .bullet(indent: 0, marker: "☑", text: "done"),
        .bullet(indent: 0, marker: "2.", text: "second"),
        .code(language: "swift", text: "let a = 1\n\nprint(a)"),
        .quote("quoted"),
        .table(rows: [["a", "b"], ["1", "2"]]),
        .rule,
    ])
}

@Test func unclosedFenceStillRenders() {
    #expect(MarkdownBlock.parse("```\nx") == [.code(language: "", text: "x")])
}

@Test func uploadScriptWritesUnderCache() {
    let s = HostLink.uploadScript(name: "a b.png")
    #expect(s.contains(".cache/lasso/uploads"))
    #expect(s.contains("'a b.png'"))
}

@Test func findsGhosttyPastePaths() {
    let s = "\u{1B}[200~/private/var/mobile/Containers/Data/Application/8C/tmp/ghostty-paste/image-1.heic\u{1B}[201~"
    #expect(PastedFiles.localPaths(in: s) == ["/private/var/mobile/Containers/Data/Application/8C/tmp/ghostty-paste/image-1.heic"])
    #expect(PastedFiles.localPaths(in: "ls /tmp").isEmpty)
}

@Test func compactSummaryIsNotAUserMessage() {
    var t = ClaudeTranscript()
    t.feed(Data(#"{"type":"user","uuid":"u1","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}"#.utf8 + [0x0A]))
    #expect(t.items == [.compacted(id: "u1", text: "This session is being continued")])
}
