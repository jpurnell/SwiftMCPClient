import Foundation
#if canImport(FoundationNetworking)
// `URLSession` and friends live here on Linux. Invisible on a Mac, so only CI catches it.
import FoundationNetworking
#endif
import Testing
import SwiftOAuthCore
import SwiftOAuthClient
@testable import MCPClient

/// The sign-in sequence, without a browser and without a live server.
///
/// What is exercised here is the ordering, which is where this kind of code goes wrong: the
/// listener must be bound before registration, because the redirect URI carries its assigned
/// port and the server records that URI at registration time.
@Suite("MCP OAuth session")
struct MCPOAuthSessionTests {

    /// A server that does not advertise an authorization server is saying it does not use
    /// OAuth, and the session must say so rather than guessing at an endpoint.
    @Test("A server without OAuth is reported as such")
    func serverWithoutOAuth() async {
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch(authorizationServers: [])),
            storage: InMemoryClientStorage())

        await #expect(throws: MCPOAuthError.noAuthorizationServer) {
            try await session.signIn(
                server: serverURL(), clientName: "Test", openURL: { _ in })
        }
    }

    /// Without registration there is no way to obtain credentials, because this client has
    /// none in advance. Reported before a browser is opened, since opening one would be
    /// asking the user to complete a flow that cannot finish.
    @Test("A server without registration is refused before a browser opens")
    func registrationUnavailable() async {
        let opened = OpenedURLs()
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch(registrationEndpoint: nil)),
            storage: InMemoryClientStorage())

        await #expect(throws: MCPOAuthError.registrationUnavailable) {
            try await session.signIn(
                server: serverURL(), clientName: "Test",
                openURL: { url in Task { await opened.record(url) } })
        }

        let urls = await opened.urls
        #expect(urls.isEmpty, "a browser was opened for a flow that cannot complete")
    }

    /// The origin binding holds through this path: an authorization server naming a token
    /// endpoint on another host is refused, and again before any browser opens.
    @Test("An authorization server pointing elsewhere never reaches a browser")
    func foreignEndpointNeverOpensBrowser() async {
        let opened = OpenedURLs()
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(
                fetch: metadataFetch(tokenEndpoint: "https://attacker.example/token")),
            storage: InMemoryClientStorage())

        await #expect(throws: (any Error).self) {
            try await session.signIn(
                server: serverURL(), clientName: "Test",
                openURL: { url in Task { await opened.record(url) } })
        }

        let urls = await opened.urls
        #expect(urls.isEmpty, "the user was sent to authorize against a refused server")
    }

    /// Before signing in there is no header to offer, and the session must say so rather
    /// than returning an empty `Bearer `.
    @Test("An unsigned-in session offers no header")
    func noHeaderBeforeSignIn() async throws {
        let session = MCPOAuthSession(storage: InMemoryClientStorage())
        #expect(try await session.authorizationHeader() == nil)
        #expect(await session.isSignedIn == false)
    }

    /// Signing out of a session that never signed in is not an error — a user pressing it
    /// twice should not see a failure.
    @Test("Signing out when not signed in is harmless")
    func signOutWhenNotSignedIn() async throws {
        let session = MCPOAuthSession(storage: InMemoryClientStorage())
        try await session.signOut()
        #expect(await session.isSignedIn == false)
    }
}

@Suite("MCP OAuth session — the redirect URI")
struct RedirectURITests {

    /// The redirect URI must be bound before it is registered, because it names the port the
    /// listener actually holds. Registering a port nothing is listening on produces a flow
    /// that completes in the browser and never comes back.
    @Test("The registered redirect URI names a port that is actually listening")
    func redirectURINamesALivePort() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        defer { Task { await listener.stop() } }

        let port = try loopbackPort(of: redirect)

        // Something is genuinely accepting on that port.
        async let received = listener.awaitCallback(timeout: .seconds(5))
        guard let probe = loopbackURL(port: port, target: "/callback?code=c&state=s") else {
            Issue.record("could not build the probe URL")
            return
        }
        _ = try await URLSession.shared.data(from: probe)

        let url = try await received
        #expect(url.port == port)
    }

    /// Loopback, never a routable address. A redirect URI on another interface could be
    /// delivered by anything that can reach this machine.
    @Test("The redirect URI is on the loopback address")
    func redirectIsLoopback() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        await listener.stop()

        // This is the loopback-host check itself, so it cannot delegate to a helper that
        // has already made the same check.
        // SECURITY: the host is asserted against the loopback literal on the next line.
        let url = try #require(URL(string: redirect))
        #expect(url.host() == "127.0.0.1")
        #expect(url.host() != "0.0.0.0")
        #expect(url.host() != "localhost", "a name can resolve somewhere else; an address cannot")
    }
}

// MARK: - Helpers

private func serverURL() -> URL {
    URL(string: "https://mcp.example.com") ?? URL(fileURLWithPath: "/")
}

/// Records the URLs a flow tried to open, so a test can assert none were.
private actor OpenedURLs {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

/// Serves canned discovery documents.
private func metadataFetch(
    issuer: String = "https://auth.example.com",
    authorizationServers: [String]? = nil,
    registrationEndpoint: String? = "https://auth.example.com/register",
    tokenEndpoint: String? = nil,
    challengeMethods: [String]? = ["S256"]
) -> MCPOAuthSetup.Fetch {
    let servers = authorizationServers ?? [issuer]
    let token = tokenEndpoint ?? "\(issuer)/token"

    return { requested in
        if requested.path.contains("oauth-protected-resource") {
            return try JSONEncoder().encode(ProtectedResourceMetadata(
                resource: "https://mcp.example.com",
                authorizationServers: servers,
                scopesSupported: ["mcp:tools"]))
        }
        if requested.path.contains("oauth-authorization-server") {
            return try JSONEncoder().encode(AuthorizationServerMetadata(
                issuer: issuer,
                authorizationEndpoint: "\(issuer)/authorize",
                tokenEndpoint: token,
                registrationEndpoint: registrationEndpoint,
                codeChallengeMethodsSupported: challengeMethods,
                scopesSupported: ["mcp:tools"]))
        }
        throw MCPOAuthError.noAuthorizationServer
    }
}
