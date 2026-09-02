import Foundation

/// Carries a JSON-RPC body value safely in an HTTP header.
///
/// MCP 2026-07-28 mirrors selected body fields into headers — `Mcp-Method`, `Mcp-Name`,
/// `Mcp-Param-*` — so that load balancers and gateways can route and inspect a request without
/// parsing it. A server that reads the body **MUST** reject a request whose headers disagree
/// with it, returning `400` and `HeaderMismatch`.
///
/// That makes this encoding load-bearing rather than cosmetic: a value encoded differently from
/// how the server decodes it is a rejected request that was otherwise perfectly good.
///
/// RFC 9110 limits header values to visible ASCII, space and tab. Anything outside that travels
/// Base64 inside a sentinel — `=?base64?…?=` — and so does anything that would be ambiguous
/// left alone.
enum MCPHeaderValue {

    /// The exact, case-sensitive markers. A value that merely resembles them is data.
    private static let prefix = "=?base64?"
    private static let suffix = "?="

    /// Encodes a value for a header, leaving it alone when it is already safe.
    ///
    /// Values that are safe travel unchanged deliberately. Encoding everything would work on
    /// the wire and make every header opaque to the intermediaries this mechanism exists for.
    ///
    /// - Parameter value: The value as it appears in the request body.
    /// - Returns: Either the value itself, or a `=?base64?…?=` envelope.
    static func encode(_ value: String) -> String {
        guard needsEncoding(value) else { return value }
        return prefix + Data(value.utf8).base64EncodedString() + suffix
    }

    /// Recovers a value a server or intermediary would compare against the body.
    ///
    /// A value that is not an envelope is returned unchanged, and so is an envelope whose
    /// contents will not decode. Something malformed is still evidence; turning it into an
    /// empty string would make a mismatch look like an empty field.
    ///
    /// - Parameter header: The header value as received.
    /// - Returns: The value it represents.
    static func decode(_ header: String) -> String {
        guard header.hasPrefix(prefix), header.hasSuffix(suffix),
              header.count > prefix.count + suffix.count else {
            return header
        }
        let encoded = String(header.dropFirst(prefix.count).dropLast(suffix.count))
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return header
        }
        return decoded
    }

    /// Whether a value can travel as-is.
    ///
    /// Three reasons it cannot, and the third is the one a reader skips: characters outside
    /// what RFC 9110 permits; leading or trailing whitespace, which an intermediary may strip
    /// and thereby change; and a value that *already looks like* the sentinel, which a decoder
    /// would unwrap into something the body never contained.
    private static func needsEncoding(_ value: String) -> Bool {
        if value.hasPrefix(prefix) && value.hasSuffix(suffix) { return true }
        if value != value.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        return value.unicodeScalars.contains { scalar in
            // Visible ASCII, space, and horizontal tab — RFC 9110 field values.
            !(scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7E))
        }
    }
}
