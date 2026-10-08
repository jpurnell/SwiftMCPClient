import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// Values whose travels the redirect tests watch.
///
/// None is a credential for anything. Each exists to be recognised if it turns up at a server
/// it was never meant for.
enum Watched {
    /// A custom header of the kind an API key travels in.
    static let keyHeader = "X-Api-Key"
    static let key = "fixture-do-not-forward"
    static let staticAuthorization = "Bearer static-do-not-leak"
    static let providerAuthorization = "Bearer provider-do-not-leak"
    /// What the stub assigns as `Mcp-Session-Id`, and puts in a legacy endpoint's query.
    static let session = "fixture-session-do-not-forward"
    static let eventID = "fixture-event-41"
    /// A string inside ``body``, to recognise the body by.
    static let bodyMarker = "do-not-forward-body"

    /// A JSON-RPC request with an id, so its response stream is resumable.
    static var body: Data {
        Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"do-not-forward-body"}}"#.utf8)
    }

    /// The request that opens a Streamable HTTP session.
    static var initialize: Data {
        Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#.utf8)
    }
}

/// Every request either HTTP transport makes, and how to get it redirected.
enum RedirectedRequest: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// Legacy HTTP+SSE: the `GET` that `connect()` opens. A reconnect is this same request.
    case sseStreamGET
    /// Legacy HTTP+SSE: a `POST` to the endpoint the stream named.
    case ssePOST
    /// Streamable HTTP: the first `POST`, before the server has assigned a session.
    case streamablePOSTInitialize
    /// Streamable HTTP: a later `POST`, carrying `Mcp-Session-Id`.
    case streamablePOSTInSession
    /// Streamable HTTP: the `GET` for the server-initiated stream.
    case streamableServerStreamGET
    /// Streamable HTTP: the `GET` that resumes a dropped response, carrying `Last-Event-ID`.
    case streamableResumptionGET
    /// Streamable HTTP: the `DELETE` that ends the session on `disconnect()`.
    case streamableDELETE

    var testDescription: String { rawValue }

    var kind: RedirectStubServer.Kind {
        switch self {
        case .sseStreamGET, .ssePOST: return .legacySSE
        default: return .streamable
        }
    }

    /// The method of the request that is redirected.
    var method: HTTPMethod {
        switch self {
        case .sseStreamGET, .streamableServerStreamGET, .streamableResumptionGET: return .GET
        case .ssePOST, .streamablePOSTInitialize, .streamablePOSTInSession: return .POST
        case .streamableDELETE: return .DELETE
        }
    }

    /// The path it is sent to.
    var path: String {
        switch self {
        case .sseStreamGET: return "/sse"
        case .ssePOST: return "/messages"
        default: return "/mcp"
        }
    }

    /// How many requests of that method go by before the one under test.
    var skipping: Int { self == .streamablePOSTInSession ? 1 : 0 }

    /// Whether the transport's caller is told when the request fails. The two background
    /// streams and the best-effort `DELETE` have nobody awaiting them.
    var surfacesFailure: Bool {
        switch self {
        case .sseStreamGET, .ssePOST, .streamablePOSTInitialize, .streamablePOSTInSession: return true
        case .streamableServerStreamGET, .streamableResumptionGET, .streamableDELETE: return false
        }
    }

    /// The method a same-origin redirect must repeat the request with.
    ///
    /// What `AsyncHTTPClient` did while it was following: `303` turns anything into a `GET`,
    /// `301` and `302` turn a `POST` into one, and everything else is repeated as it was.
    func methodAfter(_ code: Int) -> String {
        switch method {
        case .POST: return [307, 308].contains(code) ? "POST" : "GET"
        case .DELETE: return code == 303 ? "GET" : "DELETE"
        default: return "GET"
        }
    }
}

/// One redirected request, driven through a real transport between two loopback servers.
struct RedirectRun: Sendable {

    /// The statuses a transport treats as a redirect.
    static let statuses = [301, 302, 303, 307, 308]

