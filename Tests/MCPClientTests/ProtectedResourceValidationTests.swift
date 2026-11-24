import Foundation
import Testing
import SwiftOAuthCore
import SwiftOAuthClient
@testable import MCPClient

/// Which protected-resource document is used, and which error says why none was.
///
/// RFC 9728 §3.3: the `resource` a document returns MUST be identical to the resource
/// identifier its well-known URL was built from, or the document MUST NOT be used. Nothing
/// compared them. A document served for `https://mcp.example.com/mcp` that called itself
/// `https://other.example/api` was decoded and used — and its `resource` became the RFC 8707
/// indicator on the authorization request, so the token asked for was one the *other*
/// server accepts (§7.3).
@Suite("Protected resource metadata — the resource it names (RFC 9728 §3.3)")
struct ProtectedResourceValidationTests {

    // MARK: - The comparison

    struct Row: Sendable, CustomTestStringConvertible {
        let claimed: String
        let expected: String
        let same: Bool
        let why: String
        var testDescription: String { "\(claimed) vs \(expected) — \(why)" }
    }

    /// The same URL over plaintext. Written from the `https` form so that no test names a
    /// plaintext URL to a host that is not this machine.
    static func plaintext(_ secure: String) -> String {
        "http" + secure.dropFirst("https".count)
    }

