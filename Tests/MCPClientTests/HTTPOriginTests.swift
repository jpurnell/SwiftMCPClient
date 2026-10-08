import Foundation
import Testing
import AsyncHTTPClient
import NIOHTTP1
@testable import MCPClient

/// The decision a redirect is held to, asked without a socket.
///
/// The wire tests show what arrives; they cannot show everything, because loopback has one
/// host and nothing there is a look-alike of anything. This is the same function those tests
/// exercise — ``HTTPOrigin/resolve(_:relativeTo:heldTo:)``, which the `endpoint` event also
/// goes through — put to the destinations a loopback stub cannot be.
@Suite("HTTPOrigin — where a server may send a request")
struct HTTPOriginDecisionTests {

    private static let configured = "https://good.example/mcp"

    /// A `Location`, and why it is an example.
    struct Destination: Sendable, CustomTestStringConvertible {
        let location: String
        let why: String
        var testDescription: String { "\(why): \(location)" }
    }

    static let followed: [Destination] = [
        Destination(location: "/moved", why: "absolute path"),
        Destination(location: "moved", why: "relative path"),
        Destination(location: "?step=2", why: "query only"),
        Destination(location: "../../../etc", why: "dot segments stop at the root"),
        Destination(location: "https://good.example/moved", why: "same origin, absolute"),
        Destination(location: "HTTPS://GOOD.EXAMPLE/moved", why: "same origin, other case"),
        Destination(location: "https://good.example:443/moved", why: "default port written out"),
        Destination(location: "/moved#fragment", why: "fragment"),
    ]

    /// A `Location` that must not be followed, and what it is refused as.
    struct Refusal: Sendable, CustomTestStringConvertible {
        let location: String
        let why: String
        let refusedAs: HTTPOrigin.Resolution
        var testDescription: String { "\(why): \(location)" }
    }

    static let refused: [Refusal] = [
        Refusal(location: "https://evil.test/mcp", why: "another host",
                refusedAs: .otherOrigin(origin: "https://evil.test")),
        Refusal(location: "//evil.test/mcp", why: "protocol-relative",
                refusedAs: .otherOrigin(origin: "https://evil.test")),
        Refusal(location: "https://good.example:8443/mcp", why: "another port",
                refusedAs: .otherOrigin(origin: "https://good.example:8443")),
        Refusal(location: "https://good.example.evil.test/mcp", why: "look-alike suffix",
                refusedAs: .otherOrigin(origin: "https://good.example.evil.test")),
        Refusal(location: "https://evilgood.example/mcp", why: "look-alike prefix",
                refusedAs: .otherOrigin(origin: "https://evilgood.example")),
        Refusal(location: "https://good.example./mcp", why: "trailing-dot host",
                refusedAs: .otherOrigin(origin: "https://good.example.")),
        Refusal(location: "https://good.example@evil.test/mcp", why: "userinfo hiding the host",
                refusedAs: .carriesUserinfo(origin: "https://evil.test")),
        Refusal(location: "https://user:pw@good.example/mcp", why: "userinfo on the right host",
                refusedAs: .carriesUserinfo(origin: "https://good.example")),
        Refusal(location: "wss://good.example/mcp", why: "another scheme",
                refusedAs: .otherOrigin(origin: "wss://good.example")),
        Refusal(location: "file:///etc/passwd", why: "not HTTP",
                refusedAs: .otherOrigin(origin: HTTPOrigin.noOrigin)),
    ]

    @Test("A destination on the configured origin is followed", arguments: followed)
    func sameOriginIsFollowed(_ example: Destination) throws {
        let configured = try requireURL(Self.configured)
        let resolution = HTTPOrigin.resolve(example.location, relativeTo: configured, heldTo: configured)
        guard case .sameOrigin(let url) = resolution else {
            Issue.record("\(example.why) was refused: \(resolution)")
            return
        }
        #expect(url.host?.lowercased() == "good.example")
        #expect(url.fragment == nil)
    }