    /// What each server heard, and how the transport's caller fared.
    struct Observation: Sendable {
        /// Everything the *second* server received. Empty is the only acceptable value when
        /// the redirect pointed at it.
        let other: [RedirectStubServer.Request]
        /// Everything the configured server received.
        let configured: [RedirectStubServer.Request]
        /// What the operation that met the redirect threw, if it threw.
        let failure: (any Error)?
        /// The second server's origin, as an error is expected to name it.
        let otherOrigin: String
        /// The configured server's origin.
        let configuredOrigin: String

        /// What reached the second server, in words — the cell of the table.
        var crossed: String { RedirectRun.describe(other) }

        /// The configured server's requests to one path.
        func configured(at path: String) -> [RedirectStubServer.Request] {
            configured.filter { $0.path == path }
        }
    }

    /// Names what a list of requests carried, of the things being watched.
    static func describe(_ requests: [RedirectStubServer.Request]) -> String {
        guard !requests.isEmpty else { return "nothing" }
        return requests.map { request in
            var carried: [String] = []
            if request.header(Watched.keyHeader) == Watched.key { carried.append(Watched.keyHeader) }
            if let authorization = request.header("Authorization") {
                let source = authorization == Watched.providerAuthorization ? "provider" : "static"
                carried.append("Authorization (\(source))")
            }
            for name in ["Mcp-Session-Id", "MCP-Protocol-Version", "Last-Event-ID"]
            where request.header(name) != nil {
                carried.append(name)
            }
            if request.body.contains(Watched.bodyMarker) { carried.append("body") }
            return "\(request.method) \(request.path) [\(carried.joined(separator: ", "))]"
        }.joined(separator: "; ")
    }

    /// The origin a refused redirect named, if that is what an error is.
    ///
    /// "It threw" is not enough: a stub that never started, or a request that timed out,
    /// throws too.
    static func refusedDestination(_ error: (any Error)?) -> String? {
        guard case .redirectRejected(let destination, _) = error as? MCPError else { return nil }
        return destination
    }

    /// Whether an error is the transport reporting that the request could not be completed.
    static func isConnectionFailure(_ error: (any Error)?) -> Bool {
        guard case .connectionFailed = error as? MCPError else { return false }
        return true
    }

    /// Polls until a condition holds.
    ///
    /// - Returns: Whether it held before the time ran out.
    static func wait(
        atMost limit: Duration,
        until condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await condition()
    }

