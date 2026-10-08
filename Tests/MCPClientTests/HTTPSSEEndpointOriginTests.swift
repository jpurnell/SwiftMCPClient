import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// Where the legacy HTTP+SSE transport is willing to POST.
///
/// The server's first event, `endpoint`, names the URI every JSON-RPC message is then sent to —
/// with the caller's `Authorization` header on it. The value is the server's to choose, so a
/// compromised server, or anything able to write into the stream, chooses it too. A relative
/// path cannot leave the origin the caller configured. An absolute URL can, and so can
/// `//host/path`, which reads like a path and is not one.
///
/// The rule under test is the one the TypeScript and Python reference clients apply: the
/// resolved endpoint must share the stream's origin — scheme, host and effective port.
@Suite("HTTP+SSE — endpoint origin (resolution)")
struct HTTPSSEEndpointResolutionTests {

    private static let stream = "https://good.example/mcp/sse"

    /// One `endpoint` value and where it must resolve to.
    struct Accepted: Sendable, CustomTestStringConvertible {
        let raw: String
        let destination: String
        var testDescription: String { raw }
    }

    /// One `endpoint` value that must be refused, and what it is an example of.
    struct Refused: Sendable, CustomTestStringConvertible {
        let raw: String
        let why: String
        var testDescription: String { "\(why): \(raw)" }
    }

    static let accepted: [Accepted] = [
        Accepted(raw: "/messages?sessionId=abc", destination: "https://good.example/messages?sessionId=abc"),
        Accepted(raw: "messages", destination: "https://good.example/mcp/messages"),
        Accepted(raw: "?sessionId=1", destination: "https://good.example/mcp/sse?sessionId=1"),
        // `..` cannot climb out of an origin: RFC 3986 resolution stops at the root.
        Accepted(raw: "../messages", destination: "https://good.example/messages"),
        Accepted(raw: "/a/../../b", destination: "https://good.example/b"),
        Accepted(raw: "../../../../etc", destination: "https://good.example/etc"),
        // Backslashes are data, not separators — they must not be read as `//`.
        Accepted(raw: "/\\evil.test/x", destination: "https://good.example/%5Cevil.test/x"),
        // An absolute URL naming the same origin, however it is spelled.
        Accepted(raw: "https://good.example/messages", destination: "https://good.example/messages"),
        Accepted(raw: "HTTPS://GOOD.EXAMPLE/messages", destination: "HTTPS://GOOD.EXAMPLE/messages"),
        Accepted(raw: "https://good.example:443/messages", destination: "https://good.example:443/messages"),
        // A fragment is never sent in a request, so it is dropped rather than refused.
        Accepted(raw: "/messages?s=1#frag", destination: "https://good.example/messages?s=1"),
    ]

    static let refused: [Refused] = [
        Refused(raw: "https://evil.test/messages", why: "another host"),
        Refused(raw: "//evil.test/messages", why: "protocol-relative"),
        Refused(raw: "ws://good.example/messages", why: "another scheme"),
        Refused(raw: "https://good.example:8443/messages", why: "another port"),
        Refused(raw: "https://good.example.evil.test/x", why: "look-alike suffix"),
        Refused(raw: "https://evilgood.example/x", why: "look-alike prefix"),
        Refused(raw: "https://good.example%2eevil.test/x", why: "look-alike, encoded"),
        Refused(raw: "https://good.example./x", why: "trailing-dot host"),
        Refused(raw: "https://good.example@evil.test/x", why: "userinfo hiding the host"),
        Refused(raw: "https://good.example\\@evil.test/x", why: "userinfo hiding the host"),
        Refused(raw: "https://user:pw@good.example/x", why: "userinfo on the right host"),
        Refused(raw: "https://user@good.example/x", why: "userinfo on the right host"),
        Refused(raw: "https:evil.test/x", why: "no authority"),
        Refused(raw: "file:///etc/passwd", why: "not HTTP"),
        Refused(raw: "javascript:alert(1)", why: "not HTTP"),
    ]

    @Test("A same-origin endpoint resolves to where it says", arguments: accepted)
    func sameOriginIsAccepted(_ example: Accepted) throws {
        let resolved = try HTTPSSETransport.resolveEndpoint(
            example.raw, against: try requireURL(Self.stream))
        #expect(resolved.absoluteString == example.destination)
    }

