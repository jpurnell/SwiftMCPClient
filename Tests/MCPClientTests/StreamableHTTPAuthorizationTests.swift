import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// Keeping a long session authorised.
///
/// The transport used to read an `Authorization` header once, at construction, and rebuild
/// every request from that frozen copy. The session underneath it refreshed on schedule and
/// the transport never looked again — which is why `updateAuthorization(_:)` was written, and
/// why it then sat with no caller.
///
/// These tests assert against a real server on loopback rather than against the transport's
/// own `currentHeaders`, because the failure being fixed was precisely a gap between what the
/// transport believed it would send and what it sent.
@Suite("Streamable HTTP — authorization")
struct StreamableHTTPAuthorizationTests {

    /// The provider is asked per request, not per transport. A provider consulted once is the
    /// original bug wearing a closure.
    @Test("Every request asks the provider again")
    func providerConsultedPerRequest() async throws {
        let tokens = TokenScript(["first", "second"])
        let seen = try await withStub(
            replies: [.ok(#"{"jsonrpc":"2.0","id":1}"#)],
            authorization: { _ in await tokens.next() }
        ) { transport, server in
            try await transport.send(Data(#"{"id":1}"#.utf8))
            _ = try await transport.receive()
            try await transport.send(Data(#"{"id":2}"#.utf8))
            _ = try await transport.receive()
            return await server.received.map(\.authorization)
        }

        #expect(seen == ["first", "second"], "the second request reused the first request's token")
    }

    /// A provider that returns a new token has to reach the wire, or refreshing changes
    /// nothing a server can observe.
    @Test("A refreshed token reaches the next request")
    func refreshedTokenReachesTheWire() async throws {
        let tokens = TokenScript(["stale", "fresh"])
        let last = try await withStub(
            replies: [.ok(#"{"jsonrpc":"2.0","id":1}"#)],
            authorization: { _ in await tokens.next() }
        ) { transport, server in
            try await transport.send(Data(#"{"id":1}"#.utf8))
            _ = try await transport.receive()
            try await transport.send(Data(#"{"id":2}"#.utf8))
            _ = try await transport.receive()
            return await server.received.last
        }

        #expect(try #require(last).authorization == "fresh")
    }

    /// A provider beats a header passed at construction. Both present means a caller has an
    /// OAuth session and a leftover pasted token, and sending the stale one silently would be
    /// the worse of the two guesses.
    @Test("The provider wins over a static header")
    func providerBeatsStaticHeader() async throws {
        let sent = try await withStub(
            replies: [.ok("{}")],
            headers: ["Authorization": "Bearer pasted"],
            authorization: { _ in "Bearer live" }
        ) { transport, server in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            return await server.received.first?.authorization
        }

        #expect(sent == "Bearer live")
    }

    /// A provider that throws must fail the send. Falling through unauthenticated arrives at
    /// the server as a `401`, which sends whoever is reading the logs to the wrong layer.
    @Test("A failing provider fails the send rather than sending unauthenticated")
    func failingProviderFailsTheSend() async throws {
        let received = try await withStub(
            replies: [.ok("{}")],
            authorization: { _ in throw TokenTrouble.unavailable }
        ) { transport, server in
            await #expect(throws: (any Error).self) {
                try await transport.send(Data("{}".utf8))
            }
            return await server.received
        }

        #expect(received.isEmpty, "an unauthenticated request was sent anyway")
    }

    /// With no provider, nothing changes: the static header is sent on every request exactly
    /// as it is today.
    @Test("Without a provider the static header is unchanged")
    func staticHeaderStillWorks() async throws {
        let seen = try await withStub(
            replies: [.ok("{}")],
            headers: ["Authorization": "Bearer static"]
        ) { transport, server in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            return await server.received.map(\.authorization)
        }

        #expect(seen == ["Bearer static", "Bearer static"])
    }

    /// A provider returning `nil` means "not signed in". That has to arrive as no header at
    /// all, not as `Bearer nil` or a bare `Bearer`.
    @Test("A nil token sends no authorization header")
    func nilTokenSendsNoHeader() async throws {
        let sent = try await withStub(
            replies: [.ok("{}")],
            authorization: { _ in nil }
        ) { transport, server in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            return await server.received.first
        }

        #expect(try #require(sent).authorization == nil)
    }
}

/// What happens when the server refuses a token the local clock still likes.
@Suite("Streamable HTTP — refusal")
struct StreamableHTTPRefusalTests {

    /// The reactive half. A `401` is retried once, and the retry asks for a forced refresh —
    /// the local clock cannot see a revoked grant or an expired registration, so waiting for
    /// predicted expiry would wait forever.
    @Test("A 401 is retried once with a forcibly refreshed token")
    func retriesOnceAfterRefusal() async throws {
        let tokens = TokenScript(["Bearer rejected", "Bearer forced"])
        let forcings = ForcingLog()
        let seen = try await withStub(
            replies: [.unauthorized(), .ok(#"{"jsonrpc":"2.0","id":1}"#)],
            authorization: { forcing in
                await forcings.record(forcing)
                return await tokens.next()
            }
        ) { transport, server in
            try await transport.send(Data(#"{"id":1}"#.utf8))
            _ = try await transport.receive()
            return await server.received.map(\.authorization)
        }
        #expect(seen == ["Bearer rejected", "Bearer forced"], "the refused request was not retried")
        #expect(await forcings.flags == [false, true],
                "the retry did not ask for a forced refresh, so it re-sent what the clock still liked")
    }

    /// Once, not in a loop. A server refusing a token that was just refreshed is refusing the
    /// grant, and each further attempt spends a rotation to be told the same thing.
    @Test("A second refusal is not retried again")
    func doesNotRetryTwice() async throws {
        let forcings = ForcingLog()
        let count = try await withStub(
            replies: [.unauthorized()],
            authorization: { forcing in
                await forcings.record(forcing)
                return "Bearer whatever"
            }
        ) { transport, server in
            await #expect(throws: (any Error).self) {
                try await transport.send(Data("{}".utf8))
            }
            return await server.received.count
        }

        #expect(count == 2, "the request was attempted more than twice")
        #expect(await forcings.flags == [false, true])
    }

    /// The session the server tracks must survive the token change. Rebuilding the transport
    /// to carry a new token is what this whole mechanism exists to avoid, and losing
    /// `Mcp-Session-Id` in the retry would be the same loss by another route.
    @Test("The session id survives a refusal and retry")
    func sessionSurvivesRetry() async throws {
        let retried = try await withStub(
            replies: [
                .ok(#"{"jsonrpc":"2.0","id":0}"#),
                .unauthorized(),
                .ok(#"{"jsonrpc":"2.0","id":1}"#)
            ],
            authorization: { _ in "Bearer any" }
        ) { transport, server in
            // The first exchange is what hands the client its session id.
            try await transport.send(Data(#"{"id":0}"#.utf8))
            _ = try await transport.receive()

            try await transport.send(Data(#"{"id":1}"#.utf8))
            _ = try await transport.receive()
            return await server.received.last
        }

        #expect(try #require(retried).sessionId == "stub-session",
                "the retry dropped the server's session")
    }

    /// Only a refusal is retried. A `500` is the server's problem, and forcing a refresh to
    /// answer it spends a rotation on a token that was never in question.
    @Test("A server error is not retried")
    func serverErrorIsNotRetried() async throws {
        let forcings = ForcingLog()
        let count = try await withStub(
            replies: [.init(status: .internalServerError, body: "{}")],
            authorization: { forcing in
                await forcings.record(forcing)
                return "Bearer any"
            }
        ) { transport, server in
            await #expect(throws: (any Error).self) {
                try await transport.send(Data("{}".utf8))
            }
            return await server.received.count
        }

        #expect(count == 1)
        #expect(await forcings.flags == [false])
    }

    /// With no provider there is nothing to refresh, so a `401` fails exactly as it does
    /// today rather than becoming a bare repeat of the same request.
    @Test("Without a provider a refusal is not retried")
    func noProviderMeansNoRetry() async throws {
        let count = try await withStub(
            replies: [.unauthorized()],
            headers: ["Authorization": "Bearer static"]
        ) { transport, server in
            await #expect(throws: (any Error).self) {
                try await transport.send(Data("{}".utf8))
            }
            return await server.received.count
        }

        #expect(count == 1)
    }
}

// MARK: - Helpers

/// Runs a body against a stubbed server and a connected transport, and takes both down after.
///
/// The teardown is the point. `HTTPClient` traps in `deinit` if it was never shut down, so a
/// test that returns without disconnecting kills the whole suite rather than failing — the
/// same crash shape this package already fixed once, on the handshake-rejection path.
///
/// - Parameters:
///   - replies: What the server should answer, in order. The last repeats.
///   - headers: Static headers for the transport.
///   - authorization: The provider under test, if any.
///   - body: The test, given the connected transport and the server.
/// - Returns: Whatever `body` returned.
private func withStub<T>(
    replies: [StubHTTPServer.Reply],
    headers: [String: String] = [:],
    authorization: AuthorizationProvider? = nil,
    _ body: (StreamableHTTPTransport, StubHTTPServer) async throws -> T
) async throws -> T {
    let server = try await StubHTTPServer.start(replies: replies)
    let transport = StreamableHTTPTransport(
        url: try await server.url,
        headers: headers,
        authorization: authorization)
    try await transport.connect()

    do {
        let result = try await body(transport, server)
        try await transport.disconnect()
        await server.stop()
        return result
    } catch {
        // Torn down on the failure path too, or one failing test takes the suite with it.
        try? await transport.disconnect()
        await server.stop()
        throw error
    }
}

/// Hands out scripted tokens, repeating the last once the script runs out.
private actor TokenScript {
    private var tokens: [String]
    init(_ tokens: [String]) { self.tokens = tokens }

    func next() -> String? {
        guard let first = tokens.first else { return nil }
        if tokens.count > 1 { tokens.removeFirst() }
        return first
    }
}

/// Records whether each call asked for a forced refresh.
private actor ForcingLog {
    private(set) var flags: [Bool] = []
    func record(_ forcing: Bool) { flags.append(forcing) }
}

/// A provider failure that is not an `MCPError`, so the test cannot pass by coincidence.
private enum TokenTrouble: Error {
    case unavailable
}

/// What a request carries once a session exists.
///
/// The headers themselves are decided by `StreamableHTTPSession` and unit-tested there. What
/// these check is that the transport actually asks it — the same class of gap that left
/// `updateAuthorization(_:)` correct and uncalled.
@Suite("Streamable HTTP — session headers")
struct StreamableHTTPSessionHeaderTests {

    /// The server assigns a session id on the first response; every later request carries it.
    @Test("An assigned session id is carried on the next request")
    func carriesSessionID() async throws {
        let seen = try await withStub(replies: [.ok("{}")]) { transport, server in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            return await server.received.map(\.sessionId)
        }

        #expect(seen == [nil, "stub-session"], "the assigned session id was not carried back")
    }

    /// `MCP-Protocol-Version` must not appear on the request that negotiates it. Sending a
    /// version before the server has agreed to one asserts a negotiation that has not happened.
    @Test("The protocol version is absent until one is negotiated")
    func protocolVersionAbsentBeforeNegotiation() async throws {
        let version = try await withStub(replies: [.ok("{}")]) { transport, server in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            return await server.received.first?.protocolVersion
        }

        #expect(version == nil)
    }

    /// Once the server has accepted a version, every later request echoes it — spec 2025-06-18
    /// requires the header, and a server enforcing it rejects requests without one.
    @Test("The negotiated version is echoed on later requests")
    func echoesNegotiatedVersion() async throws {
        let version = try await withStub(replies: [.ok("{}")]) { transport, server in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()

            await transport.didNegotiate(protocolVersion: "2025-06-18")

            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()
            return await server.received.last?.protocolVersion
        }

        #expect(version == "2025-06-18")
    }

    /// A `404` answering a request that carried a session id means the server has forgotten
    /// the session. Keeping it would send every later request into the same wall; the caller
    /// has to re-initialize, and it cannot do that while the transport still believes.
    @Test("A 404 against a live session forgets it")
    func notFoundClearsTheSession() async throws {
        let stillHeld = try await withStub(
            replies: [.ok("{}"), .init(status: .notFound, body: "{}")]
        ) { transport, _ in
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()

            await #expect(throws: (any Error).self) {
                try await transport.send(Data("{}".utf8))
            }
            return await transport.sessionId
        }

        #expect(stillHeld == nil, "the transport still holds a session the server has forgotten")
    }
}
