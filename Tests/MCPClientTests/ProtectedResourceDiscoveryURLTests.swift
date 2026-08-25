import Foundation
import Testing
@testable import MCPClient

/// Where a client looks for RFC 9728 protected-resource metadata.
///
/// The rule is easy to get subtly wrong: the well-known segment goes *between* the host and
/// the server's path, not on the end of it. Appending instead of inserting produces a URL
/// that 404s against every server whose MCP endpoint is not at an origin root — which is
/// most of them, and which is why these vectors are measured against a live server rather
/// than reasoned about.
@Suite("Protected resource discovery URLs")
struct ProtectedResourceDiscoveryURLTests {

    // MARK: - Golden path (RFC 9728 §3.1)

    /// The Apollo case, measured 2026-08-21. Both candidates return HTTP 200 live; the
    /// path-suffixed form is tried first because it is the one the RFC specifies.
    @Test("A server with a path yields the RFC form first, then the origin root")
    func serverWithPath() throws {
        let candidates = MCPOAuthSetup.protectedResourceURLs(server: try #require(URL(string: "https://mcp.apollo.io/mcp")))

        #expect(candidates.map(\.absoluteString) == [
            "https://mcp.apollo.io/.well-known/oauth-protected-resource/mcp",
            "https://mcp.apollo.io/.well-known/oauth-protected-resource"
        ])
    }

    /// With no path there is only one place the metadata can be, and offering the same URL
    /// twice would mean a second pointless round trip on every failure.
    @Test("A server at the origin root yields exactly one candidate")
    func serverAtOriginRoot() throws {
        let candidates = MCPOAuthSetup.protectedResourceURLs(server: try #require(URL(string: "https://mcp.example.com")))

        #expect(candidates.map(\.absoluteString) == [
            "https://mcp.example.com/.well-known/oauth-protected-resource"
        ])
    }

    @Test("A multi-segment path is preserved in order")
    func multiSegmentPath() throws {
        let candidates = MCPOAuthSetup.protectedResourceURLs(server: try #require(URL(string: "https://h.example.com/a/b")))

        #expect(candidates.map(\.absoluteString) == [
            "https://h.example.com/.well-known/oauth-protected-resource/a/b",
            "https://h.example.com/.well-known/oauth-protected-resource"
        ])
    }

    // MARK: - Edge cases

    /// A user pasting a URL out of a browser brings the trailing slash with them. It must not
    /// become an empty path segment — `…/resource/mcp/` is a different URL and 404s.
    @Test("A trailing slash does not produce an empty path segment")
    func trailingSlashIsNormalised() throws {
        let candidates = MCPOAuthSetup.protectedResourceURLs(server: try #require(URL(string: "https://h.example.com/mcp/")))

        #expect(candidates.map(\.absoluteString) == [
            "https://h.example.com/.well-known/oauth-protected-resource/mcp",
            "https://h.example.com/.well-known/oauth-protected-resource"
        ])
    }

    @Test("A bare root path behaves like no path at all")
    func bareRootPath() throws {
        let candidates = MCPOAuthSetup.protectedResourceURLs(server: try #require(URL(string: "https://h.example.com/")))

        #expect(candidates.map(\.absoluteString) == [
            "https://h.example.com/.well-known/oauth-protected-resource"
        ])
    }

    // MARK: - Fallback behaviour

    /// The candidates are an ordered attempt list, not a guess. A server that publishes only
    /// at the origin root must still resolve.
    @Test("Discovery falls back to the origin root when the RFC form is absent")
    func fallsBackToOriginRoot() async throws {
        let attempted = AttemptRecorder()
        let setup = MCPOAuthSetup(fetch: { requested in
            await attempted.record(requested)
            guard requested.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource" else {
                throw MCPOAuthError.metadataNotFound(url: requested, status: 404)
            }
            return Self.metadataJSON
        })

        let metadata = try await setup.protectedResourceMetadata(server: try #require(URL(string: "https://mcp.example.com/mcp")))

        #expect(metadata.resource == "https://mcp.example.com/mcp")
        #expect(await attempted.urls.map(\.absoluteString) == [
            "https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
            "https://mcp.example.com/.well-known/oauth-protected-resource"
        ])
    }

    /// The first candidate that answers wins, and nothing further is requested — a fallback
    /// that always runs is not a fallback, it is a second request.
    @Test("A successful first candidate stops the search")
    func firstCandidateWins() async throws {
        let attempted = AttemptRecorder()
        let setup = MCPOAuthSetup(fetch: { requested in
            await attempted.record(requested)
            return Self.metadataJSON
        })

        _ = try await setup.protectedResourceMetadata(server: try #require(URL(string: "https://mcp.example.com/mcp")))

        #expect(await attempted.urls.count == 1)
    }

    /// When every candidate fails the caller needs to know *where* we looked. Surfacing the
    /// last failure loses that; surfacing a not-found for the exhausted list keeps it.
    @Test("Exhausting every candidate throws, not decodes")
    func exhaustedCandidatesThrow() async throws {
        let setup = MCPOAuthSetup(fetch: { requested in
            throw MCPOAuthError.metadataNotFound(url: requested, status: 404)
        })

        await #expect(throws: MCPOAuthError.self) {
            _ = try await setup.protectedResourceMetadata(server: try #require(URL(string: "https://mcp.example.com/mcp")))
        }
    }

    // MARK: - Status validation

    /// The bug this replaces: a 404 body was handed to `JSONDecoder`, so "there is nothing
    /// at that URL" arrived as "the JSON was malformed". The diagnostic is half the defect.
    @Test("A non-2xx response throws a named error rather than a decoding error")
    func nonSuccessStatusThrows() throws {
        let requested = try #require(URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        let response = try #require(HTTPURLResponse(
            url: requested, statusCode: 404, httpVersion: nil, headerFields: nil))

        #expect(throws: MCPOAuthError.metadataNotFound(url: requested, status: 404)) {
            _ = try MCPOAuthSetup.validate(data: Data("not json".utf8), response: response, url: requested)
        }
    }

    @Test("A 500 reports its own status, not a generic failure")
    func serverErrorReportsStatus() throws {
        let requested = try #require(URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        let response = try #require(HTTPURLResponse(
            url: requested, statusCode: 500, httpVersion: nil, headerFields: nil))

        #expect(throws: MCPOAuthError.metadataNotFound(url: requested, status: 500)) {
            _ = try MCPOAuthSetup.validate(data: Data(), response: response, url: requested)
        }
    }

    @Test("A 200 passes the body through unchanged")
    func successPassesBodyThrough() throws {
        let requested = try #require(URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        let response = try #require(HTTPURLResponse(
            url: requested, statusCode: 200, httpVersion: nil, headerFields: nil))

        let result = try MCPOAuthSetup.validate(data: Self.metadataJSON, response: response, url: requested)
        #expect(result == Self.metadataJSON)
    }

    /// A non-HTTP response carries no status to judge. Refusing the body here would break
    /// `file://` and any injected fetch that does not synthesise a response.
    @Test("A response with no status is not judged")
    func nonHTTPResponseIsAccepted() throws {
        let requested = try #require(URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource"))
        let result = try MCPOAuthSetup.validate(data: Self.metadataJSON, response: nil, url: requested)
        #expect(result == Self.metadataJSON)
    }

    // MARK: - Fixtures

    private static let metadataJSON = Data("""
    {
      "resource": "https://mcp.example.com/mcp",
      "authorization_servers": ["https://auth.example.com"],
      "scopes_supported": ["mcp:tools"]
    }
    """.utf8)
}

/// Records which URLs a fetch was asked for, in order.
private actor AttemptRecorder {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}
