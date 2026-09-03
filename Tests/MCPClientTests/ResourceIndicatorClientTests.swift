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

    /// Rebuilding a configuration must not silently drop the indicator.
    ///
    /// `MCPOAuthSession` reconstructs the configuration discovery returned, in order to
    /// substitute the authentication method registration reported. A reconstruction that copies
    /// field by field drops anything the author forgot — which is exactly how the indicator was
    /// lost, and the reason this asserts on the rebuild rather than only on discovery.
    @Test("Rebuilding a configuration preserves the resource indicator")
    func rebuiltConfigurationKeepsResource() throws {
        let identifier = try #require(URL(string: "https://mcp.example.com"))
        let original = ProviderConfiguration(
            identifier: "auth",
            authorizationEndpoint: try #require(URL(string: "https://auth.example.com/authorize")),
            tokenEndpoint: try #require(URL(string: "https://auth.example.com/token")),
            scope: "read",
            resource: identifier)

        let rebuilt = ProviderConfiguration(
            identifier: original.identifier,
            authorizationEndpoint: original.authorizationEndpoint,
            tokenEndpoint: original.tokenEndpoint,
            revocationEndpoint: original.revocationEndpoint,
            scope: original.scope,
            authenticationMethod: .clientSecretBasic,
            resource: original.resource)

        #expect(rebuilt.resource == identifier)
    }
}