    @Test("A destination on any other origin is refused", arguments: refused)
    func otherOriginIsRefused(_ example: Refusal) throws {
        let configured = try requireURL(Self.configured)
        let resolution = HTTPOrigin.resolve(example.location, relativeTo: configured, heldTo: configured)
        #expect(resolution == example.refusedAs, "\(example.why) came to \(resolution)")
    }

    /// A host with a percent-encoded dot. Whether Foundation decodes it, keeps it, or
    /// declines to parse it has differed between releases; in none of them is it the
    /// configured host, and that is the only thing asserted.
    @Test("A percent-encoded look-alike host is never the configured origin")
    func encodedLookalike() throws {
        let configured = try requireURL(Self.configured)
        let resolution = HTTPOrigin.resolve(
            "https://good.example%2eevil.test/mcp", relativeTo: configured, heldTo: configured)
        let acceptable: [HTTPOrigin.Resolution] = [
            .notAURL,
            .otherOrigin(origin: "https://good.example.evil.test"),
            .otherOrigin(origin: "https://good.example%2eevil.test"),
        ]
        #expect(acceptable.contains(resolution), "came to \(resolution)")
    }

    /// The downgrade. On the wire this is shown with a TLS stub redirecting to a plaintext
    /// one; here it is the same host, which loopback cannot arrange with one certificate.
    @Test("https to http on the same host is another origin")
    func downgradeIsRefused() throws {
        let configured = try requireURL(Self.configured)
        let plain = try Self.plaintext("https://good.example/mcp")
        let resolution = HTTPOrigin.resolve(plain, relativeTo: configured, heldTo: configured)
        #expect(resolution == .otherOrigin(origin: try Self.plaintext("https://good.example")))
    }

    /// And the reverse. An origin is not "at least as secure as": a transport configured for
    /// plaintext that is redirected to `https` is told so, and the caller configures `https`.
    @Test("http to https on the same host is another origin")
    func upgradeIsRefused() throws {
        let configured = try requireURL(try Self.plaintext("https://good.example/mcp"))
        let resolution = HTTPOrigin.resolve(
            "https://good.example/mcp", relativeTo: configured, heldTo: configured)
        #expect(resolution == .otherOrigin(origin: "https://good.example"))
    }

    /// A second redirect is relative to the first one's destination, and still held to the
    /// URL the caller configured — not to wherever the chain has got to.
    @Test("A later hop resolves against the current URL and is held to the configured one")
    func laterHops() throws {
        let configured = try requireURL(Self.configured)
        let current = try requireURL("https://good.example/a/b")
        #expect(HTTPOrigin.resolve("c", relativeTo: current, heldTo: configured)
                == .sameOrigin(try requireURL("https://good.example/a/c")))
        #expect(HTTPOrigin.resolve("//evil.test/c", relativeTo: current, heldTo: configured)
                == .otherOrigin(origin: "https://evil.test"))
    }

    @Test("What cannot be parsed is not a destination")
    func unparseable() throws {
        let configured = try requireURL(Self.configured)
        #expect(HTTPOrigin.resolve("", relativeTo: configured, heldTo: configured) == .notAURL)
        #expect(HTTPOrigin.resolve("https://[::1/x", relativeTo: configured, heldTo: configured) == .notAURL)
    }

    /// The same URL over plaintext.
    private static func plaintext(_ secure: String) throws -> String {
        var components = try #require(URLComponents(string: secure))
        components.scheme = "http"
        return try #require(components.string)
    }
}

/// What a redirect does to the request that met it.
///
/// `AsyncHTTPClient` decided this while it was following redirects; the transports follow
/// them now, and these are its rules, kept.
@Suite("SameOriginRedirects — the request a redirect asks for")
struct RedirectedRequestTests {

    /// One status and method, and the method that follows.
    struct Rewrite: Sendable, CustomTestStringConvertible {
        let status: UInt
        let method: HTTPMethod
        let becomes: HTTPMethod
        var testDescription: String { "\(status) \(method.rawValue) → \(becomes.rawValue)" }
    }

