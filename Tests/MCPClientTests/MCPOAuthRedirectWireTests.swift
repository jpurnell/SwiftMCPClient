import Foundation
#if canImport(FoundationNetworking)
// `URLSession` and friends live here on Linux. Invisible on a Mac, so only CI catches it.
import FoundationNetworking
#endif
import Testing
import NIOHTTP1
import SwiftOAuthCore
import SwiftOAuthClient
@testable import MCPClient

/// Values whose travels the OAuth redirect tests watch.
///
/// None is a credential for anything. Each stands in for one of the things an OAuth request
/// carries, and exists to be recognised if it turns up at a server it was never meant for.
enum OAuthWatched {
    static let clientID = "fixture-client"
    /// Stands in for a `client_secret`.
    static let confidential = "fixture-confidential-do-not-forward"
    /// Stands in for an authorization code.
    static let code = "fixture-code-do-not-forward"
    /// Stands in for a PKCE verifier.
    static let verifier = "fixture-verifier-do-not-forward"
    /// Stands in for a refresh token.
    static let refresh = "fixture-refresh-do-not-forward"

    /// What an authorization-code exchange posts.
    static let exchange = [
        "grant_type": "authorization_code",
        "code": code,
        "code_verifier": verifier,
        "redirect_uri": "http://127.0.0.1:1/callback",
    ]

    /// What a refresh posts.
    static let refreshing = ["grant_type": "refresh_token", "refresh_token": refresh]

    /// Names what a list of requests carried, of the things being watched.
    static func describe(_ requests: [RedirectStubServer.Request]) -> String {
        guard !requests.isEmpty else { return "nothing" }
        return requests.map { request in
            var carried: [String] = []
            if let authorization = request.header("Authorization") {
                carried.append(authorization.hasPrefix("Basic ") ? "Authorization (client credentials)" : "Authorization")
            }
            for (name, value) in [("client_secret", confidential), ("code", code),
                                  ("code_verifier", verifier), ("refresh_token", refresh)]
            where request.body.contains(value) {
                carried.append(name)
            }
            if request.body.contains("client_name") { carried.append("registration document") }
            return "\(request.method) \(request.path) [\(carried.joined(separator: ", "))]"
        }.joined(separator: "; ")
    }
}

/// Where an OAuth request goes when the server it was sent to answers with a redirect.
///
/// The transports were held to their origin; the OAuth requests were not. They were made on
/// `URLSession.shared`, which follows a redirect wherever it points. Measured between two
/// loopback servers, for the requests this package and the `swift-oauth` release it resolves
/// make, the second server received:
///
/// | Request | `301` / `302` / `303` | `307` / `308` |
/// |---|---|---|
/// | protected-resource / authorization-server metadata `GET` | the `GET`, and its document was accepted | the same |
/// | dynamic client registration `POST` | a `GET` | the `POST`, with the registration document |
/// | token exchange, public client | a `GET` | the `POST`: `code`, `code_verifier` |
/// | token exchange, `client_secret_post` | a `GET` | the `POST`: `client_secret`, `code`, `code_verifier` |
/// | token exchange, `client_secret_basic` | a `GET` | the `POST`: `code`, `code_verifier` (not `Authorization`) |
/// | refresh | a `GET` | the `POST`: `refresh_token` (and `client_secret` when posted) |
///
/// `URLSession` removes `Authorization` when a redirect changes origin — on this platform;
/// it is not something Foundation documents — and nothing else: the form body is re-sent
/// whole on `307` and `308`. An `https` server redirecting to an `http` one was followed
/// the same way.
///
/// What a redirect may do now depends on what the request carries:
///
/// - **Metadata** is public and carries nothing, but it is only worth anything from the
///   server it describes (RFC 8414 §3 and §3.3, RFC 9728 §3 and §3.3): a redirect is
///   followed only within the origin of the URL being fetched.
/// - **Everything else** — registration, token exchange, refresh, revocation — carries a
///   credential or returns one, and is sent to the endpoint the metadata named and nowhere
///   else: no redirect is followed at all, not even on the same origin.
@Suite("OAuth requests — redirects (wire)")
struct MCPOAuthRedirectWireTests {