    @Test("An endpoint on another origin is refused", arguments: refused)
    func otherOriginIsRefused(_ example: Refused) throws {
        let stream = try requireURL(Self.stream)
        #expect("\(example.why) was accepted") {
            _ = try HTTPSSETransport.resolveEndpoint(example.raw, against: stream)
        } throws: { error in
            guard case MCPError.endpointRejected = error else { return false }
            return true
        }
    }

    /// The downgrade: the stream is `https`, the endpoint is the same host over `http`. A
    /// different origin, and the one refusal here that is about confidentiality on the path
    /// rather than about who is at the other end.
    @Test("A plaintext endpoint for an https stream is refused")
    func downgradeIsRefused() throws {
        let stream = try requireURL(Self.stream)
        let downgraded = try Self.plaintext("https://good.example/messages")
        let downgradedOrigin = try Self.plaintext("https://good.example")
        #expect(downgraded.hasPrefix("http:"))
        #expect(throws: MCPError.endpointRejected(
            endpoint: downgradedOrigin,
            reason: "Endpoint origin does not match connection origin https://good.example; nothing was sent to it")
        ) {
            _ = try HTTPSSETransport.resolveEndpoint(downgraded, against: stream)
        }
    }

    /// The reverse is a different origin too: an origin is not "at least as secure as".
    @Test("An https endpoint for a plaintext stream is refused")
    func upgradeIsRefused() throws {
        let stream = try requireURL(try Self.plaintext("https://good.example/sse"))
        #expect(throws: MCPError.self) {
            _ = try HTTPSSETransport.resolveEndpoint("https://good.example/messages", against: stream)
        }
    }

    /// The same URL over plaintext.
    private static func plaintext(_ secure: String) throws -> String {
        var components = try #require(URLComponents(string: secure))
        components.scheme = "http"
        return try #require(components.string)
    }

    /// The default port is the same origin whether or not it is written down, in either
    /// position — and for plaintext as well as `https`.
    @Test("An explicit default port is the same origin")
    func defaultPortsAreEquivalent() throws {
        let spelled = try HTTPSSETransport.resolveEndpoint(
            "/messages", against: try requireURL("https://good.example:443/sse"))
        #expect(spelled.absoluteString == "https://good.example:443/messages")

        let plain = try Self.plaintext("https://good.example/messages")
        let implied = try HTTPSSETransport.resolveEndpoint(
            plain, against: try requireURL(try Self.plaintext("https://good.example:80/sse")))
        #expect(implied.absoluteString == plain)

        #expect(throws: MCPError.self) {
            _ = try HTTPSSETransport.resolveEndpoint(
                "https://good.example:80/messages", against: try requireURL("https://good.example/sse"))
        }
    }

    /// What the error says is what ends up in a log and in front of an operator, so it names
    /// the origin and nothing else: no userinfo, and no path or query — a legacy endpoint's
    /// query is usually the session id.
    @Test("The error names the offending origin and nothing more")
    func errorCarriesOriginOnly() throws {
        let stream = try requireURL(Self.stream)
        do {
            _ = try HTTPSSETransport.resolveEndpoint(
                "https://user:hunter2@evil.test:8443/messages?sessionId=secret", against: stream)
            Issue.record("a cross-origin endpoint was accepted")
        } catch MCPError.endpointRejected(let endpoint, let reason) {
            #expect(endpoint == "https://evil.test:8443")
            #expect(!reason.contains("hunter2"))
            #expect(!reason.contains("secret"))
            #expect(reason.contains("https://good.example"))
        }
    }

    /// An endpoint that is not a URL at all stays the error it always was.
    @Test("An unparseable endpoint is still a failed connection")
    func unparseableIsConnectionFailed() throws {
        let stream = try requireURL(Self.stream)
        #expect(throws: MCPError.connectionFailed(reason: "The server's endpoint event is not a usable URL")) {
            _ = try HTTPSSETransport.resolveEndpoint("", against: stream)
        }
    }

    /// 0.14.0 refused every endpoint, a plain path included, when the *configured* URL
    /// carried userinfo — the path inherits it, and inherited userinfo looked like supplied
    /// userinfo. What the caller wrote is the caller's; what the server adds is not.
    @Test("A relative endpoint keeps the userinfo the configured URL already had")
    func configuredUserinfoIsNotTheServers() throws {
        let stream = try requireURL("https://caller:theirs@good.example/sse")
        let resolved = try HTTPSSETransport.resolveEndpoint("/messages", against: stream)
        #expect(resolved.absoluteString == "https://caller:theirs@good.example/messages")

        #expect(throws: MCPError.self) {
            _ = try HTTPSSETransport.resolveEndpoint("https://other:theirs@good.example/messages", against: stream)
        }
    }
}

/// The same rule, observed from the far end of the socket.
///
/// Two servers on loopback. One is the server the caller configured; the other stands in for
/// wherever a hostile `endpoint` event points. What a transport *decided* is not the evidence
/// here — what arrived is: the second server must have been asked nothing at all.
@Suite("HTTP+SSE — endpoint origin (wire)")
struct HTTPSSEEndpointOriginWireTests {

