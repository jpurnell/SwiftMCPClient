import SwiftUI
import MCPClient
import SwiftOAuthCore
import SwiftOAuthClient
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif

/// Where the OAuth sign-in has got to.
enum OAuthState: Equatable {
    case signedOut
    /// The browser is open and the user has not come back yet.
    case awaitingBrowser
    case signedIn
    case failed(String)
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(server: String, version: String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum TransportType: String, CaseIterable, Identifiable {
    case httpSSE = "HTTP/SSE"
    case streamableHTTP = "Streamable HTTP"
    case webSocket = "WebSocket"
    case stdio = "stdio"

    var id: String { rawValue }

    /// Whether this transport speaks HTTP and can therefore carry a bearer credential.
    var usesHTTPCredentials: Bool {
        self == .httpSSE || self == .streamableHTTP
    }

    /// A representative URL, shown so a user can tell at a glance whether they have pasted
    /// the right endpoint for the transport they picked.
    var exampleURL: String {
        switch self {
        case .httpSSE: "https://mcp.example.com/sse"
        case .streamableHTTP: "https://mcp.example.com/mcp"
        case .webSocket: "wss://mcp.example.com/ws"
        case .stdio: ""
        }
    }
}

struct NotificationEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let notification: MCPNotification

    var summary: String {
        switch notification {
        case .progress(let p):
            return "Progress: \(p.progress)/\(p.total ?? 0)"
        case .logMessage(let msg):
            return "[\(msg.level.rawValue)] \(msg.logger ?? "server"): \(msg.data)"
        case .toolsListChanged:
            return "Tools list changed"
        case .resourcesListChanged:
            return "Resources list changed"
        case .resourceUpdated(let uri):
            return "Resource updated: \(uri)"
        case .promptsListChanged:
            return "Prompts list changed"
        }
    }
}

@Observable
@MainActor
final class MCPViewModel {
    private static let logger = os.Logger(subsystem: "MCPExplorer", category: "MCPViewModel")

    // Connection
    var serverURL: String = ""
    var bearerToken: String = "" // SECURITY: empty default, populated by user at runtime

    // OAuth. The session holds the credential; nothing here ever holds a code, a verifier or
    // a state, because those are what an application gets subtly wrong.
    private let oauthSession: MCPOAuthSession
    var oauthState: OAuthState = .signedOut

    /// Whether the credential will survive a restart.
    ///
    /// Surfaced rather than assumed. If the Keychain refuses — an unsigned build, a locked
    /// keychain — the app still works, but it will forget on quit, and a user who is not told
    /// that will read the next sign-in prompt as a bug.
    private(set) var credentialsPersist: Bool
    var stdioCommand: String = ""
    var stdioArguments: String = ""
    var transportType: TransportType = .httpSSE
    var trustSelfSignedCertificates: Bool = false
    var connectionState: ConnectionState = .disconnected
    var serverCapabilities: ServerCapabilities?

    // Discovery
    var tools: [MCPTool] = []
    var resources: [MCPResource] = []
    var resourceTemplates: [MCPResourceTemplate] = []
    var prompts: [MCPPrompt] = []

    // Tool calling
    var selectedTool: MCPTool?
    var toolArgumentsJSON: String = "{}"
    var toolResult: MCPToolResult?
    var toolCallInProgress: Bool = false

    // Resource reading
    var selectedResource: MCPResource?
    var resourceContents: [MCPResourceContents] = []
    var resourceReadInProgress: Bool = false

    // Prompts
    var selectedPrompt: MCPPrompt?
    var promptArguments: [String: String] = [:]
    var promptResult: MCPPromptResult?
    var promptGetInProgress: Bool = false

    // Notifications
    var notifications: [NotificationEntry] = []

    // Error display
    var lastError: String?

    private var client: MCPClientConnection?
    private var notificationTask: Task<Void, Never>? // lifecycle:exempt — cancelled in disconnect() and consumeNotifications()

    // MARK: - Connection

