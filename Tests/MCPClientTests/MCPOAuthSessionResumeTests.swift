import Foundation
import Testing
import Crypto
import SwiftOAuthCore
import SwiftOAuthClient
@testable import MCPClient

/// Restoring a signed-in session from what is on disk.
///
/// The property being protected is the one a user notices: a second launch does not open a
/// browser. The property being protected *underneath* it is the one they would not notice
/// until later — that restoring never registers the client again. A new registration issues a
/// new `client_id`, and the refresh token already on file is bound to the old one (RFC 6749
/// §6), so a resume that re-registered would appear to work and then fail at the first refresh
/// with `invalid_client`.
@Suite("MCP OAuth session — resume")
struct MCPOAuthSessionResumeTests {

    /// The golden path: both halves on file, and a header comes back without a browser.
    @Test("A stored registration and credential restore a usable header")
    func resumesFromStorage() async throws {
        let storage = InMemoryClientStorage()
        try await storage.store(storedCredential(), for: storedConnection())
        let registrations = InMemoryRegistrationStore()
        try await registrations.store(storedRegistration(), for: storedConnection())

        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch()),
            storage: storage,
            registrations: registrations)

        let resumed = try await session.resume(server: resumeServerURL())

        #expect(resumed, "a session with both halves stored did not restore")
        #expect(await session.isSignedIn)
        #expect(try await session.authorizationHeader() == "Bearer stored-access-token")
    }

    /// The one that would not show up until the first refresh. Resume re-discovers endpoints —
    /// public metadata, and cheap — but must never touch the registration endpoint.
    @Test("Resume never registers the client again")
    func resumeNeverRegisters() async throws {
        let storage = InMemoryClientStorage()
        try await storage.store(storedCredential(), for: storedConnection())
        let registrations = InMemoryRegistrationStore()
        try await registrations.store(storedRegistration(), for: storedConnection())

        let requested = RequestedURLs()
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch(recordingInto: requested)),
            storage: storage,
            registrations: registrations)

        _ = try await session.resume(server: resumeServerURL())

        let urls = await requested.urls
        #expect(
            urls.allSatisfy { !$0.path.contains("register") },
            "resume reached the registration endpoint; the stored refresh token is now orphaned")
        #expect(!urls.isEmpty, "endpoints were not re-discovered")
    }

    /// An account from before registrations were persisted: the credential is there, the
    /// registration is not. Nothing can be rebuilt, and the caller has to offer sign-in — but
    /// this is an ordinary answer, not a failure.
    @Test("A credential with no stored registration does not resume")
    func credentialWithoutRegistration() async throws {
        let storage = InMemoryClientStorage()
        try await storage.store(storedCredential(), for: storedConnection())

        let requested = RequestedURLs()
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch(recordingInto: requested)),
            storage: storage,
            registrations: InMemoryRegistrationStore())

        #expect(try await session.resume(server: resumeServerURL()) == false)
        #expect(await session.isSignedIn == false)
        #expect(await requested.urls.isEmpty, "the network was reached for a resume that cannot succeed")
    }

    /// The mirror image: a registration whose credential has been signed out or expired away.
    /// Rebuilding a connection around it would report a signed-in session whose first request
    /// fails.
    @Test("A registration with no stored credential does not resume")
    func registrationWithoutCredential() async throws {
        let registrations = InMemoryRegistrationStore()
        try await registrations.store(storedRegistration(), for: storedConnection())

        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch()),
            storage: InMemoryClientStorage(),
            registrations: registrations)

        #expect(try await session.resume(server: resumeServerURL()) == false)
        #expect(await session.isSignedIn == false)
    }

    /// A first launch. `false`, without a network round trip — there is nothing discovery
    /// could tell this session that would change the answer.
    @Test("Nothing stored does not resume, and does not reach the network")
    func nothingStored() async throws {
        let requested = RequestedURLs()
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch(recordingInto: requested)),
            storage: InMemoryClientStorage(),
            registrations: InMemoryRegistrationStore())

        #expect(try await session.resume(server: resumeServerURL()) == false)
        #expect(await requested.urls.isEmpty)
    }

    /// A store that cannot be opened must not arrive as `false`. `false` means "sign in
    /// again", and signing in again over a broken store writes a new registration the store
    /// cannot read either — the caller needs to be able to tell the two apart.
    @Test("A registration store that cannot be opened throws rather than reporting nothing")
    func brokenStoreThrows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MCPOAuthSessionResumeTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // silent: a cleanup failure must not be reported as this test failing
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "registrations.enc")
        let key = SymmetricKey(size: .bits256)
        let written = try EncryptedFileRegistrationStore(url: file, key: key)
        try await written.store(storedRegistration(), for: storedConnection())

        let sealed = try Data(contentsOf: file)
        try sealed.prefix(sealed.count / 2).write(to: file, options: [.atomic])

        let storage = InMemoryClientStorage()
        try await storage.store(storedCredential(), for: storedConnection())
        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch()),
            storage: storage,
            registrations: try EncryptedFileRegistrationStore(url: file, key: key))

        await #expect(throws: StorageError.cannotDecrypt) {
            try await session.resume(server: resumeServerURL())
        }
    }

    /// Sign-in has to leave behind what resume needs, or the feature works only in tests.
    /// Asserted at the store rather than through a full flow, which would need a browser.
    @Test("A session with no registration on file reports nothing stored for it")
    func storedRegistrationIsReadBack() async throws {
        let registrations = InMemoryRegistrationStore()
        #expect(try await registrations.record(for: storedConnection()) == nil)

        try await registrations.store(storedRegistration(), for: storedConnection())
        let read = try await registrations.record(for: storedConnection())

        #expect(read?.clientId == "stored-client")
    }
}

