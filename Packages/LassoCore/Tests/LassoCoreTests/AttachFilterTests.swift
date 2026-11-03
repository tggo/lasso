import Foundation
@testable import LassoCore
import Testing

private func s(_ d: Data?) -> String { d.map { String(decoding: $0, as: UTF8.self) } ?? "" }

@Test func dropsNoiseBeforeMarkerAcrossChunks() {
    let f = AttachFilter()
    #expect(f.feed(Data("motd\u{1B}]lasso".utf8)) == nil)
    #expect(s(f.feed(Data("-start\u{07}hello".utf8))) == "hello")
    #expect(s(f.feed(Data("world".utf8))) == "world")
}

@Test func stripsStartupProbesButKeepsOtherCSI() {
    let f = AttachFilter()
    let input = "\u{1B}]lasso-start\u{07}\u{1B}[?1016$p\u{1B}[c\u{1B}[>0c\u{1B}[31mred\u{1B}[0m\u{1B}[2J"
    #expect(s(f.feed(Data(input.utf8))) == "\u{1B}[31mred\u{1B}[0m\u{1B}[2J")
}

@Test func probesPassAfterWindow() {
    var t = Date()
    let f = AttachFilter(probeWindow: 1, now: { t })
    _ = f.feed(Data("\u{1B}]lasso-start\u{07}".utf8))
    t = t.addingTimeInterval(2)
    #expect(s(f.feed(Data("\u{1B}[c".utf8))) == "\u{1B}[c")
}