    static let rows: [Row] = [
        Row(claimed: "https://mcp.example.com/mcp", expected: "https://mcp.example.com/mcp", same: true, why: "identical"),
        Row(claimed: "https://mcp.example.com/mcp/", expected: "https://mcp.example.com/mcp", same: true, why: "one trailing slash"),
        Row(claimed: "https://mcp.example.com/mcp", expected: "https://mcp.example.com/mcp/", same: true, why: "one trailing slash, the other way"),
        Row(claimed: "https://mcp.example.com/", expected: "https://mcp.example.com", same: true, why: "an empty path is the root (RFC 3986 §6.2.3)"),
        Row(claimed: "HTTPS://mcp.example.com/mcp", expected: "https://mcp.example.com/mcp", same: true, why: "scheme case (§6.2.2.1)"),
        Row(claimed: "https://MCP.Example.COM/mcp", expected: "https://mcp.example.com/mcp", same: true, why: "host case (§6.2.2.1)"),
        Row(claimed: "https://mcp.example.com:443/mcp", expected: "https://mcp.example.com/mcp", same: true, why: "default port (§6.2.3)"),
        Row(claimed: "http://127.0.0.1:80/mcp", expected: "http://127.0.0.1/mcp", same: true, why: "default port for http"),
        Row(claimed: "https://mcp.example.com/mcp?tenant=a", expected: "https://mcp.example.com/mcp?tenant=a", same: true, why: "the same query"),

        Row(claimed: "https://mcp.example.com/mcp//", expected: "https://mcp.example.com/mcp", same: false, why: "two trailing slashes"),
        Row(claimed: "https://mcp.example.com/MCP", expected: "https://mcp.example.com/mcp", same: false, why: "path case is significant"),
        Row(claimed: "https://mcp.example.com/mcp/v2", expected: "https://mcp.example.com/mcp", same: false, why: "a longer path"),
        Row(claimed: "https://mcp.example.com", expected: "https://mcp.example.com/mcp", same: false, why: "a shorter path"),
        Row(claimed: "https://mcp.example.com/other", expected: "https://mcp.example.com/mcp", same: false, why: "a sibling path"),
        Row(claimed: "https://mcp.example.com/%6Dcp", expected: "https://mcp.example.com/mcp", same: false, why: "percent-encoding is not normalised"),
        Row(claimed: "https://mcp.example.com/a/../mcp", expected: "https://mcp.example.com/mcp", same: false, why: "dot segments are not removed"),
        Row(claimed: plaintext("https://mcp.example.com/mcp"), expected: "https://mcp.example.com/mcp", same: false, why: "another scheme"),
        Row(claimed: "https://mcp.example.com:8443/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "another port"),
        Row(claimed: "https://mcp.example.com:80/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "80 is not the default for https"),
        Row(claimed: "https://other.example/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "another host"),
        Row(claimed: "https://mcp.example.com.evil.test/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "a host that only begins the same"),
        Row(claimed: "https://mcp.example.com/mcp?tenant=a", expected: "https://mcp.example.com/mcp", same: false, why: "a query"),
        Row(claimed: "https://mcp.example.com/mcp?", expected: "https://mcp.example.com/mcp", same: false, why: "an empty query (§6.2.3)"),
        Row(claimed: "https://mcp.example.com/mcp#frag", expected: "https://mcp.example.com/mcp", same: false, why: "a fragment"),
        Row(claimed: "https://user@mcp.example.com/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "userinfo"),
        Row(claimed: "mcp.example.com/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "no scheme"),
        Row(claimed: "", expected: "https://mcp.example.com/mcp", same: false, why: "empty"),
        Row(claimed: "/mcp", expected: "https://mcp.example.com/mcp", same: false, why: "a path alone"),
    ]

    @Test("Identical, after scheme and host case and a default port — and nothing looser", arguments: rows)
    func comparison(_ row: Row) {
        #expect(MCPOAuthSetup.isSameResource(row.claimed, row.expected) == row.same, "\(row.why)")
    }

    // MARK: - What each location may name

    @Test("The path location accepts the server's URL; the root accepts that or the origin")
    func identifiersPerLocation() throws {
        let server = try requireURL("https://user:pw@mcp.example.com/tenant/mcp/?key=secret#frag")
        let locations = MCPOAuthSetup.protectedResourceURLs(server: server)
        #expect(locations.count == 2)
        #expect(MCPOAuthSetup.resourceIdentifiers(server: server, fetchedFrom: locations[0])
                == ["https://mcp.example.com/tenant/mcp/"])
        #expect(MCPOAuthSetup.resourceIdentifiers(server: server, fetchedFrom: locations[1])
                == ["https://mcp.example.com/tenant/mcp/", "https://mcp.example.com"])

        let root = try requireURL("https://mcp.example.com")
        let only = MCPOAuthSetup.protectedResourceURLs(server: root)
        #expect(only.count == 1)
        #expect(MCPOAuthSetup.resourceIdentifiers(server: root, fetchedFrom: only[0]) == ["https://mcp.example.com"])
    }

    // MARK: - Through discovery, with a fetch of the caller's own

    /// A fetch that serves one protected-resource document per well-known path, and an
    /// authorization-server document for `issuer`.
    static func fetch(
        pathDocument: String?, rootDocument: String?,
        issuer: String = "https://auth.example.com", claimedIssuer: String? = nil,
        tokenEndpoint: String? = nil
    ) -> MCPOAuthSetup.Fetch {
        { requested in
            if requested.path == "/.well-known/oauth-protected-resource" {
                guard let rootDocument else { throw MCPOAuthSetup.notFound(at: requested, status: 404) }
                return Data(rootDocument.utf8)
            }
            if requested.path.hasPrefix("/.well-known/oauth-protected-resource/") {
                guard let pathDocument else { throw MCPOAuthSetup.notFound(at: requested, status: 404) }
                return Data(pathDocument.utf8)
            }
            return try JSONEncoder().encode(AuthorizationServerMetadata(
                issuer: claimedIssuer ?? issuer,
                authorizationEndpoint: "\(issuer)/authorize",
                tokenEndpoint: tokenEndpoint ?? "\(issuer)/token",
                registrationEndpoint: "\(issuer)/register",
                codeChallengeMethodsSupported: ["S256"]))
        }
    }

    static func document(resource: String) -> String {
        #"{"resource":"\#(resource)","authorization_servers":["https://auth.example.com"]}"#
    }

    static let server = "https://mcp.example.com/mcp"

    @Test("A document naming another resource is not used, whoever fetched it")
    func mismatchedDocumentRefused() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: "https://victim.example/api/0123456789abcdef0123456789abcdef"),
            rootDocument: nil))
        var caught: (any Error)?
        do {
            _ = try await setup.discover(server: try requireURL(Self.server), identifier: "mcp")
        } catch {
            caught = error
        }
        // Named by origin and redacted path: the path segment that could be a key is not repeated.
        #expect(caught as? MCPOAuthError == .resourceMismatch(
            expected: "https://mcp.example.com/mcp", found: "https://victim.example/api/-redacted-"))
    }

    @Test("A document naming this server is used, and its resource becomes the indicator")
    func matchingDocumentUsed() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: "https://MCP.example.com:443/mcp/"), rootDocument: nil))
        let discovered = try await setup.discover(server: try requireURL(Self.server), identifier: "mcp")
        #expect(discovered.configuration.resource?.absoluteString == "https://MCP.example.com:443/mcp/")
    }

    @Test("At the root, a document may name the server's URL or its origin — not a sibling",
          arguments: [
            ["https://mcp.example.com/mcp", "used"],
            ["https://mcp.example.com", "used"],
            ["https://mcp.example.com/other", "refused"],
            ["https://mcp.example.com/mcp/sub", "refused"],
          ])
    func rootLocation(_ row: [String]) async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(pathDocument: nil, rootDocument: Self.document(resource: row[0])))
        var caught: (any Error)?
        var used: ProtectedResourceMetadata?
        do {
            used = try await setup.protectedResourceMetadata(server: try requireURL(Self.server))
        } catch {
            caught = error
        }
        if row[1] == "used" {
            #expect(used?.resource == row[0], "\(String(describing: caught))")
        } else {
            guard case .resourceMismatch = caught as? MCPOAuthError else {
                Issue.record("expected resourceMismatch for \(row[0]), got \(String(describing: caught))")
                return
            }
        }
    }

    @Test("A mismatch at the first location does not stop a good document at the second being used")
    func mismatchThenGood() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: "https://victim.example/api"),
            rootDocument: Self.document(resource: "https://mcp.example.com/mcp")))
        let metadata = try await setup.protectedResourceMetadata(server: try requireURL(Self.server))
        #expect(metadata.resource == "https://mcp.example.com/mcp")
    }

    // MARK: - Which error survives

    @Test("A mismatch is the error reported, not the next location's 404")
    func mismatchOutranksNotFound() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: "https://victim.example/api"), rootDocument: nil))
        var caught: (any Error)?
        do {
            _ = try await setup.protectedResourceMetadata(server: try requireURL(Self.server))
        } catch {
            caught = error
        }
        #expect(caught as? MCPOAuthError == .resourceMismatch(
            expected: "https://mcp.example.com/mcp", found: "https://victim.example/api"))
    }

    @Test("A refused redirect is the error reported, not the next location's 404")
    func refusalOutranksNotFound() async throws {
        let refusal = MCPError.redirectRejected(destination: "https://elsewhere.example", reason: "fixture")
        let setup = MCPOAuthSetup { requested in
            if requested.path.hasPrefix("/.well-known/oauth-protected-resource/") { throw refusal }
            throw MCPOAuthSetup.notFound(at: requested, status: 404)
        }
        var caught: (any Error)?
        do {
            _ = try await setup.protectedResourceMetadata(server: try requireURL(Self.server))
        } catch {
            caught = error
        }
        #expect(caught as? MCPError == refusal, "got \(String(describing: caught))")
    }

    @Test("A refused redirect at the first location does not stop a good document at the second being used")
    func refusalThenGood() async throws {
        let log = FetchLog()
        let setup = MCPOAuthSetup { requested in
            await log.record(requested)
            if requested.path.hasPrefix("/.well-known/oauth-protected-resource/") {
                throw MCPError.redirectRejected(destination: "https://elsewhere.example", reason: "fixture")
            }
            return Data(Self.document(resource: "https://mcp.example.com/mcp").utf8)
        }
        let metadata = try await setup.protectedResourceMetadata(server: try requireURL(Self.server))
        #expect(metadata.resource == "https://mcp.example.com/mcp")
        #expect(await log.paths == ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"])
    }

    @Test("With no refusal, the last location's failure is still the one reported")
    func lastErrorWithoutRefusal() async throws {
        let setup = MCPOAuthSetup { requested in
            throw MCPOAuthSetup.notFound(
                at: requested, status: requested.path.hasSuffix("/mcp") ? 500 : 404)
        }
        var caught: (any Error)?
        do {
            _ = try await setup.protectedResourceMetadata(server: try requireURL(Self.server))
        } catch {
            caught = error
        }
        guard case .metadataNotFound(_, let status) = caught as? MCPOAuthError else {
            Issue.record("expected metadataNotFound, got \(String(describing: caught))")
            return
        }
        #expect(status == 404)
    }

    // MARK: - The other checks a caller's own fetch cannot skip

    @Test("A caller's fetch returning another issuer's metadata is refused")
    func customFetchIssuerMismatch() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: Self.server), rootDocument: nil,
            claimedIssuer: "https://attacker.example"))
        var caught: (any Error)?
        do {
            _ = try await setup.discover(server: try requireURL(Self.server), identifier: "mcp")
        } catch {
            caught = error
        }
        #expect(caught as? MCPOAuthError == .issuerMismatch(
            expected: "https://auth.example.com", found: "https://attacker.example"))
    }

    @Test("A caller's fetch returning a plaintext token endpoint is refused")
    func customFetchInsecureEndpoint() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: Self.server), rootDocument: nil,
            tokenEndpoint: Self.plaintext("https://auth.example.com/token")))
        var caught: (any Error)?
        do {
            _ = try await setup.discover(server: try requireURL(Self.server), identifier: "mcp")
        } catch {
            caught = error
        }
        #expect(caught as? MCPOAuthError == .discovery(.insecureEndpoint(Self.plaintext("https://auth.example.com/token"))))
    }

    @Test("A caller's fetch returning a token endpoint on another origin is refused")
    func customFetchForeignEndpoint() async throws {
        let setup = MCPOAuthSetup(fetch: Self.fetch(
            pathDocument: Self.document(resource: Self.server), rootDocument: nil,
            tokenEndpoint: "https://attacker.example/token"))
        var caught: (any Error)?
        do {
            _ = try await setup.discover(server: try requireURL(Self.server), identifier: "mcp")
        } catch {
            caught = error
        }
        #expect(caught as? MCPOAuthError == .discovery(.endpointOutsideIssuer("https://attacker.example/token")))
    }
}

/// Records what a fetch was asked for.
actor FetchLog {
    private(set) var paths: [String] = []
    func record(_ url: URL) { paths.append(url.path) }
}
