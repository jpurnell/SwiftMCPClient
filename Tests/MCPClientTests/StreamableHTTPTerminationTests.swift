import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// A provider that answers its first asks at once and then stops answering.
///
/// A token refresh that never returns is the case `disconnect()` has to survive: the
/// authorization server is down, or the network is, which is often *why* the caller is
/// disconnecting.
actor StallingProvider {
    private let answersFirst: Int
    private(set) var asks: [Bool] = []
    private var stalled: [CheckedContinuation<Void, Never>] = []

    /// - Parameter answersFirst: How many asks are answered before one stalls.
    init(answersFirst: Int) {
        self.answersFirst = answersFirst
    }

    /// One ask. Deliberately deaf to cancellation: a provider is the caller's code, and a
    /// bound that only works on a provider which co-operates is not a bound.
    func header(forcingRefresh: Bool) async -> String? {
        asks.append(forcingRefresh)
        guard asks.count > answersFirst else { return Watched.providerAuthorization }
        await withCheckedContinuation { stalled.append($0) }
        return Watched.providerAuthorization
    }

    /// How many asks are stalled now.
    var stalledCount: Int { stalled.count }

    /// Whether the stall was ended by a test's watchdog rather than by the test itself.
    private(set) var releasedByWatchdog = false

    /// Lets every stalled ask finish, so the test leaves nothing suspended behind it.
    func release(byWatchdog: Bool = false) {
        if byWatchdog, !stalled.isEmpty { releasedByWatchdog = true }
        for continuation in stalled { continuation.resume() }
        stalled.removeAll()
    }

    /// The provider to hand a transport.
    nonisolated var provider: AuthorizationProvider {
        { forcing in await self.header(forcingRefresh: forcing) }
    }
}

/// The `DELETE` that ends a Streamable HTTP session.
///
/// Every other request the transport makes asks the `authorization:` provider for a current
/// header. This one did not: it went out with the static headers and nothing else, so the
/// termination of an OAuth session was unauthenticated. A server that checks — and one that
/// issued the session to an authenticated client should — refuses it, and the session stays
/// open until it expires.
@Suite("Streamable HTTP — ending the session (wire)")
struct StreamableHTTPTerminationTests {

    /// Opens a session on a stub and returns the transport, ready to be disconnected.
    static func session(
        on server: RedirectStubServer,
        headers: [String: String] = [:],
        provider: AuthorizationProvider?,
        timeout: TimeInterval = 5
    ) async throws -> StreamableHTTPTransport {
        let transport = StreamableHTTPTransport(
            url: try await server.url,
            headers: headers,
            authorization: provider,
            openServerStream: false,
            connectionTimeout: timeout)
        try await transport.connect()
        try await transport.send(Watched.initialize)
        return transport
    }

