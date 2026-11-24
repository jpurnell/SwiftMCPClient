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

/// What an OAuth request reads, and what it carries that nobody put in it.
///
/// Every OAuth request this package makes goes through `OAuthHTTP`. These hold that one
/// function to three things on the wire: a response is read up to 1 MiB and no further; no
/// cookie a server set is ever sent back; and — with a TLS stub — an `https` endpoint that
/// redirects to `http` is refused with nothing sent in the clear.
@Suite("OAuth requests — size, cookies and downgrade (wire)")
struct MCPOAuthHardeningWireTests {

    static let credentials = ClientCredentials(
        environment: "test", clientID: OAuthWatched.clientID, clientSecret: OAuthWatched.confidential)

    static let grantAnswer = #"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600,"refresh_token":"fixture-refresh-next"}"#

    /// The three kinds of OAuth request, each made against `url`.
    enum Request: String, CaseIterable, Sendable {
        case metadata, registration, token

        func make(at url: URL) async throws {
            switch self {
            case .metadata:
                _ = try await MCPOAuthSetup.fetchMetadata(from: url)
            case .registration:
                _ = try await MCPOAuthSession.register(
                    at: url,
                    request: ClientRegistrationRequest(
                        clientName: "fixture", redirectUris: ["http://127.0.0.1:1/callback"], scope: nil))
            case .token:
                _ = try await MCPOAuthTokenTransport().exchange(
                    endpoint: url, parameters: OAuthWatched.exchange,
                    credentials: MCPOAuthHardeningWireTests.credentials, method: .clientSecretPost)
            }
        }
    }

    static func failure(of operation: () async throws -> Void) async -> (any Error)? {
        await MCPOAuthRedirectWireTests.failure(of: operation)
    }

    // MARK: - Size

