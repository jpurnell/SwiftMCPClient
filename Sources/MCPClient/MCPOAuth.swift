import Foundation
#if canImport(FoundationNetworking)
// `URLSession`, `URLRequest` and `HTTPURLResponse` live here on Linux rather than in
// Foundation. Without this the file does not compile there at all — and it is invisible on a
// Mac, which is why CI is the only thing that catches it.
import FoundationNetworking
#endif
import Logging
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

    /// Nothing usable was served where protected-resource metadata should be.
    ///
    /// Distinct from ``noAuthorizationServer``: that is a server saying it does not use
    /// OAuth, this is a server that should have answered and did not. Carrying the URL and
    /// status matters because the client tries more than one candidate location, and
    /// "not found" without saying where is not actionable.
    ///
    /// A `status` of `0` means no candidate URL could be formed from the server URL at all.
    ///
    /// The URL is where the client looked, without userinfo, query or fragment, and with any
    /// path segment that could be a credential replaced — an error is printed and logged,
    /// and those are the parts of a URL that carry secrets.
    case metadataNotFound(url: URL, status: Int)

    /// The authorization server's metadata names a different issuer from the one it was
    /// fetched for.
    ///
    /// RFC 8414 §3.3: the `issuer` in the document MUST be identical to the issuer whose
    /// well-known URL it was retrieved from, and a document where it is not MUST NOT be
    /// used. Every endpoint in the document is held to the document's issuer, so a document
    /// allowed to choose its own issuer chooses where the authorization code goes.
    ///
    /// - Parameters:
    ///   - expected: The issuer the MCP server advertised, and the metadata was fetched for.
    ///   - found: The issuer the document claims, as an origin only.
    case issuerMismatch(expected: String, found: String)

    /// The protected-resource metadata describes a different resource from the one it was
    /// fetched for.
    ///
    /// RFC 9728 §3.3: the `resource` in the document MUST be identical to the resource
    /// identifier whose well-known URL it was retrieved from, and a document where it is
    /// not MUST NOT be used. §7.3 says what the check is for: a document that may name any
    /// resource it likes can claim to be another server's, and the token the client then
    /// obtains — its audience is this value, by RFC 8707 — is one that other server accepts.
    ///
    /// Identical means the same string, after the normalisation RFC 3986 §6.2.2.1 and
    /// §6.2.3 allow — scheme and host in lower case, a default port left out — and with one
    /// trailing slash on the path overlooked. Nothing looser: a different path, a different
    /// case in the path, a query, a fragment or userinfo is a different resource.
    ///
    /// Thrown once every candidate location has been tried. A mismatch at one location does
    /// not stop the next being asked — that document is simply not used — but if none
    /// serves a usable one, this is reported in preference to a later location's `404`.
    ///
    /// - Parameters:
    ///   - expected: The resource the document had to name: the MCP server's URL, without
    ///     query, fragment or userinfo, as an origin and a redacted path.
    ///   - found: The `resource` the document claims, as an origin and a redacted path.
    case resourceMismatch(expected: String, found: String)
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
    /// - Parameter fetch: How to retrieve a document. Defaults to
    ///   ``fetchMetadata(from:)``.
    ///
    ///   **A `fetch` of your own replaces every protection the default has on the request.**
    ///   The default follows a redirect only within the origin of the URL it was asked for,
    ///   reads at most 1 MiB, and sends no cookie or stored credential. None of that is
    ///   applied to a closure passed here: if it is `URLSession.shared.data(from:)`, it
    ///   follows a redirect to any origin — `https` to `http` included — and reads a body
    ///   of any size. Hold your own to the same rules, or call ``fetchMetadata(from:)``
    ///   from inside it.
    ///
    ///   What does not depend on who fetched is checked on whatever comes back, yours
    ///   included: the protected-resource document's `resource` must be the server it was
    ///   asked about (``MCPOAuthError/resourceMismatch(expected:found:)``), the
    ///   authorization server's `issuer` must be the one asked for
    ///   (``MCPOAuthError/issuerMismatch(expected:found:)``), and every endpoint the
    ///   document names must be `https` and on its issuer's origin
    ///   (``MCPOAuthError/discovery(_:)``).
    public init(fetch: @escaping Fetch = { url in try await MCPOAuthSetup.fetchMetadata(from: url) }) {
        self.fetch = fetch
    }

    /// Fetches a metadata document, following a redirect only within the document's origin.
    ///
    /// A discovery document names where this client will shortly send an authorization
    /// code and a refresh token, so where the document itself came from matters: RFC 8414 §3
    /// and RFC 9728 §3 locate it at a well-known path on the issuer's — or the protected
    /// resource's — own host. A redirect to the same scheme, host and port is followed, up
    /// to five times; a redirect anywhere else is not, nothing is sent to it, and the fetch
    /// fails. `https` to `http` is somewhere else.
    ///
    /// - Parameter url: The document's URL.
    /// - Returns: The document.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if the server redirected
    ///   the request off the URL's origin, naming the destination by origin only;
    ///   ``MCPError/connectionFailed(reason:)`` if the request could not be made, naming the
    ///   URL's origin; ``MCPOAuthError/metadataNotFound(url:status:)`` for a status that is
    ///   not a success.
    public static func fetchMetadata(from url: URL) async throws -> Data {
        let (data, response) = try await OAuthHTTP.data(
            for: URLRequest(url: url), policy: .withinOrigin, purpose: "metadata")
        return try validate(data: data, response: response, url: url)
    }

    /// Rejects a response that carries a failing HTTP status.
    ///
    /// Without this, a `404` body is handed to `JSONDecoder` and "there is nothing at that
    /// URL" arrives as "the JSON was malformed" — a diagnostic that sends the reader to the
    /// wrong place entirely. A response with no HTTP status is not judged, so injected
    /// fetches and non-HTTP schemes keep working.
    ///
    /// - Parameters:
    ///   - data: The body as received.
    ///   - response: The response, if the transport produced one.
    ///   - url: The URL requested, carried into the error so the caller knows where we looked
    ///     — by origin and path only.
    /// - Returns: `data`, unchanged, when the status is a success or absent.
    /// - Throws: ``MCPOAuthError/metadataNotFound(url:status:)`` for any non-2xx status.
    public static func validate(data: Data, response: URLResponse?, url: URL) throws -> Data {
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200...299).contains(http.statusCode) else {
            throw notFound(at: url, status: http.statusCode)
        }
        return data
    }

    /// The error for a metadata document that was not where it was looked for.
    ///
    /// The one place ``MCPOAuthError/metadataNotFound(url:status:)`` is made, so that the URL
    /// it carries has always been through ``HTTPOrigin/redactedURL(_:)``. The server URL is
    /// the caller's and can hold userinfo or a key in its query; the error is a public value
    /// a caller will print.
    ///
    /// - Parameters:
    ///   - url: Where the client looked.
    ///   - status: The HTTP status, or `0` if nothing could be requested.
    /// - Returns: The error, naming `url` without userinfo, query or fragment.
    static func notFound(at url: URL, status: Int) -> MCPOAuthError {
        // A URL that cannot be taken apart is named as the root, never as itself: the
        // fallback must not be the thing the redaction exists to keep out.
        .metadataNotFound(url: HTTPOrigin.redactedURL(url) ?? URL(fileURLWithPath: "/"), status: status)
    }

    /// The candidate metadata URLs for a server, most specific first.
    ///
    /// RFC 9728 §3.1 inserts the well-known segment *between the host and the server's
    /// path*, giving `https://host/.well-known/oauth-protected-resource/path`. Appending it
    /// to the end of the path instead — the obvious-looking mistake — produces a URL that
    /// 404s against every server whose MCP endpoint is not at an origin root.
    ///
    /// Servers at an origin root publish at the bare well-known path, and some servers with
    /// a path publish there too, so that location is tried second rather than assumed away.
    /// A server with no path yields one candidate, not the same URL twice.
    ///
    /// - Parameter server: The MCP server's base URL.
    /// - Returns: One or two URLs, in the order they should be attempted. Empty only if no
    ///   URL could be formed at all.
    public static func protectedResourceURLs(server: URL) -> [URL] {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return []
        }
        // Query and fragment belong to the MCP endpoint, not to its metadata document.
        components.query = nil
        components.fragment = nil

        let wellKnown = "/.well-known/oauth-protected-resource"
        // A pasted URL brings its trailing slash along; left in, it becomes an empty path
        // segment and a different URL.
        let path = server.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var candidates: [URL] = []
        if !path.isEmpty {
            components.path = "\(wellKnown)/\(path)"
            if let url = components.url { candidates.append(url) }
        }
        components.path = wellKnown
        if let url = components.url { candidates.append(url) }
        return candidates
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

        // RFC 8414 §3.3, before anything in the document is used. The endpoints below are
        // held to the document's own `issuer`, which protects nothing if the document may
        // name any issuer it likes.
        guard Self.isSameIssuer(metadata.issuer, issuer) else {
            throw MCPOAuthError.issuerMismatch(
                expected: URL(string: issuer).map(HTTPOrigin.redacted) ?? HTTPOrigin.noOrigin,
                found: URL(string: metadata.issuer).map(HTTPOrigin.description(of:)) ?? HTTPOrigin.noOrigin)
        }

        do {
            // The **issuer** identifies the configuration, not the MCP server's host. MCP
            // 2026-07-28 (SEP-2352) requires a client to key persisted credentials by the
            // issuer, never reuse them with a different authorization server, and re-register
            // when it changes — and a key naming the MCP host says nothing about which
            // authorization server issued what it holds.
            //
            // The passed identifier survives only as a fallback for a server whose metadata
            // states no issuer, which is malformed but need not be fatal here.
            return (
                try metadata.configuration(
                    identifier: metadata.issuer.isEmpty ? identifier : metadata.issuer,
                    scope: resource.scopesSupported?.joined(separator: " "),
                    // RFC 8707. The identifier the *resource* published about itself, which is
                    // exactly what a server with a strict resource policy expects to be named.
                    // Discovery has held this value all along; until 0.11.1 there was nowhere
                    // to put it, so the client read it and then sent nothing.
                    resource: URL(string: resource.resource)),
                try metadata.registrationURL())
        } catch let error as DiscoveryError {
            throw MCPOAuthError.discovery(error)
        }
    }

    /// Whether the issuer a metadata document claims is the one it was fetched for.
    ///
    /// RFC 8414 §3.3 says identical, and this compares the two strings as they are — with
    /// one allowance, a single trailing slash on either, which is how the same issuer is
    /// routinely written two ways and which names no other server.
    ///
    /// - Parameters:
    ///   - claimed: The `issuer` in the document.
    ///   - requested: The issuer the well-known URL was built from.
    /// - Returns: `true` if they are the same issuer.
    static func isSameIssuer(_ claimed: String, _ requested: String) -> Bool {
        func trimmed(_ issuer: String) -> Substring {
            issuer.hasSuffix("/") ? issuer.dropLast() : Substring(issuer)
        }
        return !claimed.isEmpty && trimmed(claimed) == trimmed(requested)
    }

    /// Fetches an MCP server's protected resource metadata.
    ///
    /// The locations ``protectedResourceURLs(server:)`` lists are asked in order, and the
    /// first that serves a document describing this server is used. The order is the MCP
    /// authorization specification's: the location RFC 9728 §3.1 derives from the server's
    /// own URL, then the root of its host.
    ///
    /// A location that fails does not stop the next being asked. That includes one whose
    /// redirect was refused and one whose document names another resource: each is evidence
    /// about *that* location, the other location is on the same host and is held to the
    /// same checks, and nothing was sent to the redirect's destination. What the refusal
    /// must not be is hidden. So when no location serves a usable document, the error is
    /// the first refused redirect or resource mismatch, if there was one — not whatever the
    /// last location happened to answer, which is typically a `404` that says nothing about
    /// why discovery failed.
    ///
    /// - Parameter server: The MCP server's base URL.
    /// - Returns: The metadata.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` or
    ///   ``MCPOAuthError/resourceMismatch(expected:found:)`` if any location was refused
    ///   for that reason and none served a usable document; otherwise the last location's
    ///   failure — ``MCPOAuthError/metadataNotFound(url:status:)``, a transport error, or a
    ///   decoding error.
    public func protectedResourceMetadata(server: URL) async throws -> ProtectedResourceMetadata {
        let candidates = Self.protectedResourceURLs(server: server)
        guard !candidates.isEmpty else {
            throw Self.notFound(at: server, status: 0)
        }

        var refusal: (any Error)?
        var lastError: (any Error)?
        for candidate in candidates {
            do {
                let document = try JSONDecoder().decode(
                    ProtectedResourceMetadata.self, from: try await fetch(candidate))
                // RFC 9728 §3.3, before anything in the document is used — and on whatever
                // `fetch` returned, the caller's own included.
                let accepted = Self.resourceIdentifiers(server: server, fetchedFrom: candidate)
                guard accepted.contains(where: { Self.isSameResource(document.resource, $0) }) else {
                    throw MCPOAuthError.resourceMismatch(
                        expected: accepted.first.flatMap(URL.init(string:)).map(HTTPOrigin.redacted)
                            ?? HTTPOrigin.noOrigin,
                        found: URL(string: document.resource).map(HTTPOrigin.redacted) ?? HTTPOrigin.noOrigin)
                }
                return document
            } catch {
                // Keep going: a 404 at the RFC location is expected against servers that
                // publish only at the origin root.
                let logger = Logger(label: "MCPClient.MCPOAuth")
                // logging: swift-log has no privacy annotations; the candidate by origin and redacted path, the failure by kind — no userinfo, query or error text
                logger.debug("protected-resource metadata not usable at \(HTTPOrigin.redacted(candidate)): \(TransportFailure.kind(of: error))")
                if refusal == nil, Self.isRefusal(error) { refusal = error }
                lastError = error
            }
        }
        throw refusal ?? lastError ?? Self.notFound(at: server, status: 0)
    }

    /// Whether a failure is this client declining something a server asked of it, rather
    /// than a document simply not being there.
    private static func isRefusal(_ error: any Error) -> Bool {
        if case .redirectRejected = error as? MCPError { return true }
        if case .resourceMismatch = error as? MCPOAuthError { return true }
        return false
    }

    /// The resource identifiers a document fetched from a candidate location may name.
    ///
    /// RFC 9728 §3.3 gives two identities, and each location is held to the ones that apply
    /// to it:
    ///
    /// - **The identifier the well-known string was inserted into.** For the location
    ///   derived from the server's path that is the server's URL; for the root location it
    ///   is the origin alone.
    /// - **The URL the client uses to make requests to the resource server** — the second
    ///   paragraph's rule for a metadata URL the client was handed rather than derived.
    ///   The root location is that case for a server with a path: the MCP authorization
    ///   specification sends a client there as a fallback, and a server publishing there
    ///   names itself by the URL it is reached at.
    ///
    /// So the path location accepts the server's URL, and the root location accepts the
    /// server's URL or its origin. Query, fragment and userinfo are not part of either: the
    /// well-known URL is built without the query (see ``protectedResourceURLs(server:)``),
    /// a resource identifier has no fragment (RFC 9728 §1.2), and userinfo is a credential.
    ///
    /// - Parameters:
    ///   - server: The MCP server's base URL.
    ///   - candidate: One of ``protectedResourceURLs(server:)``.
    /// - Returns: The acceptable identifiers, the server's own URL first. Empty if the
    ///   server URL cannot be taken apart, which accepts nothing.
    static func resourceIdentifiers(server: URL, fetchedFrom candidate: URL) -> [String] {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return []
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let own = components.string else { return [] }

        components.path = ""
        let isRoot = candidate.path == "/.well-known/oauth-protected-resource"
        guard isRoot, let origin = components.string, origin != own else { return [own] }
        return [own, origin]
    }

    /// Whether the resource a document claims is the one it had to name.
    ///
    /// RFC 9728 §3.3 says identical. The two are compared as strings after the
    /// normalisation RFC 3986 allows without changing what a URL identifies — §6.2.2.1,
    /// scheme and host in lower case; §6.2.3, a port that is the scheme's default left out
    /// — and with a single trailing slash on the path overlooked, as it is for the issuer.
    /// The path is otherwise compared exactly, case and percent-encoding included; a
    /// claimed resource carrying a fragment or userinfo is never the same.
    ///
    /// - Parameters:
    ///   - claimed: The `resource` in the document.
    ///   - expected: The identifier it had to name.
    /// - Returns: `true` if they are the same resource.
    static func isSameResource(_ claimed: String, _ expected: String) -> Bool {
        guard let left = canonicalResource(claimed), let right = canonicalResource(expected) else {
            return false
        }
        return left == right
    }

    /// A resource identifier in the form two of them are compared in, or `nil` if it is not
    /// one: no scheme or host, or a fragment or userinfo.
    private static func canonicalResource(_ identifier: String) -> String? {
        guard let components = URLComponents(string: identifier),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.fragment == nil, components.user == nil, components.password == nil else {
            return nil
        }
        let isDefault = (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80)
        let port = components.port.flatMap { isDefault ? nil : ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(path)\(query)"
    }
}
