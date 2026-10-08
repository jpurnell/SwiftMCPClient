import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// Asked for a header and answers from a script, recording how it was asked.
actor ScriptedProvider {
    private var answers: [String?]
    private(set) var asks: [Bool] = []

    /// - Parameter answers: What to return, in order. The last is repeated.
    init(_ answers: [String?]) {
        self.answers = answers
    }

    /// One ask.
    func header(forcingRefresh: Bool) -> String? {
        asks.append(forcingRefresh)
        guard answers.count > 1 else { return answers.first ?? nil }
        return answers.removeFirst()
    }

    /// The provider to hand a transport.
    nonisolated var provider: AuthorizationProvider {
        { forcing in await self.header(forcingRefresh: forcing) }
    }
}

/// The WebSocket upgrade request: what it carries, over what, and to where.
///
/// The transport makes exactly one HTTP request, and it is the one that carries the
/// credential. The stub here does not complete the upgrade — it records the request and
/// answers `200`, which fails `connect()` — because what is being asked is what arrived.
@Suite("WebSocket — the upgrade request (wire)")
struct WebSocketUpgradeWireTests {

    /// A `ws` or `wss` URL on a stub.
    static func socketURL(
        _ server: RedirectStubServer,
        scheme: String,
        path: String = "/ws",
        query: String? = nil
    ) async throws -> URL {
        var components = try #require(URLComponents(
            url: try await server.url(path: path, query: query), resolvingAgainstBaseURL: false))
        components.scheme = scheme
        return try #require(components.url)
    }

    /// Connects, expecting the stub's `200` to fail the upgrade, and returns what was thrown.
    static func attempt(_ transport: WebSocketTransport) async throws -> (any Error)? {
        var caught: (any Error)?
        do {
            try await transport.connect()
        } catch {
            caught = error
        }
        try await transport.disconnect()
        return caught
    }

    // MARK: - The credential

    @Test("Static headers go on the upgrade request", .timeLimit(.minutes(1)))
    func staticHeaders() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable)
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: [Watched.keyHeader: Watched.key, "Authorization": Watched.staticAuthorization])
        _ = try await Self.attempt(transport)

        let upgrade = try #require(await server.requests.first)
        #expect(upgrade.header("Upgrade")?.lowercased() == "websocket")
        #expect(upgrade.header(Watched.keyHeader) == Watched.key)
        #expect(upgrade.header("Authorization") == Watched.staticAuthorization)
        await server.stop()
    }

    /// The HTTP transports take an `authorization:` provider, so that a session which
    /// refreshes reaches the wire. This transport had no such parameter: an OAuth session
    /// could only be given to it as a string that then expired.
    @Test("The authorization provider's header goes on the upgrade, in place of a static one",
          .timeLimit(.minutes(1)))
    func providerSuppliesTheHeader() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable)
        let scripted = ScriptedProvider([Watched.providerAuthorization])
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: [Watched.keyHeader: Watched.key, "Authorization": Watched.staticAuthorization],
            authorization: scripted.provider)
        _ = try await Self.attempt(transport)

        let requests = await server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.header("Authorization") == Watched.providerAuthorization)
        #expect(requests.first?.header(Watched.keyHeader) == Watched.key)
        // Asked once, and not for a forced refresh: nothing has been refused yet.
        #expect(await scripted.asks == [false])
        await server.stop()
    }

    /// `nil` means not signed in. As on the HTTP transports, that is a request with no
    /// `Authorization` at all — the static one is the leftover, not the fallback.
    @Test("A provider that returns nil sends no Authorization header", .timeLimit(.minutes(1)))
    func providerReturningNil() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable)
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: ["Authorization": Watched.staticAuthorization],
            authorization: { _ in nil })
        _ = try await Self.attempt(transport)

        let upgrade = try #require(await server.requests.first)
        #expect(upgrade.header("Authorization") == nil)
        await server.stop()
    }

    /// A provider that fails fails the connect, as it fails a send on the HTTP transports:
    /// going on without the header reaches the server as a `401`, which reads as a credential
    /// problem at the far end rather than a local one.
    @Test("A provider that throws fails connect(), and nothing is sent", .timeLimit(.minutes(1)))
    func providerThatThrows() async throws {
        struct RefreshFailed: Error {}
        let server = try await RedirectStubServer.start(kind: .streamable)
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: ["Authorization": Watched.staticAuthorization],
            authorization: { _ in throw RefreshFailed() })

        let caught = try await Self.attempt(transport)
        #expect(caught is RefreshFailed, "connect() ended with \(String(describing: caught))")
        #expect(await server.requests.isEmpty)
        await server.stop()
    }

    /// The HTTP transports answer a `401` by asking the provider for a token obtained now,
    /// once. The upgrade is this transport's only request, so it is the only place that
    /// recovery can happen.
    @Test("A 401 on the upgrade is retried once with a forced refresh", .timeLimit(.minutes(1)))
    func unauthorizedIsRetriedOnce() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(status: .unauthorized, location: "/", times: 1)])
        let scripted = ScriptedProvider(["Bearer stale-do-not-leak", Watched.providerAuthorization])
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: [:],
            authorization: scripted.provider)
        _ = try await Self.attempt(transport)

        #expect(await server.requests.map { $0.header("Authorization") }
                == ["Bearer stale-do-not-leak", Watched.providerAuthorization])
        #expect(await scripted.asks == [false, true])
        await server.stop()
    }

    @Test("A 401 that persists is not retried again", .timeLimit(.minutes(1)))
    func unauthorizedTwiceIsFinal() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(status: .unauthorized, location: "/")])
        let scripted = ScriptedProvider([Watched.providerAuthorization])
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: [:],
            authorization: scripted.provider)

        let caught = try await Self.attempt(transport)
        #expect(caught as? MCPError == .connectionFailed(
            reason: "Could not reach ws://127.0.0.1:\(try await server.port): "
                + "the server answered the WebSocket upgrade with HTTP 401"))
        #expect(await server.requests.count == 2)
        #expect(await scripted.asks == [false, true])
        await server.stop()
    }

    /// Without a provider there is nothing to refresh, so a refusal stands.
    @Test("Without a provider a 401 is not retried", .timeLimit(.minutes(1)))
    func unauthorizedWithoutAProvider() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(status: .unauthorized, location: "/")])
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: "ws"),
            headers: ["Authorization": Watched.staticAuthorization])
        _ = try await Self.attempt(transport)
        #expect(await server.requests.count == 1)
        await server.stop()
    }

    // MARK: - The scheme

    /// `WebSocketKit` decides whether to use TLS by comparing the scheme with the exact
    /// string `wss`. A URL's scheme is case-insensitive (RFC 3986 §3.1), so `WSS://` is a
    /// request for TLS — and compared that way it is a request for plaintext on port 80, in a
    /// release build, and an assertion failure in a debug one. The transport passed the URL
    /// through unexamined.
    @Test("A wss URL is connected to over TLS however its scheme is capitalised",
          .timeLimit(.minutes(1)),
          arguments: ["wss", "WSS", "Wss"])
    func secureSchemeIsCaseInsensitive(_ scheme: String) async throws {
        let identity = try TestIdentity.selfSigned()
        let server = try await RedirectStubServer.start(
            kind: .streamable, tls: try identity.serverContext())
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: scheme),
            headers: ["Authorization": Watched.staticAuthorization],
            serverTrust: try .onlyRoots([.pem(identity.pem)]))
        _ = try await Self.attempt(transport)

        // The stub speaks only TLS, so a request it could read is one that arrived over TLS.
        let upgrade = try #require(await server.requests.first, "\(scheme): nothing arrived over TLS")
        #expect(upgrade.header("Authorization") == Watched.staticAuthorization)
        await server.stop()
    }

    @Test("A ws URL is connected to in plaintext however its scheme is capitalised",
          .timeLimit(.minutes(1)),
          arguments: ["ws", "WS"])
    func plainSchemeIsCaseInsensitive(_ scheme: String) async throws {
        let server = try await RedirectStubServer.start(kind: .streamable)
        let transport = WebSocketTransport(url: try await Self.socketURL(server, scheme: scheme))
        _ = try await Self.attempt(transport)
        #expect(await server.requests.count == 1)
        await server.stop()
    }

    /// Anything else is not a WebSocket URL. `https` in particular was sent as plaintext to
    /// port 80 in a release build: the caller asked for TLS in the only words they had, and
    /// got none.
    @Test("A URL that is not ws or wss is refused before anything is sent",
          .timeLimit(.minutes(1)),
          arguments: ["https", "http", "HTTPS", "ftp"])
    func otherSchemesAreRefused(_ scheme: String) async throws {
        let server = try await RedirectStubServer.start(kind: .streamable)
        let transport = WebSocketTransport(
            url: try await Self.socketURL(server, scheme: scheme, query: "api_key=\(Watched.key)"),
            headers: ["Authorization": Watched.staticAuthorization])

        let caught = try await Self.attempt(transport)
        guard case .connectionFailed(let reason) = caught as? MCPError else {
            Issue.record("\(scheme): connect() ended with \(String(describing: caught))")
            return
        }
        #expect(reason.contains("ws://") && reason.contains("wss://"), "the reason does not say what is accepted: \(reason)")
        #expect(reason.contains(scheme.lowercased()))
        #expect(!reason.contains(Watched.key))
        #expect(await server.requests.isEmpty, "a request was made on a \(scheme) URL")
        await server.stop()
    }
}