// MARK: - Helpers

/// The server every fixture here is filed under.
private func resumeServerURL() -> URL {
    URL(string: "https://mcp.example.com") ?? URL(fileURLWithPath: "/")
}

/// The connection the stored halves belong to — the same identity `signIn` files them under.
private func storedConnection() -> ConnectionID {
    ConnectionID(
        tenant: "local", provider: "mcp.example.com", account: "https://mcp.example.com")
}

/// A registration as a server issued it on some earlier launch.
private func storedRegistration() -> ClientRegistrationResponse {
    ClientRegistrationResponse(
        clientId: "stored-client",
        clientSecret: "stored-secret",
        clientName: "Test Client",
        redirectUris: ["http://127.0.0.1:49152/callback"])
}

/// A credential with an hour left on it, so restoring it needs no refresh and therefore no
/// token endpoint.
private func storedCredential() -> StoredCredential {
    let anchor = Date(timeIntervalSince1970: 1_756_684_800)
    return StoredCredential(
        accessToken: "stored-access-token",
        refreshToken: "stored-refresh-token",
        accessExpiry: Date().addingTimeInterval(3600),
        refreshExpiry: nil,
        previousRefreshToken: nil,
        rotatedAt: anchor,
        scope: "mcp:tools")
}

/// Records what a flow asked the network for, so a test can assert what it did not ask for.
private actor RequestedURLs {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

/// Serves canned discovery documents, optionally recording what was requested.
private func metadataFetch(
    recordingInto recorder: RequestedURLs? = nil,
    issuer: String = "https://auth.example.com"
) -> MCPOAuthSetup.Fetch {
    { requested in
        await recorder?.record(requested)

        if requested.path.contains("oauth-protected-resource") {
            return try JSONEncoder().encode(ProtectedResourceMetadata(
                resource: "https://mcp.example.com",
                authorizationServers: [issuer],
                scopesSupported: ["mcp:tools"]))
        }
        if requested.path.contains("oauth-authorization-server") {
            return try JSONEncoder().encode(AuthorizationServerMetadata(
                issuer: issuer,
                authorizationEndpoint: "\(issuer)/authorize",
                tokenEndpoint: "\(issuer)/token",
                registrationEndpoint: "\(issuer)/register",
                codeChallengeMethodsSupported: ["S256"],
                scopesSupported: ["mcp:tools"]))
        }
        throw MCPOAuthError.noAuthorizationServer
    }
}

@Suite("MCP OAuth session — signing out")
struct MCPOAuthSignOutTests {

    /// A registration carries a `client_secret`. Signing out has to take it with it, or the
    /// secret outlives the session it belonged to and sits on disk indefinitely.
    @Test("Signing out forgets the stored registration")
    func signOutForgetsRegistration() async throws {
        let storage = InMemoryClientStorage()
        try await storage.store(storedCredential(), for: storedConnection())
        let registrations = InMemoryRegistrationStore()
        try await registrations.store(storedRegistration(), for: storedConnection())

        let session = MCPOAuthSession(
            setup: MCPOAuthSetup(fetch: metadataFetch()),
            storage: storage,
            registrations: registrations)

        #expect(try await session.resume(server: resumeServerURL()))
        try await session.signOut()

        #expect(try await registrations.record(for: storedConnection()) == nil,
                "the client secret is still on disk after signing out")
        #expect(await session.isSignedIn == false)
    }

    /// Signing out of a session that never signed in still must not fail — nothing to forget
    /// is not an error, and a user pressing it twice should not see one.
    @Test("Signing out with nothing stored is harmless")
    func signOutWithNothingStored() async throws {
        let session = MCPOAuthSession(
            storage: InMemoryClientStorage(),
            registrations: InMemoryRegistrationStore())

        try await session.signOut()
        #expect(await session.isSignedIn == false)
    }
}