    func connect() async {
        guard !connectionState.isConnected else { return }
        connectionState = .connecting
        lastError = nil

        do {
            let transport: MCPTransport
            switch transportType {
            case .httpSSE, .streamableHTTP:
                // SECURITY: URL is user-provided configuration entered in the UI
                guard let url = URL(string: serverURL), !serverURL.isEmpty else {
                    connectionState = .error("Invalid URL")
                    return
                }
                var headers: [String: String] = [:]
                // A signed-in OAuth session wins over a pasted token: it refreshes, and a
                // token typed in by hand is the thing it replaces.
                if let header = try await oauthSession.authorizationHeader() {
                    headers["Authorization"] = header
                } else if !bearerToken.isEmpty {
                    headers["Authorization"] = "Bearer \(bearerToken)"
                }
                // Both are HTTP with the same credential; they differ in how the server
                // frames its side of the conversation, which is the transport's business.
                if transportType == .streamableHTTP {
                    transport = StreamableHTTPTransport(
                        url: url,
                        headers: headers,
                        trustSelfSignedCertificates: trustSelfSignedCertificates)
                } else {
                    transport = HTTPSSETransport(url: url, headers: headers, trustSelfSignedCertificates: trustSelfSignedCertificates)
                }

            case .webSocket:
                // SECURITY: URL is user-provided configuration entered in the UI
                guard let url = URL(string: serverURL), !serverURL.isEmpty else {
                    connectionState = .error("Invalid URL")
                    return
                }
                transport = WebSocketTransport(url: url)

            case .stdio:
                #if os(macOS) || os(Linux)
                let args = stdioArguments.split(separator: " ").map(String.init)
                transport = StdioTransport(command: stdioCommand, arguments: args)
                #else
                connectionState = .error("stdio not available on this platform")
                return
                #endif
            }

            let newClient = MCPClientConnection(transport: transport, requestTimeout: .seconds(30))
            let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
            let result = try await newClient.initialize(
                clientName: "MCPExplorer",
                clientVersion: "1.0.0",
                capabilities: caps
            )

            self.client = newClient
            self.serverCapabilities = result.capabilities
            connectionState = .connected(
                server: result.serverInfo.name,
                version: result.serverInfo.version
            )

            // Cancel any previous notification listener before starting a new one
            notificationTask?.cancel()
            notificationTask = Task { await consumeNotifications() }

            // Auto-discover
            await discover()

        } catch {
            connectionState = .error(String(describing: error))
            lastError = String(describing: error)
        }
    }

    func disconnect() async {
        notificationTask?.cancel()
        notificationTask = nil

        if let client {
            try? await client.disconnect() // silent: best-effort cleanup during disconnect
        }
        client = nil
        connectionState = .disconnected
        tools = []
        resources = []
        resourceTemplates = []
        prompts = []
        toolResult = nil
        resourceContents = []
        promptResult = nil
        serverCapabilities = nil
    }

    // MARK: - Discovery

    func discover() async {
        guard let client else { return }
        lastError = nil

        do { tools = try await client.listTools() }
        catch { tools = []; lastError = "listTools: \(error)"; Self.logger.error("listTools failed: \(error, privacy: .public)") }

        do { resources = try await client.listResources() }
        catch { resources = []; lastError = "listResources: \(error)"; Self.logger.error("listResources failed: \(error, privacy: .public)") }

        do { resourceTemplates = try await client.listResourceTemplates() }
        catch { resourceTemplates = []; lastError = "listResourceTemplates: \(error)"; Self.logger.error("listResourceTemplates failed: \(error, privacy: .public)") }

        do { prompts = try await client.listPrompts() }
        catch { prompts = []; lastError = "listPrompts: \(error)"; Self.logger.error("listPrompts failed: \(error, privacy: .public)") }
    }

    // MARK: - Tool Calling

    func callTool() async {
        guard let client, let tool = selectedTool else { return }
        toolCallInProgress = true
        toolResult = nil
        lastError = nil

        do {
            let arguments: [String: AnyCodableValue]
            if let data = toolArgumentsJSON.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) {
                arguments = parsed
            } else {
                arguments = [:]
            }

            toolResult = try await client.callTool(name: tool.name, arguments: arguments)
        } catch {
            lastError = "callTool: \(error)"
            Self.logger.error("callTool failed: \(error, privacy: .public)")
        }
        toolCallInProgress = false
    }

    // MARK: - Resource Reading

    func readResource() async {
        guard let client, let resource = selectedResource else { return }
        resourceReadInProgress = true
        resourceContents = []
        lastError = nil

        do {
            resourceContents = try await client.readResource(uri: resource.uri)
        } catch {
            lastError = "readResource: \(error)"
            Self.logger.error("readResource failed: \(error, privacy: .public)")
        }
        resourceReadInProgress = false
    }

    // MARK: - Prompts

