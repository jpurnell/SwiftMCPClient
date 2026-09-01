import Foundation

/// Turns a Streamable HTTP response body into zero or more JSON-RPC payloads.
///
/// A server answering a `POST` may reply with a single JSON object
/// (`application/json`) or with an SSE stream (`text/event-stream`) carrying one or
/// more messages. MCP spec 2025-03-26 permits both, and a transport that advertises
/// `Accept: application/json, text/event-stream` has promised to handle either.
///
/// Framing is separated from transport deliberately. It is the part that is easy to get
/// wrong — `charset` parameters, header casing, `data:` fields split across lines — and
/// the only part testable without a network or a server we control.
struct StreamableHTTPBodyDecoder: Sendable {

    /// The media type that means "this body is a stream of events, not one document".
    private static let eventStream = "text/event-stream"

    /// Decodes a complete response body into the JSON-RPC payloads it carries.
    ///
    /// - Parameters:
    ///   - body: The collected response body. May be empty.
    ///   - contentType: The response `Content-Type` header, if the server sent one.
    ///     Matching ignores case and any parameters, so `text/event-stream; charset=utf-8`
    ///     is recognised. An absent or unrecognised type is treated as JSON, which
    ///     preserves the behaviour of servers already working against this transport.
    /// - Returns: Payloads in the order the server sent them. Empty when the body is empty
    ///   or contains only comments and keep-alives.
    /// - Throws: ``MCPError/invalidResponse`` when an SSE body is not valid UTF-8.
    static func decode(body: Data, contentType: String?) throws -> [Data] {
        guard !body.isEmpty else { return [] }
        guard isEventStream(contentType) else { return [body] }

        // Defaulting to an empty string here would turn a transport fault into an
        // inexplicable "no response" much further downstream.
        guard let text = String(data: body, encoding: .utf8) else {
            throw MCPError.invalidResponse
        }

        var parser = SSEParser()
        return parser.append(text).map { Data($0.data.utf8) }
    }

    /// Whether a `Content-Type` names the SSE media type.
    ///
    /// Compares the essence only: everything before the first `;` is taken, trimmed, and
    /// lowercased. A direct string comparison against the header value fails on
    /// `text/event-stream; charset=utf-8`, which is what most servers actually send.
    ///
    /// - Parameter contentType: The raw header value, if present.
    /// - Returns: `true` when the type is `text/event-stream`.
    static func isEventStream(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let essence = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return essence == eventStream
    }
}
