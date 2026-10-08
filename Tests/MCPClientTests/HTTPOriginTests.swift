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
/// A request is either repeated exactly as it was sent, or the redirect is not followed.
/// `AsyncHTTPClient` — and the Fetch standard — would turn a `POST` answered `301`, `302` or
/// `303` into a `GET` with no body; here that is a refusal, because the body is the message.
@Suite("SameOriginRedirects — the request a redirect asks for")
struct RedirectedRequestTests {

    /// One status and method, and whether the redirect can carry the request.
    struct Rewrite: Sendable, CustomTestStringConvertible {
        let status: UInt
        let method: HTTPMethod
        let carried: Bool
        var testDescription: String { "\(status) \(method.rawValue) → \(carried ? "repeated" : "refused")" }
    }

    static let rewrites: [Rewrite] = [
        Rewrite(status: 301, method: .POST, carried: false),
        Rewrite(status: 302, method: .POST, carried: false),
        Rewrite(status: 303, method: .POST, carried: false),
        Rewrite(status: 307, method: .POST, carried: true),
        Rewrite(status: 308, method: .POST, carried: true),
        Rewrite(status: 301, method: .DELETE, carried: true),
        Rewrite(status: 302, method: .DELETE, carried: true),
        Rewrite(status: 303, method: .DELETE, carried: false),
        Rewrite(status: 307, method: .DELETE, carried: true),
        Rewrite(status: 308, method: .DELETE, carried: true),
        Rewrite(status: 303, method: .HEAD, carried: true),
        Rewrite(status: 301, method: .GET, carried: true),
        Rewrite(status: 302, method: .GET, carried: true),
        Rewrite(status: 303, method: .GET, carried: true),
        Rewrite(status: 307, method: .GET, carried: true),
        Rewrite(status: 308, method: .GET, carried: true),
    ]

    @Test("A request is repeated as it was sent, or not at all", arguments: rewrites)
    func method(_ rewrite: Rewrite) throws {
        var request = HTTPClientRequest(url: "https://good.example/mcp")
        request.method = rewrite.method
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: Watched.keyHeader, value: Watched.key)
        request.body = .bytes(Watched.body)

        let next = SameOriginRedirects.redirected(
            request, to: try requireURL("https://good.example/moved"), status: rewrite.status)