    /// Drives one request into a redirect and reports what each server heard.
    ///
    /// - Parameters:
    ///   - request: Which of the transports' requests to redirect.
    ///   - code: The redirect status.
    ///   - location: Builds the `Location` from the second server's port. `{self}` stands for
    ///     the configured server's own origin.
    ///   - provider: An `authorization:` provider for the transport, if it is to have one.
    ///   - tls: Whether the configured server is HTTPS. The second server never is, which is
    ///     what makes a redirect to it a downgrade.
    ///   - more: Further redirect rules for the configured server, after the first.
    ///   - otherRedirects: Redirect rules for the second server, given the placeholder that
    ///     stands for the configured server's origin.
    ///   - followUp: A path on the configured server the redirect is expected to reach. When
    ///     set, a background request is given time to arrive there.
    static func run(
        _ request: RedirectedRequest,
        status code: Int,
        location: @Sendable (_ otherPort: Int) -> String = { "http://127.0.0.1:\($0)/elsewhere" },
        provider: AuthorizationProvider? = nil,
        tls: Bool = false,
        more: [RedirectStubServer.Redirect] = [],
        otherRedirects: @Sendable (_ configured: String) -> [RedirectStubServer.Redirect] = { _ in [] },
        followUp: String? = nil
    ) async throws -> Observation {
        let identity = tls ? try TestIdentity.selfSigned() : nil
        let trust: ServerTrust = try identity.map { try .onlyRoots([.pem($0.pem)]) } ?? .system

        // Each server may need to name the other in a `Location`, and neither port exists
        // until its server is up. The second is started first and told the first's origin
        // afterwards, which is what `{configured}` in its rules stands for.
        let other = try await RedirectStubServer.start(
            kind: request.kind,
            redirects: otherRedirects("{configured}"),
            session: Watched.session)
        let otherPort = try await other.port

        let rule = RedirectStubServer.Redirect(
            method: request.method,
            path: request.path,
            status: HTTPResponseStatus(statusCode: code),
            location: location(otherPort),
            skipping: request.skipping)
        let server = try await RedirectStubServer.start(
            kind: request.kind,
            redirects: [rule] + more,
            postReply: request == .streamableResumptionGET ? .droppedStream(eventID: Watched.eventID) : .json,
            endpoint: "/messages?sessionId=\(Watched.session)",
            session: Watched.session,
            tls: try identity?.serverContext())
        let configuredOrigin = "\(tls ? "https" : "http")://127.0.0.1:\(try await server.port)"
        await other.pointBack(to: configuredOrigin)

        let headers = [Watched.keyHeader: Watched.key, "Authorization": Watched.staticAuthorization]
        var failure: (any Error)?

        switch request.kind {
        case .legacySSE:
            let transport = HTTPSSETransport(
                url: try await server.url,
                headers: headers,
                authorization: provider,
                connectionTimeout: 5,
                maxReconnectAttempts: 0,
                serverTrust: trust)
            do {
                try await transport.connect()
                if request == .ssePOST { try await transport.send(Watched.body) }
            } catch {
                failure = error
            }
            let observation = Observation(
                other: await other.requests, configured: await server.requests,
                failure: failure, otherOrigin: "http://127.0.0.1:\(otherPort)",
                configuredOrigin: configuredOrigin)
            try await transport.disconnect()
            await server.stop()
            await other.stop()
            return observation

        case .streamable:
            let transport = StreamableHTTPTransport(
                url: try await server.url,
                headers: headers,
                authorization: provider,
                openServerStream: request == .streamableServerStreamGET,
                connectionTimeout: 5,
                serverTrust: trust)
            do {
                try await transport.connect()
                switch request {
                case .streamablePOSTInitialize:
                    try await transport.send(Watched.body)
                case .streamablePOSTInSession:
                    try await transport.send(Watched.initialize)
                    try await transport.send(Watched.body)
                case .streamableServerStreamGET:
                    try await transport.send(Watched.initialize)
                    await transport.didNegotiate(protocolVersion: "2025-06-18")
                    try await settle(server: server, other: other, followUp: followUp)
                case .streamableResumptionGET:
                    try await transport.send(Watched.body)
                    try await settle(server: server, other: other, followUp: followUp)
                default:
                    try await transport.send(Watched.initialize)
                    try await transport.disconnect()
                }
            } catch {
                failure = error
            }
            let observation = Observation(
                other: await other.requests, configured: await server.requests,
                failure: failure, otherOrigin: "http://127.0.0.1:\(otherPort)",
                configuredOrigin: configuredOrigin)
            try await transport.disconnect()
            await server.stop()
            await other.stop()
            return observation
        }
    }

    /// Gives a background `GET` time to be sent, redirected, and — if it is going to be —
    /// followed.
    ///
    /// Nothing awaits the two Streamable HTTP streams, so there is no call whose return says
    /// the request is over. The configured server seeing the `GET` is the first half; the
    /// second is either the follow-up arriving, or a bounded wait for one that must not.
    private static func settle(
        server: RedirectStubServer,
        other: RedirectStubServer,
        followUp: String?
    ) async throws {
        _ = try await wait(atMost: .seconds(5)) {
            await server.requests.contains { $0.method == "GET" }
        }
        if let followUp {
            _ = try await wait(atMost: .seconds(5)) {
                await server.requests.contains { $0.path == followUp }
            }
        } else {
            _ = try await wait(atMost: .milliseconds(400)) { await !other.requests.isEmpty }
        }
    }
}

// MARK: - Across origins