    func getPrompt() async {
        guard let client, let prompt = selectedPrompt else { return }
        promptGetInProgress = true
        promptResult = nil
        lastError = nil

        do {
            promptResult = try await client.getPrompt(name: prompt.name, arguments: promptArguments)
        } catch {
            lastError = "getPrompt: \(error)"
            Self.logger.error("getPrompt failed: \(error, privacy: .public)")
        }
        promptGetInProgress = false
    }

    func selectPrompt(_ prompt: MCPPrompt) {
        selectedPrompt = prompt
        promptResult = nil
        // Pre-populate argument keys
        promptArguments = [:]
        for arg in prompt.arguments ?? [] {
            promptArguments[arg.name] = ""
        }
    }

    // MARK: - Ping

    func ping() async -> Bool {
        guard let client else { return false }
        do {
            return try await client.ping()
        } catch {
            lastError = "ping: \(error)"
            Self.logger.error("ping failed: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Notifications

    private func consumeNotifications() async {
        guard let client else { return }
        let stream = await client.notifications
        for await notification in stream {
            notifications.insert(
                NotificationEntry(timestamp: Date(), notification: notification),
                at: 0
            )
            // Cap at 200 entries
            if notifications.count > 200 {
                notifications = Array(notifications.prefix(200))
            }
        }
    }

    init() {
        // Persistent by default. Making a user authorise on every launch trains them to
        // click through consent screens without reading them, which is the opposite of what
        // consent screens are for.
        do {
            oauthSession = try MCPOAuthSession.persistent()
            credentialsPersist = true
        } catch {
            // Working-but-forgetful beats not starting. The banner in the UI is what keeps
            // this from being a silent downgrade.
            Self.logger.error(
                "credential storage unavailable, falling back to memory: \(String(describing: error), privacy: .public)")
            oauthSession = MCPOAuthSession(storage: InMemoryClientStorage())
            credentialsPersist = false
        }
    }

    // MARK: - OAuth

    /// Signs in to the MCP server named in `serverURL`.
    ///
    /// Everything that could be got wrong — the state, the PKCE verifier, the redirect port,
    /// the authorization code — stays inside `MCPOAuthSession`. This method's whole job is
    /// opening a browser and reporting what happened.
    func signInWithOAuth() async {
        // Parsed into components and checked before it becomes a URL. This string is typed
        // by hand into a text field and is about to name the host an OAuth flow runs
        // against; `https` is required because every secret in that flow crosses it.
        guard let components = URLComponents(string: serverURL),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            oauthState = .failed("Enter an https:// server URL first")
            return
        }

        oauthState = .awaitingBrowser
        do {
            try await oauthSession.signIn(
                server: url,
                clientName: "MCP Explorer",
                openURL: { authorizationURL in
                    #if os(macOS)
                    NSWorkspace.shared.open(authorizationURL)
                    #endif
                })
            oauthState = .signedIn
        } catch {
            Self.logger.error("OAuth sign-in failed: \(String(describing: error), privacy: .public)")
            oauthState = .failed(Self.describe(error))
        }
    }

    /// Forgets the credential, and revokes it where the server allows.
    func signOutOfOAuth() async {
        do {
            try await oauthSession.signOut()
        } catch {
            // The local credential is gone either way; a server that could not be reached
            // must not leave the app claiming to be signed in.
            Self.logger.error("Revocation failed: \(String(describing: error), privacy: .public)")
        }
        oauthState = .signedOut
    }

    /// Turns an error into something an operator can act on.
    ///
    /// Each of these has a different remedy, and a single "sign-in failed" would hide which.
    private static func describe(_ error: Error) -> String {
        switch error {
        case MCPOAuthError.noAuthorizationServer:
            return "This server does not advertise OAuth."
        case MCPOAuthError.registrationUnavailable:
            return "This server does not allow clients to register themselves."
        case MCPOAuthError.discovery(.pkceUnsupported):
            return "This server does not support PKCE, which is required."
        case MCPOAuthError.discovery(.endpointOutsideIssuer(let endpoint)):
            return "The server pointed sign-in at another host (\(endpoint)). Refused."
        case MCPOAuthError.discovery(.insecureEndpoint(let endpoint)):
            return "The server offered a non-HTTPS endpoint (\(endpoint)). Refused."
        case LoopbackError.timedOut:
            return "Timed out waiting for the browser."
        case CallbackError.stateMismatch:
            return "The sign-in response did not match this request. Refused."
        case CallbackError.provider(let oauthError):
            return oauthError.detail ?? oauthError.standardDescription
        default:
            return String(describing: error)
        }
    }
}
