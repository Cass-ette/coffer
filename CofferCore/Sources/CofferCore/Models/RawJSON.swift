import Foundation

/// Dynamic JSON used to preserve payloads from newer Coffer versions.
public enum RawJSON: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([RawJSON]), object([String: RawJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if container.decodeNil() { self = .null }
        else if let value = try? container.decode([RawJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: RawJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var jsonData: Data? { try? JSONEncoder().encode(self) }
    public static func from(_ data: Data) -> RawJSON? {
        try? JSONDecoder().decode(RawJSON.self, from: data)
    }
}