    @Test("The DELETE carries the provider's current credential, asked for once and not forced",
          .timeLimit(.minutes(1)))
    func deleteIsAuthenticated() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable, session: Watched.session)
        let scripted = ScriptedProvider([Watched.providerAuthorization])
        let transport = try await Self.session(
            on: server, headers: ["Authorization": Watched.staticAuthorization], provider: scripted.provider)
        let before = await scripted.asks.count

        try await transport.disconnect()

        let delete = try #require(await server.requests.last { $0.method == "DELETE" }, "no DELETE was sent")
        #expect(delete.header("Authorization") == Watched.providerAuthorization)
        #expect(delete.header("Mcp-Session-Id") == Watched.session)
        // Exactly one ask for the DELETE, and an ordinary one: ending a session is no reason
        // to spend a refresh-token rotation.
        #expect(Array(await scripted.asks.dropFirst(before)) == [false])
        await server.stop()
    }

    /// A redirected `DELETE` re-uses the credential it was given rather than asking again:
    /// one ask is the bound, and a second would be a second chance to stall.
    @Test("A redirected DELETE does not ask the provider a second time", .timeLimit(.minutes(1)))
    func redirectedDeleteAsksOnce() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(method: .DELETE, path: "/mcp", status: .temporaryRedirect, location: "/moved")],
            session: Watched.session)
        let scripted = ScriptedProvider([Watched.providerAuthorization])
        let transport = try await Self.session(on: server, provider: scripted.provider)
        let before = await scripted.asks.count

        try await transport.disconnect()

        let deletes = await server.requests.filter { $0.method == "DELETE" }
        #expect(deletes.map(\.path) == ["/mcp", "/moved"])
        #expect(deletes.allSatisfy { $0.header("Authorization") == Watched.providerAuthorization })
        #expect(Array(await scripted.asks.dropFirst(before)) == [false])
        await server.stop()
    }

    /// The reason the `DELETE` was left unauthenticated: asking could block. It is bounded
    /// instead — by the same deadline the `DELETE` itself has — and when no credential arrives
    /// in time nothing is sent, because an unauthenticated termination is the request the
    /// server refuses and the one this is here to stop sending.
    @Test("A provider that never answers does not hang disconnect(), and no DELETE is sent without a credential",
          .timeLimit(.minutes(1)))
    func stalledProviderDoesNotHangDisconnect() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable, session: Watched.session)
        // Answers the one ask the opening POST makes, then stalls.
        let stalling = StallingProvider(answersFirst: 1)
        let transport = try await Self.session(
            on: server, headers: ["Authorization": Watched.staticAuthorization],
            provider: stalling.provider, timeout: 0.5)

        // If `disconnect()` waited for the provider it would never return, so a watchdog
        // releases the provider after far longer than the bound — and the assertion is on
        // *who* let the provider go, not on how long anything took.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            await stalling.release(byWatchdog: true)
        }
        try await transport.disconnect()
        watchdog.cancel()

        #expect(await stalling.releasedByWatchdog == false,
                "disconnect() returned only because the provider was released")
        #expect(await stalling.stalledCount == 1, "the provider was no longer stalled when disconnect() returned")
        #expect(await stalling.asks == [false, false])
        #expect(await server.requests.filter { $0.method == "DELETE" }.isEmpty,
                "a DELETE was sent without the credential it was waiting for")
        await stalling.release()
        await server.stop()
    }

    @Test("A provider that throws sends no DELETE, and disconnect() still completes",
          .timeLimit(.minutes(1)))
    func throwingProviderSendsNothing() async throws {
        struct RefreshFailed: Error {}
        let server = try await RedirectStubServer.start(kind: .streamable, session: Watched.session)
        let asked = AskCount()
        let transport = try await Self.session(
            on: server,
            headers: ["Authorization": Watched.staticAuthorization],
            provider: { _ in
                // The opening POST gets a header; the DELETE's ask fails.
                guard await asked.next() == 1 else { throw RefreshFailed() }
                return Watched.providerAuthorization
            })

        try await transport.disconnect()
        #expect(await server.requests.filter { $0.method == "DELETE" }.isEmpty)
        await server.stop()
    }

    /// `nil` is the provider saying there is no session to authenticate with. The `DELETE`
    /// goes as every other request did under that answer: without an `Authorization` header,
    /// the static one included.
    @Test("A provider that returns nil sends the DELETE with no Authorization header",
          .timeLimit(.minutes(1)))
    func providerReturningNil() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable, session: Watched.session)
        let transport = try await Self.session(
            on: server, headers: ["Authorization": Watched.staticAuthorization], provider: { _ in nil })

        try await transport.disconnect()
        let delete = try #require(await server.requests.last { $0.method == "DELETE" }, "no DELETE was sent")
        #expect(delete.header("Authorization") == nil)
        await server.stop()
    }

    @Test("Without a provider the DELETE carries the static headers, as before",
          .timeLimit(.minutes(1)))
    func staticHeadersStillSent() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable, session: Watched.session)
        let transport = try await Self.session(
            on: server,
            headers: ["Authorization": Watched.staticAuthorization, Watched.keyHeader: Watched.key],
            provider: nil)

        try await transport.disconnect()
        let delete = try #require(await server.requests.last { $0.method == "DELETE" }, "no DELETE was sent")
        #expect(delete.header("Authorization") == Watched.staticAuthorization)
        #expect(delete.header(Watched.keyHeader) == Watched.key)
        await server.stop()
    }
}