    /// The `Authorization` value whose travels these tests watch. Not a credential for
    /// anything: it exists to be recognised if it turns up at the wrong server.
    private static let watched = "Bearer do-not-leak"

    @Test("A relative endpoint is posted to the stream's origin, with the header",
          .timeLimit(.minutes(1)))
    func relativeEndpointUnchanged() async throws {
        let server = try await SSEStubServer.start(replies: [.ok("{}")], endpoint: "/messages")
        let transport = try await Self.transport(for: server)
        do {
            try await transport.connect()
            try await transport.send(Data("{}".utf8))
            #expect(await server.received.map(\.authorization) == [Self.watched])
            await Self.tearDown(transport, server)
        } catch {
            await Self.tearDown(transport, server)
            throw error
        }
    }

    @Test("An absolute endpoint on the same origin is accepted", .timeLimit(.minutes(1)))
    func absoluteSameOriginAccepted() async throws {
        let server = try await SSEStubServer.start(
            replies: [.ok("{}")], endpoint: "{origin}/messages?sessionId=1")
        let transport = try await Self.transport(for: server)
        do {
            try await transport.connect()
            try await transport.send(Data("{}".utf8))
            #expect(await server.received.map(\.authorization) == [Self.watched])
            await Self.tearDown(transport, server)
        } catch {
            await Self.tearDown(transport, server)
            throw error
        }
    }

    /// The finding itself. Before the check, `connect()` succeeded and the POST — token and
    /// all — arrived at the second server.
    @Test("An endpoint on another host is refused, and nothing is sent there",
          .timeLimit(.minutes(1)))
    func otherHostReceivesNothing() async throws {
        // `localhost` and `127.0.0.1` are the same machine and different hosts, which is
        // exactly the distinction an origin check draws.
        let outcome = try await Self.handshake { other in "http://localhost:\(other)/messages" }
        #expect(outcome.refused, "connect() ended with \(outcome.ending)")
        #expect(outcome.otherOrigin.isEmpty, "the other origin was sent \(outcome.otherOrigin)")
        #expect(outcome.configuredPosts.isEmpty)
    }

    @Test("An endpoint on another port is refused, and nothing is sent there",
          .timeLimit(.minutes(1)))
    func otherPortReceivesNothing() async throws {
        let outcome = try await Self.handshake { other in "http://127.0.0.1:\(other)/messages" }
        #expect(outcome.refused, "connect() ended with \(outcome.ending)")
        #expect(outcome.otherOrigin.isEmpty, "the other origin was sent \(outcome.otherOrigin)")
        #expect(outcome.configuredPosts.isEmpty)
    }

    @Test("A protocol-relative endpoint is refused, and nothing is sent there",
          .timeLimit(.minutes(1)))
    func protocolRelativeReceivesNothing() async throws {
        let outcome = try await Self.handshake { other in "//127.0.0.1:\(other)/messages" }
        #expect(outcome.refused, "connect() ended with \(outcome.ending)")
        #expect(outcome.otherOrigin.isEmpty, "the other origin was sent \(outcome.otherOrigin)")
        #expect(outcome.configuredPosts.isEmpty)
    }

    @Test("Userinfo pointing elsewhere is refused, and nothing is sent there",
          .timeLimit(.minutes(1)))
    func userinfoReceivesNothing() async throws {
        let outcome = try await Self.handshake { other in "//{authority}@127.0.0.1:\(other)/messages" }
        #expect(outcome.refused, "connect() ended with \(outcome.ending)")
        #expect(outcome.otherOrigin.isEmpty, "the other origin was sent \(outcome.otherOrigin)")
        #expect(outcome.configuredPosts.isEmpty)
    }

