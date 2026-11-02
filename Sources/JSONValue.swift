import Foundation

enum JSONValue: Codable, Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue {
        if case .object(let values) = self { return values[key] ?? .null }
        return .null
    }

    var stringValue: String {
        if case .string(let value) = self { return value }
        return ""
    }

    var boolValue: Bool {
        if case .bool(let value) = self { return value }
        return false
    }

    var numberValue: Double {
        if case .number(let value) = self { return value }
        return 0
    }

    var arrayValue: [JSONValue] {
        if case .array(let value) = self { return value }
        return []
    }

    var objectValue: [String: JSONValue] {
        if case .object(let value) = self { return value }
        return [:]
    }

    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct GoblinError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
