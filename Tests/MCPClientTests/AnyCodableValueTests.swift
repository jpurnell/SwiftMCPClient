import Testing
import Foundation
@testable import MCPClient

@Suite("AnyCodableValue")
struct AnyCodableValueTests {

    // MARK: - Golden Path: Encoding

    @Test("Encodes string value to JSON")
    func encodesString() throws {
        let value = AnyCodableValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "\"hello\"")
    }

    @Test("Encodes number value to JSON")
    func encodesNumber() throws {
        let value = AnyCodableValue.number(3.14)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "3.14" || json == "3.1400000000000001") // IEEE 754
    }

    @Test("Encodes integer value to JSON")
    func encodesInteger() throws {
        let value = AnyCodableValue.integer(42)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "42")
    }

    @Test("Encodes bool true to JSON")
    func encodesBoolTrue() throws {
        let value = AnyCodableValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "true")
    }

    @Test("Encodes bool false to JSON")
    func encodesBoolFalse() throws {
        let value = AnyCodableValue.bool(false)
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "false")
    }

    @Test("Encodes null to JSON")
    func encodesNull() throws {
        let value = AnyCodableValue.null
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "null")
    }

    @Test("Encodes array to JSON")
    func encodesArray() throws {
        let value = AnyCodableValue.array([.integer(1), .string("two"), .bool(true)])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "[1,\"two\",true]")
    }

    @Test("Encodes object to JSON")
    func encodesObject() throws {
        let value = AnyCodableValue.object(["key": .string("value")])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)
        #expect(json == "{\"key\":\"value\"}")
    }

    // MARK: - Golden Path: Decoding

    @Test("Decodes JSON string")
    func decodesString() throws {
        let data = "\"hello\"".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .string("hello"))
    }

    @Test("Decodes JSON number as number")
    func decodesNumber() throws {
        let data = "3.14".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .number(3.14))
    }

    @Test("Decodes JSON integer as integer")
    func decodesInteger() throws {
        let data = "42".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .integer(42))
    }

    @Test("Decodes JSON true as bool")
    func decodesBoolTrue() throws {
        let data = "true".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .bool(true))
    }

    @Test("Decodes JSON false as bool")
    func decodesBoolFalse() throws {
        let data = "false".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .bool(false))
    }

    @Test("Decodes JSON null")
    func decodesNull() throws {
        let data = "null".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .null)
    }

    @Test("Decodes JSON array")
    func decodesArray() throws {
        let data = "[1, \"two\", true]".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .array([.integer(1), .string("two"), .bool(true)]))
    }

    @Test("Decodes JSON object")
    func decodesObject() throws {
        let data = "{\"key\": \"value\"}".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .object(["key": .string("value")]))
    }

    // MARK: - Edge Cases

    @Test("Decodes nested objects")
    func decodesNestedObjects() throws {
        let json = """
        {"outer": {"inner": [1, 2, 3]}}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        let expected = AnyCodableValue.object([
            "outer": .object([
                "inner": .array([.integer(1), .integer(2), .integer(3)])
            ])
        ])
        #expect(value == expected)
    }

    @Test("Decodes empty object")
    func decodesEmptyObject() throws {
        let data = "{}".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .object([:]))
    }

    @Test("Decodes empty array")
    func decodesEmptyArray() throws {
        let data = "[]".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .array([]))
    }

    @Test("Decodes empty string")
    func decodesEmptyString() throws {
        let data = "\"\"".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .string(""))
    }

    @Test("Decodes zero as integer")
    func decodesZero() throws {
        let data = "0".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .integer(0))
    }

    @Test("Decodes negative integer")
    func decodesNegativeInteger() throws {
        let data = "-5".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .integer(-5))
    }

    @Test("Decodes negative float")
    func decodesNegativeFloat() throws {
        let data = "-3.14".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .number(-3.14))
    }

    @Test("Decodes very large integer")
    func decodesLargeInteger() throws {
        let data = "999999999".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .integer(999999999))
    }

    // MARK: - Round-trip

    @Test("Round-trips complex nested structure")
    func roundTripsComplex() throws {
        let original = AnyCodableValue.object([
            "name": .string("test"),
            "count": .integer(42),
            "rate": .number(0.95),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .null
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Equatable

    @Test("Values of different types are not equal")
    func differentTypesNotEqual() {
        #expect(AnyCodableValue.string("1") != AnyCodableValue.integer(1))
        #expect(AnyCodableValue.integer(1) != AnyCodableValue.number(1.0))
        #expect(AnyCodableValue.bool(true) != AnyCodableValue.integer(1))
        #expect(AnyCodableValue.null != AnyCodableValue.string("null"))
    }
}
