import SwiftUI
import MCPClient
import os

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
    case webSocket = "WebSocket"
    case stdio = "stdio"

    var id: String { rawValue }
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
            case .httpSSE:
                // SECURITY: URL is user-provided configuration entered in the UI
                guard let url = URL(string: serverURL), !serverURL.isEmpty else {
                    connectionState = .error("Invalid URL")
                    return
                }
                var headers: [String: String] = [:]
                if !bearerToken.isEmpty {
                    headers["Authorization"] = "Bearer \(bearerToken)"
                }
                transport = HTTPSSETransport(url: url, headers: headers, trustSelfSignedCertificates: trustSelfSignedCertificates)

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
}
