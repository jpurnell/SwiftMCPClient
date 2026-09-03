import Foundation
import Testing
import SwiftOAuthClient
@testable import MCPClient

/// Sending RFC 8707's `resource` — the client-side half of a strict authorization server.
///
/// A server with the strict policy that swift-oauth 0.8.0 introduced refuses any request naming
/// no resource. This client discovers the identifier to send — it is the `resource` field of the
/// protected-resource metadata that discovery already fetches — and until now dropped it on the
/// floor, sending nothing and being refused for it.
///
/// The defect had the shape every one in this feature has had: two halves, each correct alone.
/// Discovery fetched the value; the configuration had a field for it; nothing joined them.
@Suite("RFC 8707 — the client sends a resource indicator")
struct ResourceIndicatorClientTests {

    /// The identifier the server published is the one the configuration carries.
    @Test("A discovered resource identifier reaches the provider configuration")
    func discoveredResourceIsCarried() throws {
        // SECURITY: literals written in this test; nothing is fetched from them.
        let identifier = try #require(URL(string: "https://mcp.example.com"))
        let metadata = AuthorizationServerMetadata(
            issuer: "https://auth.example.com",
            authorizationEndpoint: "https://auth.example.com/authorize",
            tokenEndpoint: "https://auth.example.com/token",
            codeChallengeMethodsSupported: ["S256"])

        let configuration = try metadata.configuration(
            identifier: "auth", scope: "read", resource: identifier)

        #expect(configuration.resource == identifier,
                "a client that discovers an identifier and sends nothing is refused by a strict server")
    }

    /// The real discovery path, end to end.
    ///
    /// The first version of this test built two `ProviderConfiguration`s by hand and compared
    /// them, which exercised the initialiser and not the code under test — a mutation setting
    /// `resource: nil` at the actual call site compiled and left it passing. It was a test of
    /// the wrong thing that read like a test of the right one.
    ///
    /// This drives `MCPOAuthSetup.discover` against stubbed metadata, so the assertion covers
    /// the path a real client takes.
    @Test("Discovery produces a configuration carrying the server's resource identifier")
    func discoveryCarriesResourceEndToEnd() async throws {
        let setup = MCPOAuthSetup(fetch: { requested in
            if requested.absoluteString.contains("oauth-protected-resource") {
                return Data("""
                {"resource":"https://mcp.example.com/mcp",
                 "authorization_servers":["https://auth.example.com"],
                 "scopes_supported":["read"]}
                """.utf8)
            }
            return Data("""
            {"issuer":"https://auth.example.com",
             "authorization_endpoint":"https://auth.example.com/authorize",
             "token_endpoint":"https://auth.example.com/token",
             "code_challenge_methods_supported":["S256"]}
            """.utf8)
        })

        let (configuration, _) = try await setup.discover(
            server: try #require(URL(string: "https://mcp.example.com/mcp")),
            identifier: "fallback")

        #expect(configuration.resource?.absoluteString == "https://mcp.example.com/mcp",
                "the identifier the resource published about itself must reach the request")
    }
}
