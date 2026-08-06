import Foundation
import SwiftOAuthCore
import SwiftOAuthClient

/// Why an MCP server's OAuth could not be set up.
public enum MCPOAuthError: Error, Equatable, Sendable {

    /// The server does not advertise an authorization server.
    ///
    /// Not a failure to reach one — a server that returns no protected-resource metadata is
    /// telling the client it does not use OAuth, and the client should not invent an
    /// endpoint to try.
    case noAuthorizationServer

    /// The server offers no registration endpoint.
    ///
    /// Fatal for a client like this one. A user points it at a server nobody anticipated, so
    /// there are no credentials to fall back on: without registration there is no way to
    /// obtain any.
    case registrationUnavailable

    /// The server's advertised authorization server could not be used.
    case discovery(DiscoveryError)
}

/// RFC 9728 protected resource metadata — how an MCP server names its authorization server.
///
/// The indirection matters: the MCP server and the thing that issues its tokens need not be
/// the same host, and a client that assumes they are works only for the case where they
/// happen to coincide.
public struct ProtectedResourceMetadata: Codable, Sendable, Equatable {

    /// The resource's own identifier.
    public let resource: String

    /// The authorization servers that protect it.
    public let authorizationServers: [String]

    /// The scopes the resource recognises.
    public let scopesSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }

    /// Creates protected resource metadata.
    public init(
        resource: String,
        authorizationServers: [String],
        scopesSupported: [String]? = nil
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }

    /// The authorization server to use.
    ///
    /// The first advertised. RFC 9728 permits several and gives no ordering rule, so a client
    /// has to choose; choosing the first is at least deterministic, and a client that tried
    /// them in turn would leak an authorization attempt to each one it tried.
    public var primaryAuthorizationServer: String? {
        authorizationServers.first
    }
}

/// Everything an MCP client needs to authenticate against a server it was never configured
/// for.
///
/// The sequence is fixed and each step depends on the last:
///
/// 1. Ask the MCP server which authorization server protects it (RFC 9728).
/// 2. Ask that server what it supports and where its endpoints are (RFC 8414).
/// 3. Register, because there are no pre-issued credentials to use (RFC 7591).
/// 4. Run the authorization code flow with PKCE.
///
/// Steps 1–3 are what a client that merely holds a bearer token skips, and skipping them is
/// why such a client only works against servers whose tokens someone has already obtained by
/// hand.
///
/// The network is injected rather than assumed, so every step above is testable without one.
public struct MCPOAuthSetup: Sendable {

    /// Fetches a document. Injected so the sequence can be tested without a server.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch

    /// Creates a setup helper.
    ///
    /// - Parameter fetch: How to retrieve a document. Defaults to `URLSession.shared`.
    public init(fetch: @escaping Fetch = { url in
        try await URLSession.shared.data(from: url).0
    }) {
        self.fetch = fetch
    }

    /// Discovers how to authenticate against an MCP server.
    ///
    /// - Parameters:
    ///   - server: The MCP server's base URL.
    ///   - identifier: A short name for this provider, used in the stored connection.
    /// - Returns: A configuration, and where to register if registration is offered.
    /// - Throws: ``MCPOAuthError``.
    public func discover(
        server: URL,
        identifier: String
    ) async throws -> (configuration: ProviderConfiguration, registration: URL?) {
        let resource = try await protectedResourceMetadata(server: server)
        guard let issuer = resource.primaryAuthorizationServer else {
            throw MCPOAuthError.noAuthorizationServer
        }

        let metadata: AuthorizationServerMetadata
        do {
            let url = try AuthorizationServerMetadata.discoveryURL(issuer: issuer)
            metadata = try JSONDecoder().decode(
                AuthorizationServerMetadata.self, from: try await fetch(url))
        } catch let error as DiscoveryError {
            throw MCPOAuthError.discovery(error)
        }

        do {
            return (
                try metadata.configuration(
                    identifier: identifier,
                    scope: resource.scopesSupported?.joined(separator: " ")),
                try metadata.registrationURL())
        } catch let error as DiscoveryError {
            throw MCPOAuthError.discovery(error)
        }
    }

    /// Fetches an MCP server's protected resource metadata.
    ///
    /// - Parameter server: The MCP server's base URL.
    /// - Returns: The metadata.
    /// - Throws: ``MCPOAuthError`` or a transport error.
    public func protectedResourceMetadata(server: URL) async throws -> ProtectedResourceMetadata {
        let url = server.appending(path: ".well-known/oauth-protected-resource")
        return try JSONDecoder().decode(
            ProtectedResourceMetadata.self, from: try await fetch(url))
    }
}