/// Whether a redirect can carry a request off the origin the caller configured.
///
/// Two servers on loopback. The first is the one the transport was pointed at, and answers
/// one request with a redirect to the second. What the transport decided is not the evidence
/// — what arrived is. For a redirect that leaves the origin, the second server must have been
/// sent nothing at all: not the custom header, not the session id, not the body, and not a
/// bare request either, because the request itself says where the client was and what it
/// was doing.
@Suite("Redirects — across origins (wire)")
struct CrossOriginRedirectWireTests {

    @Test("A redirect to another origin is not followed",
          .timeLimit(.minutes(2)),
          arguments: RedirectedRequest.allCases, RedirectRun.statuses)
    func nothingCrossesTheOrigin(_ request: RedirectedRequest, _ code: Int) async throws {
        let seen = try await RedirectRun.run(request, status: code)
        #expect(seen.other.isEmpty, "\(request) \(code): the other origin received \(seen.crossed)")
        // The redirect was met — otherwise an empty second server proves nothing.
        #expect(seen.configured(at: request.path).contains { $0.method == request.method.rawValue })
        // And where there is a caller to tell, it is told which origin it was asked to go to.
        if request.surfacesFailure {
            #expect(RedirectRun.refusedDestination(seen.failure) == seen.otherOrigin,
                    "\(request) \(code) ended with \(String(describing: seen.failure))")
        }
    }

    /// The same, with the credential coming from an `authorization:` provider instead of the
    /// static headers. The provider's value must never be seen off the origin, and nor may
    /// anything else.
    @Test("A redirect to another origin is not followed when a provider supplies the token",
          .timeLimit(.minutes(2)),
          arguments: RedirectedRequest.allCases, [302, 307])
    func nothingCrossesWithAProvider(_ request: RedirectedRequest, _ code: Int) async throws {
        let seen = try await RedirectRun.run(
            request, status: code, provider: { _ in Watched.providerAuthorization })
        #expect(seen.other.isEmpty, "\(request) \(code): the other origin received \(seen.crossed)")
        #expect(!seen.other.contains { $0.header("Authorization") == Watched.providerAuthorization })
    }

    /// One way of spelling "somewhere else" in a `Location`.
    enum Elsewhere: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Another host that is the same machine: `localhost` is not `127.0.0.1`.
        case otherHost
        /// `//host/path`, which reads like a path and replaces the authority.
        case protocolRelative
        /// Userinfo on the other origin.
        case userinfo
        /// The configured authority as userinfo, so the URL reads as one host and reaches another.
        case userinfoLookalike

        var testDescription: String { rawValue }

        func location(otherPort: Int) -> String {
            switch self {
            case .otherHost: return "http://localhost:\(otherPort)/elsewhere"
            case .protocolRelative: return "//127.0.0.1:\(otherPort)/elsewhere"
            case .userinfo: return "http://user:pw@127.0.0.1:\(otherPort)/elsewhere"
            case .userinfoLookalike: return "http://127.0.0.1:80@127.0.0.1:\(otherPort)/elsewhere"
            }
        }

        /// The origin an error is expected to name for it, given the second server's.
        func origin(of otherOrigin: String) -> String {
            switch self {
            case .otherHost: return otherOrigin.replacingOccurrences(of: "127.0.0.1", with: "localhost")
            default: return otherOrigin
            }
        }
    }

    @Test("However the other origin is spelled, nothing is sent to it",
          .timeLimit(.minutes(2)),
          arguments: [RedirectedRequest.sseStreamGET, .ssePOST, .streamablePOSTInitialize, .streamableDELETE],
          Elsewhere.allCases)
    func spellingsOfElsewhere(_ request: RedirectedRequest, _ elsewhere: Elsewhere) async throws {
        let seen = try await RedirectRun.run(
            request, status: 307, location: { elsewhere.location(otherPort: $0) })
        #expect(seen.other.isEmpty, "\(request) → \(elsewhere): the other origin received \(seen.crossed)")
        if request.surfacesFailure {
            #expect(RedirectRun.refusedDestination(seen.failure) == elsewhere.origin(of: seen.otherOrigin),
                    "\(request) → \(elsewhere) ended with \(String(describing: seen.failure))")
        }
    }

    /// What the error says is what ends up in a log and in front of an operator. A `Location`
    /// is the server's to write, so everything in it but the origin is the server choosing
    /// what appears there — and its query is as likely as an endpoint's to be a session id.
    @Test("The error names the destination's origin and nothing more",
          .timeLimit(.minutes(1)),
          arguments: [RedirectedRequest.sseStreamGET, .ssePOST, .streamablePOSTInitialize])
    func errorNamesOriginOnly(_ request: RedirectedRequest) async throws {
        let seen = try await RedirectRun.run(
            request, status: 307,
            location: { "http://user:hunter2@127.0.0.1:\($0)/private/path?sessionId=\(Watched.session)" })

        #expect(RedirectRun.refusedDestination(seen.failure) == seen.otherOrigin)
        let text = String(describing: seen.failure)
        for secret in ["hunter2", "user", "/private/path", Watched.session] {
            #expect(!text.contains(secret), "the error carries \(secret): \(text)")
        }
        // The origin the caller configured is named, so the message says what was expected.
        #expect(text.contains(seen.configuredOrigin))
        #expect(seen.other.isEmpty)
    }

    /// A refusal is a decision, not a transient failure. Retrying it re-opens the stream —
    /// credentials attached — to be told the same thing, after seconds of backoff.
    @Test("A refused redirect of the legacy stream is not retried", .timeLimit(.minutes(1)))
    func legacyConnectIsNotRetried() async throws {
        let other = try await RedirectStubServer.start(kind: .legacySSE)
        let server = try await RedirectStubServer.start(
            kind: .legacySSE,
            redirects: [.init(
                method: .GET, status: .temporaryRedirect,
                location: "http://127.0.0.1:\(try await other.port)/elsewhere")])
        let transport = HTTPSSETransport(
            url: try await server.url,
            connectionTimeout: 5,
            maxReconnectAttempts: 3,
            reconnectBaseDelay: 0.01)

        let otherOrigin = "http://127.0.0.1:\(try await other.port)"
        await #expect("connect() followed the redirect, or failed some other way") {
            try await transport.connect()
        } throws: { RedirectRun.refusedDestination($0) == otherOrigin }
        #expect(await server.requests.count == 1)
        #expect(await other.requests.isEmpty)
        try await transport.disconnect()
        await server.stop()
        await other.stop()
    }

    /// The server stream reconnects on its own, with backoff, for as long as the transport
    /// lives. A refused redirect has to end that loop, or the transport spends the session
    /// asking a question it has already been answered.
    @Test("A refused redirect of the server stream ends it instead of reconnecting",
          .timeLimit(.minutes(1)))
    func serverStreamIsNotRetried() async throws {
        let other = try await RedirectStubServer.start(kind: .streamable)
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                method: .GET, status: .temporaryRedirect,
                location: "http://127.0.0.1:\(try await other.port)/elsewhere")])
        let transport = StreamableHTTPTransport(url: try await server.url, connectionTimeout: 5)
        try await transport.connect()
        try await transport.send(Watched.initialize)
        await transport.didNegotiate(protocolVersion: "2025-06-18")

        // The first reconnect would come two seconds after the first attempt failed.
        try await Task.sleep(for: .milliseconds(2600))
        #expect(await server.requests.filter { $0.method == "GET" }.count == 1)
        #expect(await other.requests.isEmpty)

        // Request and response are untouched by losing the stream.
        try await transport.send(Watched.body)
        #expect(await server.requests.filter { $0.method == "POST" }.count == 2)
        try await transport.disconnect()
        await server.stop()
        await other.stop()
    }

    /// The downgrade, on the wire. The configured server is HTTPS, with a certificate minted
    /// for the test and supplied as the only root; the redirect names a plaintext server.
    /// Following it puts whatever the request carried on the network in the clear.
    @Test("An https request is not redirected to plain http",
          .timeLimit(.minutes(2)),
          arguments: RedirectedRequest.allCases, [302, 307])
    func downgradeIsNotFollowed(_ request: RedirectedRequest, _ code: Int) async throws {
        let seen = try await RedirectRun.run(request, status: code, tls: true)
        #expect(seen.other.isEmpty,
                "\(request) \(code): the plaintext server received \(seen.crossed)")
        #expect(seen.configured(at: request.path).contains { $0.method == request.method.rawValue })
        if request.surfacesFailure {
            #expect(RedirectRun.refusedDestination(seen.failure) == seen.otherOrigin)
        }
    }

    /// The factory reads a failed `server/discover` as evidence about the server's era, and
    /// falls back to `initialize`. A refused redirect is not evidence about the era, and the
    /// fallback would send a second request into the same redirect.
    @Test("The connection factory does not try a second handshake through a refused redirect",
          .timeLimit(.minutes(1)))
    func factoryDoesNotFallBack() async throws {
        let other = try await RedirectStubServer.start(kind: .streamable)
        let otherOrigin = "http://127.0.0.1:\(try await other.port)"
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(method: .POST, status: .temporaryRedirect, location: "\(otherOrigin)/elsewhere")])
        let transport = StreamableHTTPTransport(
            url: try await server.url, openServerStream: false, connectionTimeout: 5)

        await #expect("the factory connected, or failed some other way") {
            _ = try await MCPConnectionFactory.connect(
                transport: transport, clientName: "probe", clientVersion: "1.0")
        } throws: { RedirectRun.refusedDestination($0) == otherOrigin }

        #expect(await server.requests.filter { $0.method == "POST" }.count == 1)
        #expect(await other.requests.isEmpty)
        try await transport.disconnect()
        await server.stop()
        await other.stop()
    }

    /// Leaving and coming back is still leaving: the hop in the middle is a request to
    /// another origin, and that request is the thing being refused.
    @Test("A chain that leaves the origin and returns is stopped at the first hop",
          .timeLimit(.minutes(2)),
          arguments: [RedirectedRequest.ssePOST, .streamablePOSTInitialize])
    func leavesAndReturns(_ request: RedirectedRequest) async throws {
        let seen = try await RedirectRun.run(
            request, status: 307,
            location: { "http://127.0.0.1:\($0)/hop" },
            otherRedirects: { configured in
                [RedirectStubServer.Redirect(path: "/hop", status: .temporaryRedirect, location: "\(configured)/back")]
            })
        #expect(seen.other.isEmpty, "\(request): the other origin received \(seen.crossed)")
        #expect(seen.configured(at: "/back").isEmpty, "the chain was followed back")
        #expect(RedirectRun.refusedDestination(seen.failure) == seen.otherOrigin)
    }
}