/// Asking the session for a token it must obtain now.
///
/// The distinction the transport depends on. An ordinary header request is answered from the
/// stored credential whenever the clock says it is still good; a forced one exchanges anyway,
/// because a grant the provider has revoked looks perfectly valid to every clock on this side.
@Suite("MCP OAuth session — forced refresh")
struct MCPOAuthSessionForcedRefreshTests {

    /// The ordinary path must not exchange for a credential that is still valid. If it did,
    /// every request would spend a rotation.
    @Test("An ordinary header request does not exchange")
    func ordinaryRequestDoesNotExchange() async throws {
        let exchanges = ExchangeLog()
        let session = try await resumedSession(exchanges: exchanges)

        #expect(try await session.authorizationHeader() == "Bearer stored-access-token")
        #expect(await exchanges.count == 0)
    }

    /// The forced path exchanges even though the stored token has an hour left, and hands
    /// back what the provider issued rather than what was on file.
    @Test("A forced header request exchanges and returns the new token")
    func forcedRequestExchanges() async throws {
        let exchanges = ExchangeLog()
        let session = try await resumedSession(exchanges: exchanges)

        let header = try await session.authorizationHeader(forcingRefresh: true)

        #expect(header == "Bearer refreshed-access-token")
        #expect(await exchanges.count == 1, "forcing a refresh did not reach the provider")
        #expect(await exchanges.grantTypes == ["refresh_token"])
    }

    /// Forcing a refresh on a session that never signed in is `nil`, not an exchange against
    /// a connection that does not exist.
    @Test("Forcing a refresh while signed out yields no header")
    func forcedRequestWhileSignedOut() async throws {
        let session = MCPOAuthSession(
            storage: InMemoryClientStorage(),
            registrations: InMemoryRegistrationStore())

        #expect(try await session.authorizationHeader(forcingRefresh: true) == nil)
    }
}

// MARK: - Forced-refresh helpers

/// A session resumed from storage, with the provider stubbed.
private func resumedSession(exchanges: ExchangeLog) async throws -> MCPOAuthSession {
    let storage = InMemoryClientStorage()
    try await storage.store(storedCredential(), for: storedConnection())
    let registrations = InMemoryRegistrationStore()
    try await registrations.store(storedRegistration(), for: storedConnection())

    let session = MCPOAuthSession(
        setup: MCPOAuthSetup(fetch: metadataFetch()),
        storage: storage,
        registrations: registrations,
        tokenTransport: StubTokenTransport(log: exchanges))

    _ = try await session.resume(server: resumeServerURL())
    return session
}

/// What the provider was asked for.
private actor ExchangeLog {
    private(set) var grantTypes: [String] = []
    var count: Int { grantTypes.count }
    func record(_ grantType: String?) { grantTypes.append(grantType ?? "") }
}

/// A token endpoint that answers without a network.
private struct StubTokenTransport: TokenTransport {
    let log: ExchangeLog

    func exchange(
        endpoint: URL,
        parameters: [String: String],
        credentials: ClientCredentials,
        method: ClientAuthenticationMethod
    ) async throws -> TokenResponse {
        await log.record(parameters["grant_type"])
        return TokenResponse(
            accessToken: "refreshed-access-token",
            tokenType: "Bearer",
            expiresIn: 3_600,
            refreshToken: "rotated-refresh-token",
            scope: "mcp:tools")
    }
}