    /// Scheme and userinfo on the *right* host: there is no second server for a request to
    /// reach, so the evidence is that `connect()` refuses and the configured server is never
    /// posted to either.
    @Test("Another scheme, or userinfo, on the same host is refused",
          .timeLimit(.minutes(1)),
          arguments: ["https://{authority}/messages", "//user:pw@{authority}/messages"])
    func sameHostVariantsRefused(_ endpoint: String) async throws {
        let server = try await SSEStubServer.start(replies: [.ok("{}")], endpoint: endpoint)
        let transport = try await Self.transport(for: server)
        await #expect("connect() accepted \(endpoint)") {
            try await transport.connect()
        } throws: { error in
            guard case MCPError.endpointRejected = error else { return false }
            return true
        }
        #expect(await server.received.isEmpty)
        await Self.tearDown(transport, server)
    }

    /// A refusal is a decision, not a transient failure. Retrying it re-opens the stream —
    /// token attached — to be told the same thing, after seconds of backoff.
    @Test("A refused endpoint is not retried", .timeLimit(.minutes(1)))
    func refusalIsNotRetried() async throws {
        let server = try await SSEStubServer.start(
            replies: [.ok("{}")], endpoint: "http://localhost:9/messages")
        let transport = HTTPSSETransport(
            url: try await server.url,
            headers: ["Authorization": Self.watched],
            connectionTimeout: 5,
            maxReconnectAttempts: 3,
            reconnectBaseDelay: 0.01)
        await #expect(throws: MCPError.self) { try await transport.connect() }
        #expect(await server.streamOpens.count == 1)
        await Self.tearDown(transport, server)
    }

    /// The other route to the same place. 0.14.0 pinned what `AsyncHTTPClient` did with this
    /// redirect — it followed it, without `Authorization` but with everything else. The
    /// transport now decides for itself, and the answer is the one the endpoint gets: nothing
    /// is sent to another origin. The whole matrix is in `TransportRedirectWireTests`.
    @Test("A cross-origin redirect of the POST is refused, and nothing is sent there",
          .timeLimit(.minutes(1)))
    func redirectIsNotFollowedOffOrigin() async throws {
        let other = try await SSEStubServer.start(replies: [.ok("{}")])
        let otherPort = try await other.port
        let server = try await SSEStubServer.start(
            replies: [.ok("{}")],
            redirectingPostsTo: "http://127.0.0.1:\(otherPort)/elsewhere")
        let transport = try await Self.transport(for: server)
        do {
            try await transport.connect()
            await #expect(throws: MCPError.redirectRejected(
                destination: "http://127.0.0.1:\(otherPort)",
                reason: "HTTP 307 redirect leaves the configured origin "
                    + "http://127.0.0.1:\(try await server.port); nothing was sent to it")
            ) {
                try await transport.send(Data("{}".utf8))
            }
            #expect(await server.received.map(\.authorization) == [Self.watched])
            #expect(await other.received.isEmpty, "the redirect target was sent a request")
            await Self.tearDown(transport, server)
            await other.stop()
        } catch {
            await Self.tearDown(transport, server)
            await other.stop()
            throw error
        }
    }

    // MARK: - Helpers

    /// A transport pointed at `server`, carrying the token whose travels are being watched.
    private static func transport(for server: SSEStubServer) async throws -> HTTPSSETransport {
        HTTPSSETransport(
            url: try await server.url,
            headers: ["Authorization": watched],
            connectionTimeout: 5,
            maxReconnectAttempts: 0)
    }

    private static func tearDown(_ transport: HTTPSSETransport, _ server: SSEStubServer) async {
        // silent: a transport that never connected has nothing to disconnect
        try? await transport.disconnect()
        await server.stop()
    }

    /// What a handshake pointed at a second server came to.
    struct Outcome: Sendable {
        /// Whether `connect()` threw `endpointRejected`.
        let refused: Bool
        /// How `connect()` ended, for a failure message.
        let ending: String
        /// The `Authorization` of every request the second server received — stream opens and
        /// POSTs alike. Empty is the only acceptable value.
        let otherOrigin: [String?]
        /// The `Authorization` of every POST the configured server received.
        let configuredPosts: [String?]
    }

    /// Runs a handshake whose `endpoint` event points at a second server, and reports what
    /// each server heard.
    ///
    /// A `send` is attempted if `connect()` succeeds. That is what makes a test fail for the
    /// right reason against a transport with no check: there the connect succeeds, the send
    /// goes out, and the second server records the header.
    ///
    /// - Parameter endpoint: Builds the `endpoint` value from the second server's port.
    private static func handshake(_ endpoint: (Int) -> String) async throws -> Outcome {
        let other = try await SSEStubServer.start(replies: [.ok("{}")])
        let value = endpoint(try await other.port)
        let server = try await SSEStubServer.start(replies: [.ok("{}")], endpoint: value)
        let transport = try await transport(for: server)

        var refused = false
        var ending = "success"
        do {
            try await transport.connect()
            // silent: the send's own outcome is not the evidence; what arrived is
            try? await transport.send(Data("{}".utf8))
        } catch MCPError.endpointRejected {
            refused = true
            ending = "endpointRejected"
        } catch {
            ending = "\(error)"
        }

        let heard = await other.streamOpens.map(\.authorization) + other.received.map(\.authorization)
        let posts = await server.received.map(\.authorization)
        await tearDown(transport, server)
        await other.stop()
        return Outcome(refused: refused, ending: ending, otherOrigin: heard, configuredPosts: posts)
    }
}