// MARK: - Within the origin

/// Redirects that stay on the configured origin keep working, and keep their meaning.
@Suite("Redirects — within the origin (wire)")
struct SameOriginRedirectWireTests {

    @Test("A relative redirect is followed, with the method the status asks for",
          .timeLimit(.minutes(2)),
          arguments: RedirectedRequest.allCases, RedirectRun.statuses)
    func relativeRedirectIsFollowed(_ request: RedirectedRequest, _ code: Int) async throws {
        let seen = try await RedirectRun.run(
            request, status: code, location: { _ in "/moved" }, followUp: "/moved")

        let followed = seen.configured(at: "/moved")
        #expect(followed.count == 1, "\(request) \(code): /moved received \(RedirectRun.describe(followed))")
        let arrived = try #require(followed.first, "\(request) \(code): the redirect was not followed")

        let method = request.methodAfter(code)
        #expect(arrived.method == method)
        // Same origin, so everything the request carried goes with it.
        #expect(arrived.header(Watched.keyHeader) == Watched.key)
        #expect(arrived.header("Authorization") == Watched.staticAuthorization)
        if request.method == .POST {
            // The body goes exactly when the method does.
            #expect(arrived.body.contains(Watched.bodyMarker) == (method == "POST"))
        }
        if request == .streamablePOSTInSession || request == .streamableDELETE {
            #expect(arrived.header("Mcp-Session-Id") == Watched.session)
        }
        if request == .streamableResumptionGET {
            #expect(arrived.header("Last-Event-ID") == Watched.eventID)
        }
        if request.surfacesFailure, method == request.method.rawValue {
            #expect(seen.failure == nil, "\(request) \(code) failed: \(String(describing: seen.failure))")
        }
        #expect(seen.other.isEmpty)
    }