    static let statuses = [301, 302, 303, 307, 308]

    /// The token transport ``MCPOAuthSession`` uses when it is not given one.
    static func sessionTokenTransport() -> any TokenTransport {
        MCPOAuthTokenTransport()
    }

    /// Two servers: the one the request is sent to, which redirects it, and the one the
    /// redirect names.
    static func pair(
        status code: Int,
        method: HTTPMethod?,
        location: @Sendable (_ otherPort: Int) -> String = { "http://127.0.0.1:\($0)/elsewhere?session=\(Watched.session)" },
        document: String = "{}"
    ) async throws -> (server: RedirectStubServer, other: RedirectStubServer, otherOrigin: String) {
        let other = try await RedirectStubServer.start(kind: .streamable, document: document)
        let otherPort = try await other.port
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                method: method, status: HTTPResponseStatus(statusCode: code), location: location(otherPort))],
            document: document)
        return (server, other, "http://127.0.0.1:\(otherPort)")
    }

    /// The origin a refused redirect named, if that is what an error is.
    static func refused(_ error: (any Error)?) -> (destination: String, reason: String)? {
        guard case .redirectRejected(let destination, let reason) = error as? MCPError else { return nil }
        return (destination, reason)
    }

    /// Runs an operation that is expected to fail, and returns what it failed with.
    static func failure(of operation: () async throws -> Void) async -> (any Error)? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    /// What every refusal owes: nothing sent, the destination named by origin only.
    static func expectRefused(
        _ error: (any Error)?,
        naming origin: String,
        other: RedirectStubServer,
        _ label: String
    ) async {
        let elsewhere = await other.requests
        #expect(elsewhere.isEmpty, "\(label): the other origin received \(OAuthWatched.describe(elsewhere))")
        guard let refusal = refused(error) else {
            Issue.record("\(label): ended with \(String(describing: error))")
            return
        }
        #expect(refusal.destination == origin, "\(label): the error names \(refusal.destination)")
        let text = String(describing: error)
        for part in ["/elsewhere", Watched.session] {
            #expect(!text.contains(part), "\(label): the error carries \(part): \(text)")
        }
    }

    // MARK: - Metadata

    static let resourceDocument = #"{"resource":"https://mcp.example","authorization_servers":["https://auth.example"]}"#

    @Test("A metadata fetch does not follow a redirect to another origin",
          .timeLimit(.minutes(1)), arguments: statuses)
    func metadataDoesNotLeaveTheOrigin(_ code: Int) async throws {
        let (server, other, otherOrigin) = try await Self.pair(
            status: code, method: .GET, document: Self.resourceDocument)

        let error = await Self.failure {
            // Would succeed if followed: the other server serves a well-formed document,
            // which is the point — a document from another origin describing this one.
            _ = try await MCPOAuthSetup().protectedResourceMetadata(server: try await server.url)
        }
        #expect(await other.requests.count == 0, "the document was fetched from the other origin")
        await Self.expectRefused(error, naming: otherOrigin, other: other, "metadata \(code)")
        await server.stop()
        await other.stop()
    }

    @Test("A metadata fetch follows a redirect within its own origin",
          .timeLimit(.minutes(1)), arguments: statuses)
    func metadataFollowsWithinTheOrigin(_ code: Int) async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                method: .GET, path: "/.well-known/oauth-protected-resource/mcp",
                status: HTTPResponseStatus(statusCode: code), location: "/metadata/moved")],
            document: Self.resourceDocument)

        let metadata = try await MCPOAuthSetup().protectedResourceMetadata(server: try await server.url)
        #expect(metadata.authorizationServers == ["https://auth.example"])
        #expect(await server.requests.map(\.path)
                == ["/.well-known/oauth-protected-resource/mcp", "/metadata/moved"])
        await server.stop()
    }

    /// The same host on another port is another origin, and so is `localhost` for
    /// `127.0.0.1`: the comparison is ``HTTPOrigin``'s, the one the transports use.
    @Test("A metadata redirect to the same host by another name is refused", .timeLimit(.minutes(1)))
    func metadataOtherSpelling() async throws {
        let (server, other, otherOrigin) = try await Self.pair(
            status: 302, method: .GET,
            location: { "http://localhost:\($0)/elsewhere?session=\(Watched.session)" },
            document: Self.resourceDocument)
        let error = await Self.failure {
            _ = try await MCPOAuthSetup().protectedResourceMetadata(server: try await server.url)
        }
        #expect(await server.requests.count == 2, "both candidate locations are asked, and both redirect")
        await Self.expectRefused(
            error, naming: otherOrigin.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
            other: other, "metadata by another name")
        await server.stop()
        await other.stop()
    }

    // MARK: - Registration

    @Test("A registration request is never redirected to another origin",
          .timeLimit(.minutes(1)), arguments: statuses)
    func registrationDoesNotLeaveTheOrigin(_ code: Int) async throws {
        let (server, other, otherOrigin) = try await Self.pair(status: code, method: .POST)
        let error = await Self.failure {
            _ = try await MCPOAuthSession.register(
                at: try await server.url(path: "/register"),
                request: ClientRegistrationRequest(
                    clientName: "Test", redirectUris: ["http://127.0.0.1:1/callback"]))
        }
        await Self.expectRefused(error, naming: otherOrigin, other: other, "registration \(code)")
        #expect(await server.requests.map(\.method) == ["POST"])
        await server.stop()
        await other.stop()
    }

    /// Not even within the origin. The endpoint is the one the server's own metadata named;
    /// a server that wants registrations elsewhere says so there.
    @Test("A registration request is not redirected within its origin either",
          .timeLimit(.minutes(1)), arguments: statuses)
    func registrationIsNotRedirectedAtAll(_ code: Int) async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                method: .POST, path: "/register",
                status: HTTPResponseStatus(statusCode: code), location: "/moved")])
        let error = await Self.failure {
            _ = try await MCPOAuthSession.register(
                at: try await server.url(path: "/register"),
                request: ClientRegistrationRequest(
                    clientName: "Test", redirectUris: ["http://127.0.0.1:1/callback"]))
        }
        #expect(Self.refused(error)?.destination == "http://127.0.0.1:\(try await server.port)",
                "registration \(code) ended with \(String(describing: error))")
        #expect(await server.requests.map(\.path) == ["/register"])
        await server.stop()
    }

    // MARK: - Token endpoint

    /// One way a client authenticates at the token endpoint.
    enum Authentication: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case publicClient, secretInBody, secretInHeader

        var testDescription: String { rawValue }

        var method: ClientAuthenticationMethod {
            switch self {
            case .publicClient: return .none
            case .secretInBody: return .clientSecretPost
            case .secretInHeader: return .clientSecretBasic
            }
        }
    }

    static let credentials = ClientCredentials(
        environment: "test", clientID: OAuthWatched.clientID, clientSecret: OAuthWatched.confidential)

    @Test("A token exchange is never redirected to another origin",
          .timeLimit(.minutes(2)), arguments: Authentication.allCases, statuses)
    func tokenExchangeDoesNotLeaveTheOrigin(_ authentication: Authentication, _ code: Int) async throws {
        let (server, other, otherOrigin) = try await Self.pair(status: code, method: .POST)
        let endpoint = try await server.url(path: "/token")
        let error = await Self.failure {
            _ = try await Self.sessionTokenTransport().exchange(
                endpoint: endpoint, parameters: OAuthWatched.exchange,
                credentials: Self.credentials, method: authentication.method)
        }
        await Self.expectRefused(error, naming: otherOrigin, other: other, "token/\(authentication) \(code)")
        #expect(await server.requests.map(\.method) == ["POST"])
        await server.stop()
        await other.stop()
    }

    @Test("A refresh is never redirected to another origin",
          .timeLimit(.minutes(2)), arguments: [Authentication.publicClient, .secretInBody], statuses)
    func refreshDoesNotLeaveTheOrigin(_ authentication: Authentication, _ code: Int) async throws {
        let (server, other, otherOrigin) = try await Self.pair(status: code, method: .POST)
        let endpoint = try await server.url(path: "/token")
        let error = await Self.failure {
            _ = try await Self.sessionTokenTransport().exchange(
                endpoint: endpoint, parameters: OAuthWatched.refreshing,
                credentials: Self.credentials, method: authentication.method)
        }
        await Self.expectRefused(error, naming: otherOrigin, other: other, "refresh/\(authentication) \(code)")
        #expect(await server.requests.map(\.method) == ["POST"])
        await server.stop()
        await other.stop()
    }

    @Test("A token request is not redirected within its origin either",
          .timeLimit(.minutes(1)), arguments: statuses)
    func tokenExchangeIsNotRedirectedAtAll(_ code: Int) async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                method: .POST, path: "/token",
                status: HTTPResponseStatus(statusCode: code), location: "/moved")])
        let endpoint = try await server.url(path: "/token")
        let error = await Self.failure {
            _ = try await Self.sessionTokenTransport().exchange(
                endpoint: endpoint, parameters: OAuthWatched.exchange,
                credentials: Self.credentials, method: .clientSecretPost)
        }
        let refusal = Self.refused(error)
        #expect(refusal?.destination == "http://127.0.0.1:\(try await server.port)",
                "token \(code) ended with \(String(describing: error))")
        #expect(refusal?.reason.contains("HTTP \(code)") == true)
        #expect(await server.requests.map(\.path) == ["/token"])
        await server.stop()
    }

    /// A token endpoint that answers normally still works through the same door.
    @Test("A token exchange that is not redirected is delivered and decoded", .timeLimit(.minutes(1)))
    func tokenExchangeStillWorks() async throws {
        let server = try await RedirectStubServer.start(kind: .streamable, postReply: .status(.badRequest))
        let endpoint = try await server.url(path: "/token")
        let error = await Self.failure {
            _ = try await Self.sessionTokenTransport().exchange(
                endpoint: endpoint, parameters: OAuthWatched.exchange,
                credentials: Self.credentials, method: .clientSecretPost)
        }
        // The stub answers `400` with an empty object: the provider's refusal, reported as
        // one, and not mistaken for a redirect or a network failure.
        #expect(error is OAuthError, "ended with \(String(describing: error))")
        let request = try #require(await server.requests.first)
        #expect(request.body.contains(OAuthWatched.code))
        #expect(request.body.contains(OAuthWatched.confidential))
        await server.stop()
    }

    // MARK: - Failures

    /// `URLSession` puts the whole failing URL in its error — query included, and any key a
    /// deployment keeps in its path. The OAuth requests' network failures are described the
    /// way the transports' are: by kind and origin.
    @Test("A token endpoint that cannot be reached is named by origin only", .timeLimit(.minutes(1)))
    func unreachableEndpointIsRedacted() async throws {
        let gone = try await FaultStubServer.start(.silent)
        let endpoint = try await gone.url(
            path: "/tenant/\(TransportFailureTests.pathKey)/token", query: "api_key=\(Watched.key)")
        try await gone.stopAndWait()

        let error = await Self.failure {
            _ = try await Self.sessionTokenTransport().exchange(
                endpoint: endpoint, parameters: OAuthWatched.exchange,
                credentials: Self.credentials, method: .clientSecretPost)
        }
        let caught = try #require(error, "the request did not fail")
        for text in TransportFailureTests.renderings(of: caught) {
            #expect(!text.contains(TransportFailureTests.pathKey), "the error carries the path key: \(text)")
            #expect(!text.contains(Watched.key), "the error carries the query: \(text)")
            #expect(!text.contains(OAuthWatched.confidential))
        }
        guard case .connectionFailed(let reason) = caught as? MCPError else {
            Issue.record("expected connectionFailed, got \(caught)")
            return
        }
        #expect(reason.contains(HTTPOrigin.description(of: endpoint)))
    }
}
