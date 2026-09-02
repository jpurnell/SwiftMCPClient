import Foundation
import Testing
@testable import MCPClient

/// Encoding a body value so it can safely travel as an HTTP header.
///
/// MCP 2026-07-28 mirrors selected JSON-RPC fields into headers so intermediaries can route on
/// them without parsing the body — and servers **MUST** reject a request whose headers do not
/// match its body. So this encoding is not cosmetic: get it wrong and a conforming server
/// answers `400 HeaderMismatch` for a request that was otherwise perfectly good.
///
/// Header values are limited to visible ASCII, space and tab (RFC 9110). Anything else travels
/// Base64 inside a sentinel, `=?base64?…?=`.
@Suite("MCP header values")
struct MCPHeaderValueTests {

    /// The specification's own examples, used as vectors. A value that is already safe travels
    /// unchanged — encoding everything would work on the wire and make every header unreadable
    /// to the intermediaries this mechanism exists to serve.
    @Test("The specification's examples encode as it says", arguments: [
        ("us-west1", "us-west1"),
        ("Hello, 世界", "=?base64?SGVsbG8sIOS4lueVjA==?="),
        (" padded ", "=?base64?IHBhZGRlZCA=?="),
        ("line1\nline2", "=?base64?bGluZTEKbGluZTI=?="),
        ("=?base64?literal?=", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
    ])
    func specificationVectors(value: String, expected: String) {
        #expect(MCPHeaderValue.encode(value) == expected)
    }

    /// The self-referential rule, stated on its own because it is the one a reader skips: a
    /// value that is *already* plain ASCII must still be encoded if it looks like the sentinel.
    /// Otherwise a server decoding it would recover something the body never contained, and the
    /// two would disagree.
    @Test("A value that looks like the sentinel is encoded anyway")
    func sentinelLookalikeIsEncoded() {
        let encoded = MCPHeaderValue.encode("=?base64?literal?=")

        #expect(encoded != "=?base64?literal?=")
        #expect(MCPHeaderValue.decode(encoded) == "=?base64?literal?=")
    }

    /// Round-tripping is the property that matters, since the server decodes before comparing.
    @Test("Every value survives a round trip", arguments: [
        "tools/call", "get_weather", "file:///projects/app/config.json",
        "Hello, 世界", " padded ", "line1\nline2", "=?base64?literal?=", "", "\u{9}tab"
    ])
    func roundTrips(value: String) {
        #expect(MCPHeaderValue.decode(MCPHeaderValue.encode(value)) == value)
    }

    /// A plain value is returned untouched by the decoder — a server sends most values
    /// unencoded, and treating them as Base64 would mangle them.
    @Test("A plain value decodes to itself")
    func plainValueDecodesToItself() {
        #expect(MCPHeaderValue.decode("tools/call") == "tools/call")
    }

    /// The markers are case-sensitive and exact. A value that merely resembles them is data,
    /// not an envelope.
    @Test("A near-miss sentinel is not treated as one")
    func nearMissIsNotASentinel() {
        #expect(MCPHeaderValue.decode("=?BASE64?dGVzdA==?=") == "=?BASE64?dGVzdA==?=")
        #expect(MCPHeaderValue.decode("=?base64?dGVzdA==") == "=?base64?dGVzdA==")
    }

    /// A sentinel whose contents are not valid Base64 is returned as it arrived rather than
    /// discarded. Something malformed is still evidence; silently producing an empty string
    /// would make a mismatch look like an empty field.
    @Test("An unreadable sentinel is left alone")
    func unreadableSentinelIsLeftAlone() {
        #expect(MCPHeaderValue.decode("=?base64?not base64!?=") == "=?base64?not base64!?=")
    }
}