    @Test("An absolute redirect naming the same origin is followed",
          .timeLimit(.minutes(2)),
          arguments: [RedirectedRequest.ssePOST, .streamablePOSTInitialize, .sseStreamGET])
    func absoluteSameOriginIsFollowed(_ request: RedirectedRequest) async throws {
        let seen = try await RedirectRun.run(
            request, status: 308, location: { _ in "{self}/moved?step=2" }, followUp: "/moved")
        #expect(seen.configured(at: "/moved").map(\.target) == ["/moved?step=2"])
        #expect(seen.failure == nil, "failed: \(String(describing: seen.failure))")
    }

    /// The provider is asked for the token of each request that is actually sent, and a
    /// redirected request is one. A token that expired between the two is the case this
    /// exists for.
    @Test("The authorization provider is asked again for the redirected request",
          .timeLimit(.minutes(2)),
          arguments: [RedirectedRequest.ssePOST, .streamablePOSTInitialize])
    func providerIsAskedPerHop(_ request: RedirectedRequest) async throws {
        let asked = AskCount()
        let seen = try await RedirectRun.run(
            request, status: 307, location: { _ in "/moved" },
            provider: { _ in "Bearer issue-\(await asked.next())" },
            followUp: "/moved")

        let first = try #require(seen.configured(at: request.path).last?.header("Authorization"))
        let second = try #require(seen.configured(at: "/moved").first?.header("Authorization"))
        #expect(first != second, "both hops carried \(first)")
        #expect(second.hasPrefix("Bearer issue-"))
    }

