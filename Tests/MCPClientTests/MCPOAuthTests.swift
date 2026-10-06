import Foundation
import Testing
import SwiftOAuthCore
import SwiftOAuthClient
@testable import MCPClient

/// Discovering how to authenticate against a server the client was never configured for.
///
/// The network is injected, so the whole sequence runs without one — which is the point:
/// against a live server these steps are three round trips that are awkward to provoke into
/// their failure modes, and the failure modes are what matter.
@Suite("MCP OAuth — discovery")
struct MCPOAuthDiscoveryTests {

    /// The ordinary sequence: the MCP server names an authorization server, that server
    /// describes itself, and the result is usable.
    @Test("A server's metadata resolves to a configuration")
    func discoversConfiguration() async throws {
        let setup = MCPOAuthSetup(fetch: stubFetch())
        let (configuration, registration) = try await setup.discover(
            server: url("https://mcp.example.com"), identifier: "mcp")

        #expect(configuration.tokenEndpoint.absoluteString == "https://auth.example.com/token")
        #expect(configuration.authorizationEndpoint.absoluteString
                == "https://auth.example.com/authorize")
        #expect(registration?.absoluteString == "https://auth.example.com/register")

        // The resource's scopes win over the authorization server's — the resource is what
        // the client is actually trying to reach.
        #expect(configuration.scope == "mcp:tools mcp:resources")
    }

    /// The MCP server and its authorization server need not be the same host. A client that
    /// assumes they are works only where they happen to coincide.
    @Test("The authorization server may be a different host")
    func authorizationServerMayDiffer() async throws {
        let setup = MCPOAuthSetup(fetch: stubFetch())
        let (configuration, _) = try await setup.discover(
            server: url("https://mcp.example.com"), identifier: "mcp")
        #expect(configuration.tokenEndpoint.host() == "auth.example.com")
    }

    /// A server advertising no authorization server is saying it does not use OAuth. The
    /// client must not invent an endpoint and try it.
    @Test("No advertised authorization server is refused")
    func noAuthorizationServerRefused() async {
        let setup = MCPOAuthSetup(fetch: stubFetch(authorizationServers: []))

        await #expect(throws: MCPOAuthError.noAuthorizationServer) {
            try await setup.discover(server: url("https://mcp.example.com"), identifier: "mcp")
        }
    }

    /// The origin binding still applies through this path. An MCP server that names an
    /// authorization server whose own metadata points its token endpoint elsewhere must not
    /// get the client to post credentials there.
    @Test("An authorization server pointing its endpoints elsewhere is refused")
    func endpointsOutsideIssuerRefused() async {
        let setup = MCPOAuthSetup(
            fetch: stubFetch(tokenEndpoint: "https://attacker.example/token"))

        await #expect(
            throws: MCPOAuthError.discovery(
                .endpointOutsideIssuer("https://attacker.example/token"))
        ) {
            try await setup.discover(server: url("https://mcp.example.com"), identifier: "mcp")
        }
    }

    /// A server that cannot do S256 cannot have its flow protected by PKCE, and an MCP
    /// client must not proceed without it.
    @Test("An authorization server without S256 is refused")
    func pkceUnsupportedRefused() async {
        let setup = MCPOAuthSetup(fetch: stubFetch(challengeMethods: nil))

        await #expect(throws: MCPOAuthError.discovery(.pkceUnsupported)) {
            try await setup.discover(server: url("https://mcp.example.com"), identifier: "mcp")
        }
    }

    /// The well-known path is inserted before the issuer's path, not appended — on a
    /// multi-tenant authorization server, appending silently finds nothing.
    @Test("A tenant-scoped issuer is discovered at the right path")
    func tenantScopedIssuer() async throws {
        let requested = RequestLog()
        let setup = MCPOAuthSetup(fetch: stubFetch(
            issuer: "https://auth.example.com/tenant-a",
            log: requested))

        _ = try? await setup.discover(server: url("https://mcp.example.com"), identifier: "mcp")

        let urls = await requested.urls
        #expect(urls.contains {
            $0.absoluteString
                == "https://auth.example.com/.well-known/oauth-authorization-server/tenant-a"
        }, "requested: \(urls.map(\.absoluteString))")
    }
}

@Suite("MCP OAuth — protected resource metadata")
struct ProtectedResourceMetadataTests {

    /// RFC 9728 permits several authorization servers and gives no ordering rule. Trying
    /// each in turn would leak an authorization attempt to every one tried, so the first is
    /// chosen and the choice is deterministic.
    @Test("The first advertised authorization server is chosen")
    func firstServerChosen() {
        let metadata = ProtectedResourceMetadata(
            resource: "https://mcp.example.com",
            authorizationServers: ["https://first.example.com", "https://second.example.com"])
        #expect(metadata.primaryAuthorizationServer == "https://first.example.com")
    }

    /// An empty list is not a server.
    @Test("An empty list yields no server")
    func emptyListYieldsNil() {
        let metadata = ProtectedResourceMetadata(
            resource: "https://mcp.example.com", authorizationServers: [])
        #expect(metadata.primaryAuthorizationServer == nil)
    }

    /// The wire names are snake_case, and a mismatch here means discovery fails against
    /// every real server while every test that builds the type by hand still passes.
    @Test("The wire format matches RFC 9728")
    func wireFormatMatches() throws {
        let json = """
        {
          "resource": "https://mcp.example.com",
          "authorization_servers": ["https://auth.example.com"],
          "scopes_supported": ["mcp:tools"]
        }
        """
        let decoded = try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: Data(json.utf8))

        #expect(decoded.resource == "https://mcp.example.com")
        #expect(decoded.authorizationServers == ["https://auth.example.com"])
        #expect(decoded.scopesSupported == ["mcp:tools"])
    }
}

// MARK: - Helpers

private func url(_ string: String) -> URL {
    URL(string: string) ?? URL(fileURLWithPath: "/")
}

/// Records what was fetched, so a test can assert on the path rather than the result.
private actor RequestLog {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

/// A network that answers from canned documents.
private func stubFetch(
    issuer: String = "https://auth.example.com",
    authorizationServers: [String]? = nil,
    tokenEndpoint: String? = nil,
    challengeMethods: [String]? = ["S256"],
    log: RequestLog? = nil
) -> MCPOAuthSetup.Fetch {
    let servers = authorizationServers ?? [issuer]
    // Derived from the issuer so the origin binding is satisfied by default, and a test that
    // wants to break it says so explicitly.
    let token = tokenEndpoint ?? "\(issuer)/token"

    return { requested in
        await log?.record(requested)

        if requested.path.contains("oauth-protected-resource") {
            let metadata = ProtectedResourceMetadata(
                resource: "https://mcp.example.com",
                authorizationServers: servers,
                scopesSupported: ["mcp:tools", "mcp:resources"])
            return try JSONEncoder().encode(metadata)
        }

        if requested.path.contains("oauth-authorization-server") {
            let metadata = AuthorizationServerMetadata(
                issuer: issuer,
                authorizationEndpoint: "\(issuer)/authorize",
                tokenEndpoint: token,
                registrationEndpoint: "\(issuer)/register",
                codeChallengeMethodsSupported: challengeMethods,
                scopesSupported: ["mcp:tools"])
            return try JSONEncoder().encode(metadata)
        }

        throw MCPOAuthError.noAuthorizationServer
    }
}
