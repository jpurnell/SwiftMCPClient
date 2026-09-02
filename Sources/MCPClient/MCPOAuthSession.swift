import Foundation
import Logging
import SwiftOAuthCore
import SwiftOAuthClient

/// Signs in to an MCP server and keeps the access token valid afterwards.
///
/// Wraps the whole sequence — discover, register, authorize, exchange — behind two calls, so
/// a caller never holds a code, a verifier or a state. Those exist only inside
/// ``signIn(server:clientName:tenant:openURL:)``, which is the point: every one of them is a
/// credential whose mishandling is invisible until someone is signed in to the wrong account.
///
/// After sign-in, ``authorizationHeader(forcingRefresh:)`` is the only thing a caller needs. It refreshes
/// when the token has expired, and a caller cannot forget to.
public actor MCPOAuthSession {

    private let setup: MCPOAuthSetup
    private let storage: any OAuthClientStorage
    private let registrations: any RegistrationRecordStore

    /// How token requests reach the provider.
    ///
    /// Injected for the same reason the Keychain is: the behaviour worth testing here is what
    /// happens when a token is exchanged, and a test that had to reach a provider to exercise
    /// it would not be run.
    private let tokenTransport: any TokenTransport
    private var connection: OAuthConnection?

    /// Which connection ``connection`` belongs to.
    ///
    /// Kept alongside it because signing out has to reach the stored registration, and a
    /// connection does not publish the identifier it was built with.
    private var connectionID: ConnectionID?

    /// Creates a session.
    ///
    /// - Parameters:
    ///   - setup: How discovery is performed. Injected for tests.
    ///   - storage: Where the credential lives.
    ///   - tokenTransport: How token requests reach the provider. Injected for tests.
    ///   - registrations: Where this client's registration with the server lives. Defaults to
    ///     memory, which is the behaviour of a session that cannot be resumed: a caller that
    ///     wants ``resume(server:tenant:)`` to work across launches has to say where the
    ///     registration is kept, because a credential outliving the registration that can use
    ///     it is worse than neither being stored.
    public init(
        setup: MCPOAuthSetup = MCPOAuthSetup(),
        storage: any OAuthClientStorage,
        registrations: any RegistrationRecordStore = InMemoryRegistrationStore(),
        tokenTransport: any TokenTransport = URLSessionTokenTransport()
    ) {
        self.setup = setup
        self.storage = storage
        self.registrations = registrations
        self.tokenTransport = tokenTransport
    }

    #if canImport(Security)
    /// Creates a session that keeps its credential across launches.
    ///
    /// The credential file is sealed with a key from the Keychain — one small key there, and
    /// everything else in a file beside the application's other state. Signing in again after
    /// every restart is the alternative, and it trains a user to click through consent
    /// screens without reading them.
    ///
    /// - Parameters:
    ///   - directory: Where the credential file lives. Defaults to the user's application
    ///     support directory.
    ///   - setup: How discovery is performed. Injected for tests.
    /// Available only where a Keychain is: the encrypted stores themselves are portable, but
    /// *where the key lives* is a platform decision and this convenience makes it. On Linux,
    /// construct the session directly with `EncryptedFileClientStorage` and
    /// ``EncryptedFileRegistrationStore``, supplying a key from whatever secret store that
    /// deployment already has — which is the decision this method takes on an Apple platform.
    ///
    /// - Returns: A session backed by encrypted storage.
    /// - Throws: ``CredentialKeyError`` if the Keychain refused, or a file error.
    public static func persistent(
        directory: URL? = nil,
        setup: MCPOAuthSetup = MCPOAuthSetup()
    ) throws -> MCPOAuthSession {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true).appending(path: "MCPExplorer")

        // One key for both files. They are worth the same to anyone who obtains one of them,
        // and a second key would double what can be lost without protecting anything further.
        let key = try CredentialStoreKey().loadOrCreate()

        return MCPOAuthSession(
            setup: setup,
            storage: try EncryptedFileClientStorage(
                url: base.appending(path: "credentials.enc"),
                key: key),
            registrations: try EncryptedFileRegistrationStore(
                url: base.appending(path: "registrations.enc"),
                key: key))
    }
    #endif

    /// Runs the whole flow and stores the resulting credential.
    ///
    /// The listener is bound **before** registration, because the redirect URI has to include
    /// its assigned port and the server records that URI at registration time. Registering
    /// first and binding after would register a port nothing is listening on.
    ///
    /// - Parameters:
    ///   - server: The MCP server's base URL.
    ///   - clientName: The name shown on the server's consent screen.
    ///   - tenant: Who this connection belongs to, in the application's terms.
    ///   - openURL: How to send the user to the authorization page. Injected so a test never
    ///     opens a browser.
    /// - Returns: The stored credential.
    /// - Throws: ``MCPOAuthError``, ``LoopbackError``, `CallbackError` or `OAuthError`.
    @discardableResult
    public func signIn(
        server: URL,
        clientName: String,
        tenant: String = "local",
        openURL: @Sendable (URL) -> Void
    ) async throws -> StoredCredential {
        let identifier = server.host() ?? "mcp"
        let (discovered, registrationEndpoint) = try await setup.discover(
            server: server, identifier: identifier)

        guard let registrationEndpoint else {
            throw MCPOAuthError.registrationUnavailable
        }

        let listener = LoopbackRedirectListener()
        let redirectURI = try await listener.start()
        // Every exit path closes it. An abandoned sign-in must not leave a socket bound and
        // accepting authorization codes.
        defer { Task { await listener.stop() } }

        let registration = try await register(
            at: registrationEndpoint,
            request: ClientRegistrationRequest(
                clientName: clientName,
                redirectUris: [redirectURI],
                scope: discovered.scope.isEmpty ? nil : discovered.scope))

        // The method has to match what was registered: presenting `client_secret_basic` with
        // no secret fails as `invalid_client`, which reads like wrong credentials rather than
        // like the wrong method.
        let configuration = ProviderConfiguration(
            identifier: discovered.identifier,
            authorizationEndpoint: discovered.authorizationEndpoint,
            tokenEndpoint: discovered.tokenEndpoint,
            revocationEndpoint: discovered.revocationEndpoint,
            scope: discovered.scope,
            authenticationMethod: registration.authenticationMethod)

        let id = ConnectionID(
            tenant: tenant, provider: identifier, account: server.absoluteString)
        let connection = OAuthConnection(
            configuration: configuration,
            credentials: registration.credentials(environment: identifier),
            storage: storage,
            connection: id,
            transport: tokenTransport)

        let begun = await connection.beginAuthorization(redirectURI: redirectURI)
        openURL(begun.url)

        let callback = try await listener.awaitCallback()
        let credential = try await connection.completeAuthorization(
            callback: callback, pending: begun.pending)

        self.connection = connection
        self.connectionID = id

        // Written only now that the exchange has succeeded. A record stored earlier would
        // describe a client that never obtained anything, and the next launch would rebuild a
        // connection around it and report a signed-in session with no credential behind it.
        do {
            try await registrations.store(registration, for: id)
        } catch {
            // Not rethrown. The sign-in *did* succeed, and failing it here would send the user
            // back through consent — registering a second client at the server on the way,
            // which is the accumulation this record exists to stop. What is lost is the next
            // launch's resume, which is exactly the behaviour before this record existed.
            let logger = Logger(label: "MCPClient.MCPOAuthSession")
            // logging: the reason the next launch will ask for consent again
            logger.error("the client registration could not be stored: \(error.localizedDescription)")
        }

        return credential
    }

    /// Rebuilds the signed-in state for a server whose credential and registration are both on
    /// file, without opening a browser.
    ///
    /// The registration is why this can exist. A refresh token is bound to the `client_id` that
    /// obtained it (RFC 6749 §6), so a client that registered again at every launch could never
    /// use the credential it already had — restoring means restoring *both* halves or neither.
    ///
    /// Endpoints are re-discovered rather than stored. They are public metadata, the round trip
    /// precedes a connection to the same server anyway, and a server that moves its token
    /// endpoint should not strand every client that cached the old one.
    ///
    /// - Parameters:
    ///   - server: The MCP server's base URL.
    ///   - tenant: Who the connection belongs to, in the application's terms.
    /// - Returns: `true` when the session is signed in again; `false` when nothing, or only
    ///   half, is stored — the caller should offer sign-in.
    /// - Throws: ``MCPOAuthError`` if discovery fails, or a storage error if a store exists and
    ///   cannot be read. A store that cannot be opened is deliberately not reported as `false`:
    ///   `false` sends the caller to a sign-in that would write a record over a file it could
    ///   not read.
    @discardableResult
    public func resume(server: URL, tenant: String = "local") async throws -> Bool {
        let identifier = server.host() ?? "mcp"
        let id = ConnectionID(
            tenant: tenant, provider: identifier, account: server.absoluteString)

        // Both halves are read before anything reaches the network. Discovery cannot change
        // the answer when either is missing, and a launch with nothing stored is the common
        // case — it should not cost a round trip to the server to find that out.
        guard let registration = try await registrations.record(for: id) else { return false }
        guard try await storage.credential(for: id) != nil else { return false }

        let (discovered, _) = try await setup.discover(server: server, identifier: identifier)

        // The *stored* authentication method, not one derived from what discovery returned.
        // It has to match what this client registered as: presenting `client_secret_basic`
        // with no secret fails as `invalid_client`, which reads like wrong credentials rather
        // than like the wrong method.
        let configuration = ProviderConfiguration(
            identifier: discovered.identifier,
            authorizationEndpoint: discovered.authorizationEndpoint,
            tokenEndpoint: discovered.tokenEndpoint,
            revocationEndpoint: discovered.revocationEndpoint,
            scope: discovered.scope,
            authenticationMethod: registration.authenticationMethod)

        self.connection = OAuthConnection(
            configuration: configuration,
            credentials: registration.credentials(environment: identifier),
            storage: storage,
            connection: id,
            transport: tokenTransport)
        self.connectionID = id
        return true
    }

    /// An `Authorization` header value that is valid now, refreshing if it is not.
    ///
    /// Two questions, one method. Ordinarily this asks for a token that is valid *by the
    /// clock*, and answers from the stored credential when it is — refreshing on every request
    /// would spend a rotation each time against a provider that rotates.
    ///
    /// `forcingRefresh` asks for a token obtained *now*, and is for the case the clock cannot
    /// see: the provider has stopped honouring a credential that has not expired here, because
    /// the grant was revoked, the clock drifted, or the dynamic client registration lapsed
    /// underneath it. The only evidence of any of those is a `401`, so this is the answer to a
    /// refusal and not something to call before sending.
    ///
    /// - Parameter forcingRefresh: Exchange regardless of what the stored expiry says.
    /// - Returns: The header value, or `nil` if this session has not signed in.
    /// - Throws: `ConnectionError` or `OAuthError` if the refresh was needed and failed.
    public func authorizationHeader(forcingRefresh: Bool = false) async throws -> String? {
        guard let connection else { return nil }
        let token = forcingRefresh
            ? try await connection.refreshedAccessToken()
            : try await connection.validAccessToken()
        return "Bearer \(token)"
    }

    /// Whether this session holds a credential.
    public var isSignedIn: Bool { connection != nil }

    /// Whether a credential for this server is already stored from a previous launch.
    ///
    /// Reported separately from ``isSignedIn`` because a stored credential is not yet a usable
    /// one: it still has to be refreshed, and the refresh can fail with the grant revoked.
    /// Telling a user "signed in" and then failing their first request is worse than asking.
    ///
    /// - Parameters:
    ///   - server: The MCP server.
    ///   - tenant: Who the connection belongs to.
    /// - Returns: `true` if a credential is on file.
    public func hasStoredCredential(server: URL, tenant: String = "local") async -> Bool {
        let identifier = server.host() ?? "mcp"
        let id = ConnectionID(
            tenant: tenant, provider: identifier, account: server.absoluteString)
        // An unreadable store and an empty one mean the same thing to a caller deciding
        // whether to offer a sign-in button: offer it.
        // silent: both outcomes lead to the same UI, and the store logs its own reason
        let stored = try? await storage.credential(for: id)
        return stored != nil
    }

    /// Forgets the credential and the registration, and revokes the credential where the
    /// server allows.
    ///
    /// The registration goes too. It carries a `client_secret`, and a secret that outlives the
    /// session it belonged to is one nothing will ever come back to remove.
    ///
    /// - Throws: `ConnectionError` if revocation failed, or a storage error if the registration
    ///   could not be removed — an erasure that did not happen is reported, not assumed.
    public func signOut() async throws {
        try await connection?.disconnect()
        if let connectionID {
            try await registrations.remove(connectionID)
        }
        connection = nil
        connectionID = nil
    }

    /// Registers this client with the authorization server.
    private func register(
        at endpoint: URL,
        request: ClientRegistrationRequest
    ) async throws -> ClientRegistrationResponse {
        var httpRequest = URLRequest(url: endpoint)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        httpRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.serverError("the registration response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The server explains itself in the body; the status alone does not distinguish
            // "we do not allow registration" from "your redirect URI is unacceptable".
            if let error = try? JSONDecoder().decode(OAuthError.self, from: data) {
                throw error
            }
            throw OAuthError.serverError("registration failed: HTTP \(http.statusCode)")
        }
        // Read before decoding, because decoding discards it: `ClientRegistrationResponse`
        // does not model `client_secret_expires_at`, and this is the only moment the value
        // exists. A registration that expires otherwise does so invisibly, surfacing weeks
        // later as a refresh failing `invalid_client` with nothing to connect it to.
        let logger = Logger(label: "MCPClient.MCPOAuthSession")
        // logging: the registration lifetime, observable exactly once and otherwise lost
        logger.info("registered at \(endpoint.host() ?? "the server"): \(RegistrationLifetime.expiry(from: data))")

        return try JSONDecoder().decode(ClientRegistrationResponse.self, from: data)
    }
}