        guard rewrite.carried else {
            #expect(next == nil, "a \(rewrite.status) rewrote a \(rewrite.method.rawValue) instead of refusing it")
            return
        }
        let repeated = try #require(next, "a \(rewrite.status) refused a \(rewrite.method.rawValue)")
        #expect(repeated.method == rewrite.method)
        #expect(repeated.url == "https://good.example/moved")
        // Same origin: the caller's headers go with it, and so does the body.
        #expect(repeated.headers.first(name: Watched.keyHeader) == Watched.key)
        #expect(repeated.headers.first(name: "Content-Type") == "application/json")
        // That the body's bytes arrive is asserted on the wire, in
        // `SameOriginRedirectWireTests`: a request body cannot be read back out of the
        // request here.
    }

    @Test("The reason for a refused POST names the statuses that would have carried it")
    func droppingReason() {
        let reason = SameOriginRedirects.droppingReason(status: 302, method: .POST, on: "https://good.example")
        #expect(reason.contains("HTTP 302"))
        #expect(reason.contains("POST"))
        #expect(reason.contains("307 and 308"))
        #expect(reason.contains("https://good.example"))
    }

    /// `http` → `https` on the same host is the one cross-origin redirect whose cause is
    /// known: the caller configured a plaintext URL. Loopback cannot stand in for default
    /// ports, so the decision is checked here.
    @Test("An upgrade to https on the same host is told apart, whatever the ports",
          arguments: [
            Upgrade(configured: "mcp.example", destination: "mcp.example", expected: true),
            Upgrade(configured: "MCP.example", destination: "mcp.example", expected: true),
            Upgrade(configured: "mcp.example:8080", destination: "mcp.example:8443", expected: true),
            Upgrade(configured: "mcp.example", destination: "other.example", expected: false),
            Upgrade(configured: "mcp.example", destination: "mcp.example.evil.test", expected: false),
            Upgrade(configured: "mcp.example", destination: "mcp.example", expected: false, from: "https", to: "http"),
            Upgrade(configured: "mcp.example", destination: "mcp.example:8443", expected: false, from: "https"),
            Upgrade(configured: "mcp.example", destination: "mcp.example:8080", expected: false, to: "http"),
          ])
    func upgrade(_ example: Upgrade) throws {
        let url = try requireURL("\(example.from)://\(example.configured)/mcp")
        let origin = "\(example.to)://\(example.destination)"
        #expect(HTTPOrigin.isUpgrade(from: url, toOrigin: origin) == example.expected)

        let reason = SameOriginRedirects.leavingReason(status: 301, from: url, to: origin)
        #expect(reason.contains("already been sent in the clear") == example.expected)
        #expect(reason.contains("Configure the transport with \(origin)") == example.expected)
        if !example.expected {
            #expect(reason.contains("leaves the configured origin"))
        }
    }

    /// A configured authority, a destination authority, and whether going from one to the
    /// other is the plaintext-to-TLS upgrade. The schemes are kept apart from the
    /// authorities so that no plaintext URL is written out as a literal.
    struct Upgrade: Sendable, CustomTestStringConvertible {
        let configured: String
        let destination: String
        let expected: Bool
        var from = "http"
        var to = "https"
        var testDescription: String { "\(from) \(configured) → \(to) \(destination)" }
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
        Example(url: "https://mcp.example/mcp/", redacted: "https://mcp.example/mcp/"),
        Example(url: "https://[::1]:8080/mcp?token=t", redacted: "https://[::1]:8080/mcp"),
        Example(url: "https://mcp.example", redacted: "https://mcp.example"),
        Example(url: "https://mcp.example/?only=query", redacted: "https://mcp.example/"),
    ]

    @Test("Userinfo, query and fragment are removed; origin and an ordinary path stay", arguments: examples)
    func redacts(_ example: Example) throws {
        #expect(HTTPOrigin.redacted(try requireURL(example.url)) == example.redacted)
    }

    /// A deployment that puts its key in the path — `/mcp/<key>/sse` — had it in every error
    /// and log line that named the URL, because the path was kept whole.
    static let keyedPaths: [Example] = [
        Example(url: "https://mcp.example/mcp/9f8e7d6c5b4a39281706f5e4d3c2b1a0/sse",
                redacted: "https://mcp.example/mcp/-redacted-/sse"),
        Example(url: "https://mcp.example/mcp/550e8400-e29b-41d4-a716-446655440000/messages?sessionId=abc",
                redacted: "https://mcp.example/mcp/-redacted-/messages"),
        Example(url: "https://mcp.example/v1/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl/mcp",
                redacted: "https://mcp.example/v1/-redacted-/mcp"),
        Example(url: "https://mcp.example/sk-live-abc123def456/mcp",
                redacted: "https://mcp.example/-redacted-/mcp"),
        Example(url: "https://mcp.example/mcp/a%2Fb%3Dc",
                redacted: "https://mcp.example/mcp/-redacted-"),
        Example(url: "https://user:hunter2@mcp.example:8443/t/AbCdEfGhIjKlMnOp/sse/",
                redacted: "https://mcp.example:8443/t/-redacted-/sse/"),
        Example(url: "https://mcp.example/.well-known/oauth-protected-resource/mcp/9f8e7d6c5b4a39281706f5e4d3c2b1a0",
                redacted: "https://mcp.example/.well-known/oauth-protected-resource/mcp/-redacted-"),
        Example(url: "https://mcp.example/.well-known/oauth-authorization-server/tenant-acme",
                redacted: "https://mcp.example/.well-known/oauth-authorization-server/tenant-acme"),
        Example(url: "https://mcp.example/api/v2/mcp/2025-06-18/messages",
                redacted: "https://mcp.example/api/v2/mcp/2025-06-18/messages"),
    ]

    @Test("A path segment that could be a credential is replaced; ordinary segments stay", arguments: keyedPaths)
    func redactsKeyedPaths(_ example: Example) throws {
        #expect(HTTPOrigin.redacted(try requireURL(example.url)) == example.redacted)
        #expect(HTTPOrigin.redactedURL(try requireURL(example.url))?.absoluteString == example.redacted)
    }

    /// One path segment and whether it is kept.
    struct Segment: Sendable, CustomTestStringConvertible {
        let text: String
        let kept: Bool
        let why: String
        var testDescription: String { "\(text.isEmpty ? "(empty)" : text) — \(why)" }
    }

    /// The heuristic, case by case. It errs towards redaction: a segment is kept only if it
    /// is made of short words and small numbers, and everything else goes.
    static let segments: [Segment] = [
        // Kept: what paths are ordinarily made of.
        Segment(text: "", kept: true, why: "an empty segment is a slash"),
        Segment(text: "mcp", kept: true, why: "a word"),
        Segment(text: "sse", kept: true, why: "a word"),
        Segment(text: "messages", kept: true, why: "a word"),
        Segment(text: "v1", kept: true, why: "a word with a version digit"),
        Segment(text: "oauth2", kept: true, why: "a word with a version digit"),
        Segment(text: "api", kept: true, why: "a word"),
        Segment(text: "42", kept: true, why: "a small number"),
        Segment(text: "2025-06-18", kept: true, why: "small numbers: a protocol revision"),
        Segment(text: ".well-known", kept: true, why: "words joined by punctuation"),
        Segment(text: "oauth-protected-resource", kept: true, why: "words joined by hyphens"),
        Segment(text: "oauth-authorization-server", kept: true, why: "words joined by hyphens"),
        Segment(text: "tenant_acme", kept: true, why: "words joined by an underscore"),
        Segment(text: "getToolsList", kept: true, why: "a camel-cased word"),
        Segment(text: "MCP", kept: true, why: "an acronym"),
        Segment(text: "index.html", kept: true, why: "a file name"),
        // Redacted: anything that could be a key.
        Segment(text: "550e8400-e29b-41d4-a716-446655440000", kept: false, why: "a UUID"),
        Segment(text: "550E8400-E29B-41D4-A716-446655440000", kept: false, why: "a UUID in capitals"),
        Segment(text: "9f8e7d6c5b4a39281706f5e4d3c2b1a0", kept: false, why: "32 hex digits"),
        Segment(text: "deadbeefdeadbeefdead", kept: false, why: "hex that happens to be letters"),
        Segment(text: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", kept: false, why: "JWT-shaped"),
        Segment(text: "sk-live-abc123def456", kept: false, why: "a prefixed key"),
        Segment(text: "a1b2c3", kept: false, why: "letters and digits interleaved"),
        Segment(text: "x7Kq", kept: false, why: "a digit inside a word"),
        Segment(text: "12345678", kept: false, why: "a number too long to be a version or a year"),
        Segment(text: "AbCdEfGhIjKlMnOp", kept: false, why: "letters with scrambled case"),
        Segment(text: "xKqPzLmNwRtYvBnM", kept: false, why: "letters with scrambled case"),
        Segment(text: "abcdefghijklmnopqrstuvwxyz", kept: false, why: "one run of letters too long to be a word"),
        Segment(text: "dGhpcyBpcyBhIGtleQ==", kept: false, why: "base64 with padding"),
        Segment(text: "a/b=c", kept: false, why: "characters a plain segment does not use"),
        Segment(text: "user@example.com", kept: false, why: "characters a plain segment does not use"),
        Segment(text: "key:value", kept: false, why: "characters a plain segment does not use"),
        Segment(text: "one-two-three-four-five-six-seven-eight", kept: false, why: "longer than any ordinary segment"),
        Segment(text: "clé", kept: false, why: "outside ASCII"),
    ]

    @Test("The credential heuristic, case by case", arguments: segments)
    func heuristic(_ segment: Segment) {
        #expect(HTTPOrigin.couldBeCredential(segment.text) == !segment.kept, "\(segment.text): \(segment.why)")
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