/// When a transport is about to send a credential unencrypted to another machine.
///
/// None of the three network transports refuses a plaintext URL: `http://` and `ws://` are
/// what a server on a private network or on loopback is reached by, and ``ServerTrust`` is
/// about which certificate an `https` or `wss` server may present, not about whether there is
/// one. What they owe the operator is one consistent warning when a credential is configured
/// and the peer is not this machine.
@Suite("HTTPOrigin — plaintext to a remote host")
struct PlaintextToRemoteTests {

    /// A URL, written as its scheme and the rest, and whether a credential sent to it
    /// crosses a network unencrypted.
    struct Example: Sendable, CustomTestStringConvertible {
        let scheme: String
        let rest: String
        let exposed: Bool
        var testDescription: String { "\(scheme) \(rest) → \(exposed ? "exposed" : "not exposed")" }
    }

    static let examples: [Example] = [
        Example(scheme: "http", rest: "mcp.example/mcp", exposed: true),
        Example(scheme: "ws", rest: "mcp.example/ws", exposed: true),
        Example(scheme: "WS", rest: "MCP.Example/ws", exposed: true),
        Example(scheme: "http", rest: "192.168.1.20:8080/mcp", exposed: true),
        Example(scheme: "http", rest: "localhost.evil.test/mcp", exposed: true),
        Example(scheme: "http", rest: "127.0.0.1.evil.test/mcp", exposed: true),
        Example(scheme: "https", rest: "mcp.example/mcp", exposed: false),
        Example(scheme: "wss", rest: "mcp.example/ws", exposed: false),
        Example(scheme: "http", rest: "localhost:3000/mcp", exposed: false),
        Example(scheme: "http", rest: "LOCALHOST/mcp", exposed: false),
        Example(scheme: "ws", rest: "127.0.0.1:9000/ws", exposed: false),
        Example(scheme: "http", rest: "127.8.9.10/mcp", exposed: false),
        Example(scheme: "http", rest: "[::1]:3000/mcp", exposed: false),
    ]

    @Test("Plaintext to anything but loopback is exposed", arguments: examples)
    func classifies(_ example: Example) throws {
        let url = try requireURL("\(example.scheme)://\(example.rest)")
        #expect(HTTPOrigin.isPlaintextToRemote(url) == example.exposed)
    }
}
