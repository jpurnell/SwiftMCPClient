import Foundation
import Testing
@testable import MCPClient

/// Framing a Streamable HTTP response body.
///
/// The transport advertises `Accept: application/json, text/event-stream` and must therefore
/// handle both. The failure this guards against is silent: an SSE body handed straight to
/// `JSONDecoder` fails on the first tool call of a session, long after connect, with an error
/// that points at the payload rather than at the framing.
///
/// Vectors follow MCP spec 2025-03-26 (Transports → Streamable HTTP) and the W3C
/// `text/event-stream` framing rules already implemented by ``SSEParser``.
@Suite("Streamable HTTP body decoding")
struct StreamableHTTPBodyDecoderTests {

    private static let payload = #"{"jsonrpc":"2.0","id":1,"result":{}}"#

    // MARK: - JSON bodies

    @Test("A JSON body is passed through byte-identical")
    func jsonBodyPassesThrough() throws {
        let body = Data(Self.payload.utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "application/json")

        #expect(decoded.count == 1)
        #expect(decoded.first == body)
    }

    /// Preserves today's behaviour for any server already working against this transport.
    /// Refusing an unlabelled body would be a regression dressed as strictness.
    @Test("An absent content type is treated as JSON")
    func absentContentTypeFallsBackToJSON() throws {
        let body = Data(Self.payload.utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: nil)

        #expect(decoded == [body])
    }

    @Test("An unrecognised content type is treated as JSON")
    func unrecognisedContentTypeFallsBackToJSON() throws {
        let body = Data(Self.payload.utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "application/octet-stream")

        #expect(decoded == [body])
    }

    // MARK: - SSE bodies

    @Test("A single SSE event yields its data field")
    func singleSSEEvent() throws {
        let body = Data("event: message\ndata: \(Self.payload)\n\n".utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "text/event-stream")

        #expect(decoded.count == 1)
        #expect(decoded.first == Data(Self.payload.utf8))
    }

    /// Order is the contract. JSON-RPC correlates by `id`, but a client that reorders
    /// notifications relative to responses reports progress for work already finished.
    @Test("Multiple SSE events are returned in the order sent")
    func multipleSSEEventsKeepOrder() throws {
        let first = #"{"jsonrpc":"2.0","id":1,"result":{"step":1}}"#
        let second = #"{"jsonrpc":"2.0","id":2,"result":{"step":2}}"#
        let body = Data("data: \(first)\n\ndata: \(second)\n\n".utf8)

        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "text/event-stream")

        #expect(decoded == [Data(first.utf8), Data(second.utf8)])
    }

    /// The vector a naive `contentType == "text/event-stream"` comparison fails, and the one
    /// most servers actually send.
    @Test("A charset parameter does not defeat the match")
    func charsetParameterIsIgnored() throws {
        let body = Data("data: \(Self.payload)\n\n".utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(
            body: body, contentType: "text/event-stream; charset=utf-8")

        #expect(decoded == [Data(Self.payload.utf8)])
    }

    @Test("Content type matching ignores case")
    func matchingIsCaseInsensitive() throws {
        let body = Data("data: \(Self.payload)\n\n".utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "TEXT/EVENT-STREAM")

        #expect(decoded == [Data(Self.payload.utf8)])
    }

    @Test("Surrounding whitespace in the content type is tolerated")
    func matchingTrimsWhitespace() throws {
        let body = Data("data: \(Self.payload)\n\n".utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "  text/event-stream  ")

        #expect(decoded == [Data(Self.payload.utf8)])
    }

    /// A JSON payload wider than the SSE line limit arrives split across `data:` lines and is
    /// only valid once rejoined with newlines.
    @Test("Multi-line data fields are joined with newlines")
    func multiLineDataIsJoined() throws {
        let body = Data("data: {\"a\":\ndata: 1}\n\n".utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "text/event-stream")

        #expect(decoded == [Data("{\"a\":\n1}".utf8)])
    }

    /// Keep-alive comments arrive on idle streams. Enqueuing them would push an undecodable
    /// payload at the dispatcher for every heartbeat.
    @Test("Comment-only events produce no payload")
    func commentOnlyEventsAreDiscarded() throws {
        let body = Data(": keepalive\n\n".utf8)
        let decoded = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "text/event-stream")

        #expect(decoded.isEmpty)
    }

    // MARK: - Edge cases

    /// A `202 Accepted` for a notification has no body. That is success, not an error.
    @Test("An empty body yields no payloads and does not throw")
    func emptyBodyIsNotAnError() throws {
        #expect(try StreamableHTTPBodyDecoder.decode(body: Data(), contentType: "application/json").isEmpty)
        #expect(try StreamableHTTPBodyDecoder.decode(body: Data(), contentType: "text/event-stream").isEmpty)
    }

    /// Defaulting to an empty string here would turn a transport fault into an inexplicable
    /// "no response" much further downstream.
    @Test("An SSE body that is not valid UTF-8 throws")
    func invalidUTF8Throws() {
        let body = Data([0xFF, 0xFE, 0xFD])

        #expect(throws: MCPError.self) {
            _ = try StreamableHTTPBodyDecoder.decode(body: body, contentType: "text/event-stream")
        }
    }
}
