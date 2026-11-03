import Foundation

/// One herdr API request line: `{"id":"req_1","method":"ping","params":{}}\n`.
public struct HerdrRequest: Encodable, Sendable {
    public let id: String
    public let method: String
    public let params: JSONValue

    public init(id: String, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Encoded as exactly one NDJSON line (terminated by `\n`).
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

public struct HerdrError: Error, Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
}

/// Any line herdr writes: a response (`result` / `error`) or a streamed event.
/// Decoding is lenient — herdr publishes no stability guarantee, unknown fields are kept.
public enum HerdrMessage: Sendable, Equatable {
    case result(id: String, JSONValue)
    case failure(id: String, HerdrError)
    case event(name: String, data: JSONValue)

    public static func decode(line: Data) throws -> HerdrMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        guard case let .object(obj) = value else { throw DecodeError.notAnObject }
        let id = obj["id"]?.stringValue ?? ""
        if let result = obj["result"] { return .result(id: id, result) }
        if let err = obj["error"] {
            let data = try JSONEncoder().encode(err)
            let e = (try? JSONDecoder().decode(HerdrError.self, from: data))
                ?? HerdrError(code: "unknown", message: String(decoding: data, as: UTF8.self))
            return .failure(id: id, e)
        }
        if let name = obj["event"]?.stringValue { return .event(name: name, data: obj["data"] ?? .null) }
        throw DecodeError.unrecognised
    }

    public enum DecodeError: Error { case notAnObject, unrecognised }
}
