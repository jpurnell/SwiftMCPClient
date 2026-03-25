import Foundation

/// A type-safe representation of JSON values for MCP tool arguments and results.
///
/// `AnyCodableValue` wraps the full range of JSON types into a single Swift enum
/// that conforms to `Codable`, `Sendable`, and `Equatable`. It is the primary
/// type used to pass arguments to MCP tools and to receive results.
///
/// ## Usage
///
/// Build tool arguments as a dictionary of `AnyCodableValue`:
///
/// ```swift
/// let arguments: [String: AnyCodableValue] = [
///     "ssr_score": .number(95),
///     "meta_tags_score": .number(75),
///     "crawlability_score": .number(95)
/// ]
/// let result = try await client.callTool(
///     name: "score_technical_seo",
///     arguments: arguments
/// )
/// ```
///
/// Decode arbitrary JSON responses:
///
/// ```swift
/// let data = """
/// {"score": 74.8, "grade": "C", "components": [1, 2, 3]}
/// """.data(using: .utf8)!
/// let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
/// ```
///
/// ## MCP Schema
///
/// Maps directly to JSON Schema types:
/// - `.string` → `"type": "string"`
/// - `.number` → `"type": "number"`
/// - `.integer` → `"type": "integer"`
/// - `.bool` → `"type": "boolean"`
/// - `.object` → `"type": "object"`
/// - `.array` → `"type": "array"`
/// - `.null` → `"type": "null"`
public enum AnyCodableValue: Sendable, Equatable {
    /// A JSON string value.
    case string(String)

    /// A JSON floating-point number value.
    case number(Double)

    /// A JSON integer value.
    case integer(Int)

    /// A JSON boolean value.
    case bool(Bool)

    /// A JSON object (dictionary of string keys to values).
    case object([String: AnyCodableValue])

    /// A JSON array of values.
    case array([AnyCodableValue])

    /// A JSON null value.
    case null
}

// MARK: - Codable

extension AnyCodableValue: Codable {

    /// Decodes a JSON value into the appropriate `AnyCodableValue` case.
    ///
    /// The decoder attempts types in this order to ensure correct disambiguation:
    /// null → bool → integer → double → string → array → object.
    ///
    /// - Parameter decoder: The decoder to read data from.
    /// - Throws: `DecodingError.typeMismatch` if no JSON type matches.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        // Try bool before int/double since Bool can be decoded as Int
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }

        if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
            return
        }

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let arrayValue = try? container.decode([AnyCodableValue].self) {
            self = .array(arrayValue)
            return
        }

        if let objectValue = try? container.decode([String: AnyCodableValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.typeMismatch(
            AnyCodableValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode AnyCodableValue"
            )
        )
    }

    /// Encodes this value into the given encoder as its native JSON type.
    ///
    /// - Parameter encoder: The encoder to write data to.
    /// - Throws: An error if encoding fails.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