    @Test("A response with no end is cut off at 1 MiB, not read until it stops",
          .timeLimit(.minutes(2)), arguments: Request.allCases)
    func endlessBody(_ request: Request) async throws {
        let ceiling = 256 * 1024 * 1024
        let server = try await FaultStubServer.start(.endlessBody(
            head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", ceiling: ceiling))
        let url = try await server.url(path: "/oauth")

        let error = await Self.failure { try await request.make(at: url) }
        guard case .responseTooLarge(let limit, let reason) = error as? MCPError else {
            Issue.record("\(request): expected MCPError.responseTooLarge, got \(String(describing: error))")
            await server.stop()
            return
        }
        #expect(limit == 1024 * 1024)
        #expect(reason.contains("http://127.0.0.1:\(try await server.port)"), "\(reason)")
        #expect(!reason.contains("/oauth"), "the path is not named: \(reason)")
        // The server would have gone on to 256 MiB. What it managed to write before the
        // transfer was cancelled is the limit and whatever the socket buffers held.
        #expect(server.bodyBytesWritten < 64 * 1024 * 1024,
                "\(request): the server wrote \(server.bodyBytesWritten) bytes before it was stopped")
        await server.stop()
    }

    @Test("A response declaring more than 1 MiB is refused without being read",
          .timeLimit(.minutes(1)), arguments: Request.allCases)
    func declaredTooLarge(_ request: Request) async throws {
        let server = try await FaultStubServer.start(.byMethod(
            get: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2000000\r\n\r\n{",
            other: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2000000\r\n\r\n{"))
        let url = try await server.url(path: "/oauth")
        let error = await Self.failure { try await request.make(at: url) }
        guard case .responseTooLarge(let limit, _) = error as? MCPError else {
            Issue.record("\(request): expected MCPError.responseTooLarge, got \(String(describing: error))")
            await server.stop()
            return
        }
        #expect(limit == 1024 * 1024)
        await server.stop()
    }

    @Test("A response of exactly the limit is read; one byte more is not", .timeLimit(.minutes(1)))
    func boundary() async throws {
        for (count, accepted) in [(4096, true), (4097, false)] {
            // No declared length: the body is whatever arrives before the server closes.
            let server = try await FaultStubServer.start(.byMethod(
                get: "",
                other: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
                    + String(repeating: "a", count: count)))
            var request = URLRequest(url: try await server.url(path: "/oauth"))
            request.httpMethod = "POST"
            let posted = request

            var caught: (any Error)?
            var body: Data?
            do {
                body = try await OAuthHTTP.data(for: posted, policy: .never, purpose: "token", limit: 4096).0
            } catch {
                caught = error
            }
            if accepted {
                #expect(body?.count == 4096, "\(String(describing: caught))")
            } else {
                #expect(body == nil)
                if case .responseTooLarge(let limit, _) = caught as? MCPError {
                    #expect(limit == 4096)
                } else {
                    Issue.record("expected MCPError.responseTooLarge at \(count) bytes, got \(String(describing: caught))")
                }
            }
            await server.stop()
        }
    }

    // MARK: - Cookies

    static let cookie = "sid=fixture-cookie-do-not-replay; Path=/"

    @Test("A cookie set on one hop of a metadata redirect is not sent on the next", .timeLimit(.minutes(1)))
    func metadataRedirectCookie() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(method: .GET, path: "/first", status: .found, location: "/second")],
            document: #"{"ok":true}"#,
            setCookie: Self.cookie)
        _ = try await MCPOAuthSetup.fetchMetadata(from: try await server.url(path: "/first"))

        let requests = await server.requests
        #expect(requests.map(\.path) == ["/first", "/second"])
        #expect(requests.allSatisfy { $0.header("Cookie") == nil },
                "a cookie was sent back: \(requests.map { $0.header("Cookie") ?? "-" })")
        await server.stop()
    }

    @Test("A cookie set by one token response is not sent with the next token request",
          .timeLimit(.minutes(1)))
    func tokenCookie() async throws {
        let server = try await RedirectStubServer.start(
            kind: .streamable, postReply: .body(Self.grantAnswer), setCookie: Self.cookie)
        let endpoint = try await server.url(path: "/token")
        let transport = MCPOAuthTokenTransport()
        for parameters in [OAuthWatched.exchange, OAuthWatched.refreshing] {
            let response = try await transport.exchange(
                endpoint: endpoint, parameters: parameters, credentials: Self.credentials, method: .none)
            #expect(response.accessToken == "fixture-access")
        }
        // And nothing leaked into the store every other `URLSession` in the process shares.
        _ = try await MCPOAuthSetup.fetchMetadata(from: try await server.url(path: "/metadata"))

        let requests = await server.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.header("Cookie") == nil },
                "a cookie was sent back: \(requests.map { $0.header("Cookie") ?? "-" })")
        #expect(HTTPCookieStorage.shared.cookies(for: endpoint)?.contains { $0.name == "sid" } != true)
        await server.stop()
    }

    @Test("The session an OAuth request is made on keeps no cookies, credentials or cache")
    func configuration() {
        let configuration = OAuthHTTP.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
    }

    // MARK: - https → http

    #if canImport(Security)
    // Where the Security framework is, `OAuthHTTP.trustedRootsForTesting` lets these
    // requests reach a TLS stub on loopback. swift-corelibs-foundation gives `URLSession` no
    // trust decision to hook — its roots are libcurl's, chosen when the library was built —
    // so on Linux there is no way to stand an `https` server in front of these requests
    // without editing the machine's certificate store, and these tests are Apple-only. The
    // decision they exercise is `HTTPOrigin.resolve`, which `HTTPOriginTests` covers for
    // `https` → `http` on every platform.

    /// An HTTPS server that redirects to a plaintext one, and the root the first chains to.
    static func downgradePair(
        status code: Int, method: HTTPMethod
    ) async throws -> (secure: RedirectStubServer, plain: RedirectStubServer, root: Data) {
        let (authority, leaf) = try TestIdentity.authorityAndLeaf()
        let plain = try await RedirectStubServer.start(
            kind: .streamable, postReply: .body(grantAnswer), document: #"{"served":"in the clear"}"#)
        let plainPort = try await plain.port
        let secure = try await RedirectStubServer.start(
            kind: .streamable,
            redirects: [.init(
                method: method, status: HTTPResponseStatus(statusCode: code),
                location: "http://127.0.0.1:\(plainPort)/elsewhere")],
            tls: try leaf.serverContext())
        return (secure, plain, Data(authority.der))
    }

    @Test("Metadata: an https URL redirected to http is refused, and nothing is sent in the clear",
          .timeLimit(.minutes(1)), arguments: MCPOAuthRedirectWireTests.statuses)
    func metadataDowngrade(_ code: Int) async throws {
        let (secure, plain, root) = try await Self.downgradePair(status: code, method: .GET)
        let url = try await secure.url(path: "/.well-known/oauth-authorization-server")
        let error = await OAuthHTTP.$trustedRootsForTesting.withValue([root]) {
            await Self.failure { _ = try await MCPOAuthSetup.fetchMetadata(from: url) }
        }
        // The handshake completed and the request was made: the refusal is of the redirect,
        // not of the certificate.
        #expect(await secure.requests.count == 1)
        let leaked = await plain.requests
        #expect(leaked.isEmpty, "the plaintext server was sent \(leaked.count) request(s)")
        let refusal = MCPOAuthRedirectWireTests.refused(error)
        #expect(refusal?.destination == "http://127.0.0.1:\(try await plain.port)",
                "got \(String(describing: error))")
        await secure.stop()
        await plain.stop()
    }

    @Test("Token: an https endpoint redirected to http is refused, and nothing is sent in the clear",
          .timeLimit(.minutes(1)), arguments: MCPOAuthRedirectWireTests.statuses)
    func tokenDowngrade(_ code: Int) async throws {
        let (secure, plain, root) = try await Self.downgradePair(status: code, method: .POST)
        let endpoint = try await secure.url(path: "/token")
        let error = await OAuthHTTP.$trustedRootsForTesting.withValue([root]) {
            await Self.failure {
                _ = try await MCPOAuthTokenTransport().exchange(
                    endpoint: endpoint, parameters: OAuthWatched.exchange,
                    credentials: Self.credentials, method: .clientSecretBasic)
            }
        }
        let arrived = await secure.requests
        #expect(arrived.count == 1)
        #expect(arrived.first?.body.contains(OAuthWatched.code) == true, "the request did not reach the https endpoint")
        let leaked = await plain.requests
        #expect(leaked.isEmpty, "the plaintext server was sent: \(OAuthWatched.describe(leaked))")
        let refusal = MCPOAuthRedirectWireTests.refused(error)
        #expect(refusal?.destination == "http://127.0.0.1:\(try await plain.port)",
                "got \(String(describing: error))")
        await secure.stop()
        await plain.stop()
    }

    @Test("Over TLS, an answer that is not a redirect is read as usual", .timeLimit(.minutes(1)))
    func tlsControl() async throws {
        let (authority, leaf) = try TestIdentity.authorityAndLeaf()
        let server = try await RedirectStubServer.start(
            kind: .streamable, postReply: .body(Self.grantAnswer), tls: try leaf.serverContext())
        let endpoint = try await server.url(path: "/token")
        let response = try await OAuthHTTP.$trustedRootsForTesting.withValue([Data(authority.der)]) {
            try await MCPOAuthTokenTransport().exchange(
                endpoint: endpoint, parameters: OAuthWatched.refreshing,
                credentials: Self.credentials, method: .none)
        }
        #expect(response.accessToken == "fixture-access")
        await server.stop()
    }

    @Test("The test roots are the only way in: without them, and with the wrong ones, the handshake fails",
          .timeLimit(.minutes(1)))
    func seamIsNarrow() async throws {
        let (_, leaf) = try TestIdentity.authorityAndLeaf()
        let (unrelated, _) = try TestIdentity.authorityAndLeaf()
        let server = try await RedirectStubServer.start(kind: .streamable, tls: try leaf.serverContext())
        let url = try await server.url(path: "/metadata")

        // No roots bound — every request a shipped program makes: the system decides, and
        // the system does not know this certificate.
        let unbound = await Self.failure { _ = try await MCPOAuthSetup.fetchMetadata(from: url) }
        // Roots bound, but not the ones this server chains to.
        let wrong = await OAuthHTTP.$trustedRootsForTesting.withValue([Data(unrelated.der)]) {
            await Self.failure { _ = try await MCPOAuthSetup.fetchMetadata(from: url) }
        }
        for (name, error) in [("unbound", unbound), ("wrong roots", wrong)] {
            guard case .connectionFailed(let reason) = error as? MCPError else {
                Issue.record("\(name): expected connectionFailed, got \(String(describing: error))")
                continue
            }
            #expect(reason.contains("TLS") || reason.contains("cancelled"), "\(name): \(reason)")
        }
        #expect(await server.requests.isEmpty, "a request reached a server whose certificate was not trusted")
        await server.stop()
    }
    #endif
}