    /// The stream is the point of the `GET`: following a redirect and then failing to stream
    /// would be a connection that looks open and delivers nothing.
    @Test("A redirected legacy stream still delivers its endpoint and takes messages",
          .timeLimit(.minutes(1)))
    func legacyStreamStillStreams() async throws {
        let server = try await RedirectStubServer.start(
            kind: .legacySSE,
            redirects: [.init(method: .GET, path: "/sse", status: .temporaryRedirect, location: "/sse-moved")])
        let transport = HTTPSSETransport(
            url: try await server.url, connectionTimeout: 5, maxReconnectAttempts: 0)
        try await transport.connect()
        try await transport.send(Watched.body)
        #expect(await server.requests.map(\.path) == ["/sse", "/sse-moved", "/messages"])
        try await transport.disconnect()
        await server.stop()
    }

    @Test("A redirected server stream still delivers server-initiated messages",
          .timeLimit(.minutes(1)))
    func serverStreamStillStreams() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(method: .GET, path: "/mcp", status: .permanentRedirect, location: "/mcp-stream")])
        let transport = StreamableHTTPTransport(url: try await server.url, connectionTimeout: 5)
        try await transport.connect()
        try await transport.send(Watched.initialize)
        let response = try await transport.receive()
        #expect(String(decoding: response, as: UTF8.self).contains(#""result""#))

        await transport.didNegotiate(protocolVersion: "2025-06-18")
        let pushed = try await transport.receive()
        #expect(String(decoding: pushed, as: UTF8.self).contains("notifications/stub"))
        try await transport.disconnect()
        await server.stop()
    }

    /// `POST /mcp` answered `303` to `/mcp` is "now fetch the result", not a loop: the second
    /// request is a `GET`. `AsyncHTTPClient` compared URLs alone and refused it as a cycle.
    @Test("A 303 back to the same URL is followed as a GET", .timeLimit(.minutes(1)))
    func seeOtherToTheSameURL() async throws {
        let seen = try await RedirectRun.run(
            .streamablePOSTInitialize, status: 303, location: { _ in "/mcp" })
        #expect(seen.configured.map(\.method) == ["POST", "GET"])
        #expect(seen.failure == nil, "failed: \(String(describing: seen.failure))")
    }

    /// `/mcp` → `/again` → `/mcp`. Nothing here leaves the origin; what it must not do is run
    /// forever.
    @Test("A redirect loop ends in an error after a bounded number of requests",
          .timeLimit(.minutes(2)),
          arguments: [RedirectedRequest.ssePOST, .streamablePOSTInitialize])
    func loopIsBounded(_ request: RedirectedRequest) async throws {
        let seen = try await RedirectRun.run(
            request, status: 307, location: { _ in "/again" },
            more: [.init(path: "/again", status: .temporaryRedirect, location: request.path)])
        #expect(RedirectRun.isConnectionFailure(seen.failure),
                "a loop ended with \(String(describing: seen.failure))")
        #expect(seen.configured.filter { $0.method == "POST" }.count <= 6)
    }

    /// Six redirects in a row, each to somewhere new. Five are followed; the sixth is one
    /// too many.
    @Test("No more than five redirects are followed",
          .timeLimit(.minutes(2)),
          arguments: [RedirectedRequest.ssePOST, .streamablePOSTInitialize])
    func hopsAreCapped(_ request: RedirectedRequest) async throws {
        let chain = (1...6).map { hop in
            RedirectStubServer.Redirect(
                path: "/hop\(hop)", status: .temporaryRedirect, location: "/hop\(hop + 1)")
        }
        let seen = try await RedirectRun.run(
            request, status: 307, location: { _ in "/hop1" }, more: chain)
        #expect(RedirectRun.isConnectionFailure(seen.failure),
                "seven hops ended with \(String(describing: seen.failure))")
        #expect(seen.configured.filter { $0.method == "POST" }.map(\.path)
                == [request.path, "/hop1", "/hop2", "/hop3", "/hop4", "/hop5"])
    }
}