    static let rewrites: [Rewrite] = [
        Rewrite(status: 301, method: .POST, becomes: .GET),
        Rewrite(status: 302, method: .POST, becomes: .GET),
        Rewrite(status: 303, method: .POST, becomes: .GET),
        Rewrite(status: 307, method: .POST, becomes: .POST),
        Rewrite(status: 308, method: .POST, becomes: .POST),
        Rewrite(status: 301, method: .DELETE, becomes: .DELETE),
        Rewrite(status: 302, method: .DELETE, becomes: .DELETE),
        Rewrite(status: 303, method: .DELETE, becomes: .GET),
        Rewrite(status: 307, method: .DELETE, becomes: .DELETE),
        Rewrite(status: 303, method: .HEAD, becomes: .HEAD),
        Rewrite(status: 301, method: .GET, becomes: .GET),
    ]

    @Test("The method follows the status", arguments: rewrites)
    func method(_ rewrite: Rewrite) throws {
        var request = HTTPClientRequest(url: "https://good.example/mcp")
        request.method = rewrite.method
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: Watched.keyHeader, value: Watched.key)
        request.body = .bytes(Watched.body)

        let next = SameOriginRedirects.redirected(
            request, to: try requireURL("https://good.example/moved"), status: rewrite.status)

        #expect(next.method == rewrite.becomes)
        #expect(next.url == "https://good.example/moved")
        // Same origin: the caller's headers go with it.
        #expect(next.headers.first(name: Watched.keyHeader) == Watched.key)
        // The body, and the header describing it, go exactly when the method is kept.
        let kept = rewrite.becomes == rewrite.method
        #expect((next.body != nil) == kept)
        #expect((next.headers.first(name: "Content-Type") != nil) == kept)
    }

    @Test("Only the five redirect statuses are followed")
    func statuses() {
        #expect(SameOriginRedirects.redirectStatuses == [301, 302, 303, 307, 308])
        #expect(SameOriginRedirects.maximumRedirects == 5)
    }
}

/// What may be said about a URL in an error or a log line.
@Suite("HTTPOrigin — redaction")
struct HTTPOriginRedactionTests {

    /// A URL and what is left of it.
    struct Example: Sendable, CustomTestStringConvertible {
        let url: String
        let redacted: String
        var testDescription: String { redacted }
    }

    static let examples: [Example] = [
        Example(url: "https://mcp.example/messages?sessionId=abc123", redacted: "https://mcp.example/messages"),
        Example(url: "https://user:hunter2@mcp.example/mcp", redacted: "https://mcp.example/mcp"),
        Example(url: "https://mcp.example:8443/a/b?key=k#frag", redacted: "https://mcp.example:8443/a/b"),
        Example(url: "https://[::1]:8080/mcp?token=t", redacted: "https://[::1]:8080/mcp"),
        Example(url: "https://mcp.example", redacted: "https://mcp.example"),
        Example(url: "https://mcp.example/?only=query", redacted: "https://mcp.example/"),
    ]

    @Test("Userinfo, query and fragment are removed; origin and path stay", arguments: examples)
    func redacts(_ example: Example) throws {
        #expect(HTTPOrigin.redacted(try requireURL(example.url)) == example.redacted)
    }

    @Test("A relative URL is redacted as what it resolves to")
    func relative() throws {
        let base = try requireURL("https://mcp.example/sse")
        let endpoint = try #require(URL(string: "/messages?sessionId=abc123", relativeTo: base))
        #expect(HTTPOrigin.redacted(endpoint) == "https://mcp.example/messages")
    }

    @Test("An origin is named without path, query or userinfo")
    func origin() throws {
        let url = try requireURL("HTTPS://user:hunter2@MCP.Example:8443/private?sessionId=abc123")
        #expect(HTTPOrigin.description(of: url) == "https://mcp.example:8443")
        #expect(HTTPOrigin.description(of: try requireURL("file:///etc/passwd")) == HTTPOrigin.noOrigin)
    }
}
