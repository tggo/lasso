import Foundation

/// Cleans the byte stream of `herdr agent attach` before it reaches the terminal emulator:
/// 1. drops everything before Lasso's start marker (motd, shell rc noise);
/// 2. for a short window after the marker, drops herdr's own startup probes of the
///    outer terminal (DA1 `CSI c`, DA2 `CSI > c`, DECRQM `CSI ? Ps $ p`). Answering them
///    makes the replies land in the pane as typed input (`1016;2$y62;22;52c`).
public final class AttachFilter: @unchecked Sendable {
    public static let marker = Data("\u{1B}]lasso-start\u{07}".utf8)
    private let lock = NSLock()
    private var seen = false
    private var buffer = Data()
    private var probeWindowEnd: Date?
    private let window: TimeInterval
    private let now: () -> Date

    public init(probeWindow: TimeInterval = 2, now: @escaping () -> Date = Date.init) {
        window = probeWindow
        self.now = now
    }

    public func feed(_ data: Data) -> Data? {
        lock.withLock {
            var out: Data
            if seen {
                out = data
            } else {
                buffer.append(data)
                guard let r = buffer.range(of: Self.marker) else {
                    if buffer.count > 1 << 20 { seen = true; let b = buffer; buffer = Data(); return b }
                    return nil
                }
                seen = true
                probeWindowEnd = now().addingTimeInterval(window)
                out = buffer.subdata(in: r.upperBound ..< buffer.endIndex)
                buffer = Data()
            }
            if let end = probeWindowEnd, now() < end { out = Self.stripProbes(out) }
            return out.isEmpty ? nil : out
        }
    }

    static func stripProbes(_ d: Data) -> Data {
        let b = [UInt8](d)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            if b[i] == 0x1B, i + 1 < b.count, b[i + 1] == 0x5B, let end = probeEnd(b, from: i + 2) {
                i = end
                continue
            }
            out.append(b[i])
            i += 1
        }
        return Data(out)
    }

    /// If `b[from...]` is the body of a probe CSI, return the index after it.
    private static func probeEnd(_ b: [UInt8], from: Int) -> Int? {
        var j = from
        var prefix: UInt8?
        if j < b.count, b[j] == 0x3F || b[j] == 0x3E { prefix = b[j]; j += 1 } // ? or >
        while j < b.count, (0x30 ... 0x39).contains(b[j]) || b[j] == 0x3B {
            j += 1
        }
        guard j < b.count else { return nil }
        if b[j] == 0x63, prefix != 0x3F { return j + 1 } // DA1 / DA2: CSI [>] [0] c
        if prefix == 0x3F, b[j] == 0x24, j + 1 < b.count, b[j + 1] == 0x70 { return j + 2 } // DECRQM: CSI ? Ps $ p
        return nil
    }
}
