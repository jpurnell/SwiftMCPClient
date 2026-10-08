import Foundation
#if canImport(FoundationNetworking)
// `HTTPURLResponse` lives here on Linux rather than in Foundation. Without this the file does
// not compile there — which is what broke the Linux build when this file was added.
import FoundationNetworking
#endif
import Testing
import NIOHTTP1
@testable import MCPClient

/// What a failed request says about where it was going.
///
/// An error's text does not stay where it was thrown: it is logged, shown in an alert, pasted
/// into an issue. A URL's query is where a legacy HTTP+SSE session id lives, and where an API
/// key ends up when a server documents `?key=…`; a response's headers are the server's to
/// fill. None of that belongs in a message, so each test here fails a request on purpose and
/// reads every rendering of the error for the value that must not be in it.
@Suite("Error text — no session id, key or header value")
struct TransportErrorRedactionTests {

    /// Every way an error is turned into text.
    private static func renderings(of error: any Error) -> [String] {
        [String(describing: error), String(reflecting: error), error.localizedDescription]
    }

    /// The reported defect. The legacy endpoint is `/messages?sessionId=…`, the server
    /// answers a POST `500`, and the message used to be the whole URL.
    @Test("A failed POST to a legacy endpoint does not name its session id",
          .timeLimit(.minutes(1)))
    func legacyEndpointQueryIsNotInTheError() async throws {
        let server = try await RedirectStubServer.start(
            kind: .legacySSE,
            postReply: .status(.internalServerError),
            endpoint: "/messages?sessionId=\(Watched.session)")
        let transport = HTTPSSETransport(
            url: try await server.url, connectionTimeout: 5, maxReconnectAttempts: 0)
        try await transport.connect()

        var caught: (any Error)?
        do {
            try await transport.send(Watched.body)
        } catch {
            caught = error
        }
        let error = try #require(caught, "a 500 was reported as success")
        // The request did go where the server said, session id and all.
        #expect(await server.requests.last?.target == "/messages?sessionId=\(Watched.session)")

        for text in Self.renderings(of: error) {
            #expect(!text.contains(Watched.session), "the error carries the session id: \(text)")
        }
        guard case .requestFailed(let code, let message, _) = error as? MCPError else {
            Issue.record("expected requestFailed, got \(error)")
            return
        }
        #expect(code == 500)
        // Still says which endpoint, which is the part worth having.
        #expect(message == "HTTP 500 from POST to http://127.0.0.1:\(try await server.port)/messages")
        try await transport.disconnect()
        await server.stop()
    }

    /// The same message on the other transport, where the URL is the caller's own — and
    /// where a key in its query is the caller's own secret.
    @Test("A failed Streamable HTTP POST does not name the configured URL's query or userinfo",
          .timeLimit(.minutes(1)))
    func configuredQueryIsNotInTheError() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable, postReply: .status(.internalServerError))
        let transport = StreamableHTTPTransport(
            url: try await server.url(path: "/mcp", query: "api_key=\(Watched.key)"),
            openServerStream: false,
            connectionTimeout: 5)
        try await transport.connect()

        var caught: (any Error)?
        do {
            try await transport.send(Watched.body)
        } catch {
            caught = error
        }
        let error = try #require(caught, "a 500 was reported as success")
        #expect(await server.requests.last?.target == "/mcp?api_key=\(Watched.key)")

        for text in Self.renderings(of: error) {
            #expect(!text.contains(Watched.key), "the error carries the key: \(text)")
        }
        #expect(error as? MCPError == .requestFailed(
            code: 500,
            message: "HTTP 500 from POST to http://127.0.0.1:\(try await server.port)/mcp",
            data: nil))
        try await transport.disconnect()
        await server.stop()
    }

    /// An `endpoint` event that will not parse used to be quoted back in the error. What a
    /// server sent that is not a URL is still what a server sent.
    @Test("An unparseable endpoint event is not quoted in the error",
          arguments: ["https://[::1/messages?sessionId=fixture-session-do-not-forward",
                      "ht!tps://x/?sessionId=fixture-session-do-not-forward"])
    func unparseableEndpointIsNotQuoted(_ raw: String) throws {
        let stream = try requireURL("https://good.example/sse")
        var caught: (any Error)?
        do {
            _ = try HTTPSSETransport.resolveEndpoint(raw, against: stream)
        } catch {
            caught = error
        }
        let error = try #require(caught, "\(raw) was accepted")
        for text in Self.renderings(of: error) {
            #expect(!text.contains(Watched.session), "the error quotes the endpoint: \(text)")
        }
    }

    /// `WebSocketKit` describes a refused upgrade by printing the response head — status,
    /// version and every header the server sent. The transport passed that description on.
    @Test("A refused WebSocket upgrade does not quote the server's response headers",
          .timeLimit(.minutes(1)))
    func webSocketRefusalDoesNotQuoteHeaders() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                status: .temporaryRedirect,
                location: "http://127.0.0.1:9/elsewhere?sessionId=\(Watched.session)")])
        var components = try #require(URLComponents(
            url: try await server.url(path: "/ws", query: "api_key=\(Watched.key)"),
            resolvingAgainstBaseURL: false))
        components.scheme = "ws"
        let transport = WebSocketTransport(url: try #require(components.url))

        var caught: (any Error)?
        do {
            try await transport.connect()
        } catch {
            caught = error
        }
        let error = try #require(caught, "a 307 was reported as a connection")
        for text in Self.renderings(of: error) {
            #expect(!text.contains(Watched.session), "the error quotes the Location header: \(text)")
            #expect(!text.contains(Watched.key), "the error carries the configured URL's query: \(text)")
        }
        #expect(error as? MCPError == .connectionFailed(
            reason: "Could not reach ws://127.0.0.1:\(try await server.port): "
                + "the server answered the WebSocket upgrade with HTTP 307"))
        try await transport.disconnect()
        await server.stop()
    }

    /// OAuth discovery reports where it looked. The candidate is built from the server URL
    /// the caller gave, which can carry userinfo; the error is a public value that a caller
    /// will print.
    @Test("An OAuth discovery failure names the location without userinfo or query")
    func discoveryErrorIsRedacted() throws {
        let looked = try requireURL(
            "https://user:hunter2@mcp.example/.well-known/oauth-protected-resource/mcp?access_token=\(Watched.key)")
        let response = try #require(HTTPURLResponse(
            url: looked, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))

        var caught: (any Error)?
        do {
            _ = try MCPOAuthSetup.validate(data: Data(), response: response, url: looked)
        } catch {
            caught = error
        }
        let error = try #require(caught, "a 404 was accepted")
        for text in Self.renderings(of: error) {
            #expect(!text.contains("hunter2"), "the error carries the password: \(text)")
            #expect(!text.contains(Watched.key), "the error carries the query: \(text)")
        }
        #expect(error as? MCPOAuthError == .metadataNotFound(
            url: try requireURL("https://mcp.example/.well-known/oauth-protected-resource/mcp"),
            status: 404))
    }
}
