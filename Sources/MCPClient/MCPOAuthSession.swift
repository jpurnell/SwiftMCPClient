import Foundation
import SwiftOAuthCore
import SwiftOAuthClient

/// Signs in to an MCP server and keeps the access token valid afterwards.
///
/// Wraps the whole sequence — discover, register, authorize, exchange — behind two calls, so
/// a caller never holds a code, a verifier or a state. Those exist only inside
/// ``signIn(server:clientName:tenant:openURL:)``, which is the point: every one of them is a
/// credential whose mishandling is invisible until someone is signed in to the wrong account.
///
/// After sign-in, ``authorizationHeader()`` is the only thing a caller needs. It refreshes
/// when the token has expired, and a caller cannot forget to.
public actor MCPOAuthSession {

    private let setup: MCPOAuthSetup
    private let storage: any OAuthClientStorage
    private var connection: OAuthConnection?

    /// Creates a session.
    ///
    /// - Parameters:
    ///   - setup: How discovery is performed. Injected for tests.
    ///   - storage: Where the credential lives.
    public init(
        setup: MCPOAuthSetup = MCPOAuthSetup(),
        storage: any OAuthClientStorage
    ) {
        self.setup = setup
        self.storage = storage
    }

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

        return MCPOAuthSession(
            setup: setup,
            storage: try EncryptedFileClientStorage(
                url: base.appending(path: "credentials.enc"),
                key: try CredentialStoreKey.loadOrCreate()))
    }

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

        let connection = OAuthConnection(
            configuration: configuration,
            credentials: registration.credentials(environment: identifier),
            storage: storage,
            connection: ConnectionID(
                tenant: tenant, provider: identifier, account: server.absoluteString))

        let begun = await connection.beginAuthorization(redirectURI: redirectURI)
        openURL(begun.url)

        let callback = try await listener.awaitCallback()
        let credential = try await connection.completeAuthorization(
            callback: callback, pending: begun.pending)

        self.connection = connection
        return credential
    }

    /// An `Authorization` header value that is valid now, refreshing if it is not.
    ///
    /// - Returns: The header value, or `nil` if this session has not signed in.
    /// - Throws: `ConnectionError` or `OAuthError` if a refresh was needed and failed.
    public func authorizationHeader() async throws -> String? {
        guard let connection else { return nil }
        return "Bearer \(try await connection.validAccessToken())"
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

    /// Forgets the credential, and revokes it where the server allows.
    public func signOut() async throws {
        try await connection?.disconnect()
        connection = nil
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
        return try JSONDecoder().decode(ClientRegistrationResponse.self, from: data)
    }
}
