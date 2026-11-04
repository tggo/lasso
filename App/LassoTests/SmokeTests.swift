@testable import Lasso
import Testing

@Test func appModuleLoads() { #expect(Bool(true)) }

@Test func outputRulesCollapseAndBlanksSqueeze() {
    let raw = "hello   \n\n\n\nworld\n" + String(repeating: "─", count: 60) + "\n" + String(repeating: "─", count: 60) + "\n❯ hi\n" + String(repeating: "_", count: 40)
    #expect(OutputBlock.parse(raw) == [.text("hello\n\nworld"), .rule, .text("❯ hi"), .rule])
    #expect(!OutputBlock.isRule("- a list item"))
    #expect(OutputBlock.parse("> $" + String(repeating: " ", count: 150) + "[main]") == [.text("> $   [main]")])
}