/// Counts how many times a provider was asked, and makes each answer different.
actor AskCount {
    private var count = 0

    /// The number of this ask, starting at one.
    func next() -> Int {
        count += 1
        return count
    }
}

// MARK: - WebSocket

/// What the WebSocket transport does when its upgrade request is answered with a redirect.
///
/// `WebSocketKit` sends one `GET` with the upgrade headers and treats any answer but `101`
/// as a failed upgrade; it has no redirect handling to configure. Recorded on the wire
/// rather than taken from a reading of its source, because a dependency update is exactly
/// what would change it.
@Suite("Redirects — WebSocket upgrade (wire)")
struct WebSocketRedirectWireTests {

    @Test("A redirected upgrade is not followed, on any status",
          .timeLimit(.minutes(1)),
          arguments: RedirectRun.statuses)
    func upgradeRedirectIsNotFollowed(_ code: Int) async throws {
        let other = try await RedirectStubServer.start(kind: .streamable)
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                status: HTTPResponseStatus(statusCode: code),
                location: "http://127.0.0.1:\(try await other.port)/elsewhere")])

        var components = try #require(URLComponents(url: try await server.url(path: "/ws"), resolvingAgainstBaseURL: false))
        components.scheme = "ws"
        let transport = WebSocketTransport(
            url: try #require(components.url),
            headers: [Watched.keyHeader: Watched.key, "Authorization": Watched.staticAuthorization])

        await #expect(throws: MCPError.self) { try await transport.connect() }

        let elsewhere = await other.requests
        #expect(elsewhere.isEmpty, "the other origin received \(RedirectRun.describe(elsewhere))")
        // The one request is all there ever is.
        #expect(await server.requests.map(\.path) == ["/ws"])
        try await transport.disconnect()
        await server.stop()
        await other.stop()
    }
}
