import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// Keeping a legacy HTTP+SSE session authorised.
///
/// The same defect the Streamable HTTP transport had: a header read once at construction and
/// frozen, under a session that refreshes. It matters differently here. This transport holds
/// one long-lived stream, and a header cannot be changed on a request that is already open —
/// so a token that expires mid-stream is only recoverable at the next reconnect. That limit is
/// inherent; sending a stale token on every *POST* was not.
@Suite("HTTP+SSE — authorization")
struct HTTPSSEAuthorizationTests {

    /// Every POST asks again, so a refreshed token reaches the wire.
    ///
    /// The first scripted token goes to the stream, which `connect()` opens before any POST is
    /// made — so the POSTs see the second and third. That ordering is behaviour, not an
    /// accident: a stream opened with a stale token is the failure this whole provider exists
    /// to prevent.
    @Test("Every POST asks the provider again", .timeLimit(.minutes(1)))
    func postsAskEachTime() async throws {
        let tokens = TokenSequence(["Bearer stream", "Bearer first", "Bearer second"])
        let seen = try await withSSEStub(
            authorization: { _ in await tokens.next() }
        ) { transport, server in
            try await transport.send(Data("{}".utf8))
            try await transport.send(Data("{}".utf8))
            return await server.received.map(\.authorization)
        }

        #expect(seen == ["Bearer first", "Bearer second"],
                "the second POST reused the first POST's token")
    }

    /// A refused POST is retried once with a forcibly refreshed token — the same recovery the
    /// Streamable transport has, for the same reason: a revoked grant is invisible to a clock.
    @Test("A refused POST is retried with a forced refresh", .timeLimit(.minutes(1)))
    func refusedPostIsRetried() async throws {
        let forcings = ForcedCalls()
        // As above: the stream takes the first token when `connect()` opens it.
        let tokens = TokenSequence(["Bearer stream", "Bearer rejected", "Bearer forced"])
        let seen = try await withSSEStub(
            replies: [.unauthorized(), .ok("{}")],
            authorization: { forcing in
                await forcings.record(forcing)
                return await tokens.next()
            }
        ) { transport, server in
            try await transport.send(Data("{}".utf8))
            return await server.received.map(\.authorization)
        }

        #expect(seen == ["Bearer rejected", "Bearer forced"])
        // The stream's open is the leading `false`; the POST and its retry are the pair.
        #expect(await forcings.flags.suffix(2) == [false, true])
    }

    /// The stream itself carries a current token when it is opened. It cannot change one
    /// mid-stream — nothing can — but a reconnect must not present the token that had already
    /// been refused.
    @Test("Opening the stream asks the provider", .timeLimit(.minutes(1)))
    func streamOpenAsksProvider() async throws {
        let server = try await SSEStubServer.start(replies: [.ok("{}")])
        let transport = HTTPSSETransport(
            url: try await server.url,
            authorization: { _ in "Bearer streamed" })

        do {
            try await transport.connect()
            let opens = await server.streamOpens
            #expect(opens.first?.authorization == "Bearer streamed",
                    "the stream was opened without asking for a token")
            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Without a provider nothing changes: the static header is sent exactly as before.
    @Test("A static header still works", .timeLimit(.minutes(1)))
    func staticHeaderUnchanged() async throws {
        let seen = try await withSSEStub(
            headers: ["Authorization": "Bearer static"]
        ) { transport, server in
            try await transport.send(Data("{}".utf8))
            return await server.received.map(\.authorization)
        }

        #expect(seen == ["Bearer static"])
    }
}

// MARK: - Helpers

/// Runs a body against a stubbed SSE server and a connected transport, tearing both down.
private func withSSEStub<T>(
    replies: [StubHTTPServer.Reply] = [.ok("{}")],
    headers: [String: String] = [:],
    authorization: AuthorizationProvider? = nil,
    _ body: (HTTPSSETransport, SSEStubServer) async throws -> T
) async throws -> T {
    let server = try await SSEStubServer.start(replies: replies)
    let transport = HTTPSSETransport(
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
        try? await transport.disconnect()
        await server.stop()
        throw error
    }
}

/// Hands out scripted tokens, repeating the last.
private actor TokenSequence {
    private var tokens: [String]
    init(_ tokens: [String]) { self.tokens = tokens }
    func next() -> String? {
        guard let first = tokens.first else { return nil }
        if tokens.count > 1 { tokens.removeFirst() }
        return first
    }
}

/// Records whether each provider call asked for a forced refresh.
private actor ForcedCalls {
    private(set) var flags: [Bool] = []
    func record(_ forcing: Bool) { flags.append(forcing) }
}
