import Foundation

/// An actor that manages communication with an MCP server.
///
/// `MCPClientConnection` handles the full MCP protocol lifecycle: initialization,
/// tool discovery, and tool invocation. It uses a pluggable ``MCPTransport``
/// for the underlying communication — ``HTTPSSETransport`` for remote servers
/// or ``StdioTransport`` for local development.
///
/// ## Usage
///
/// ```swift
/// let transport = HTTPSSETransport(
///     url: URL(string: "https://my-mcp-server.example.com/sse")!
/// )
/// let client = MCPClientConnection(transport: transport)
///
/// // 1. Initialize the connection
/// let info = try await client.initialize(
///     clientName: "my-app",
///     clientVersion: "1.0.0"
/// )
/// print("Connected to \(info.serverInfo.name)")
///
/// // 2. Discover available tools
/// let tools = try await client.listTools()
/// for tool in tools {
///     print("  - \(tool.name): \(tool.description ?? "")")
/// }
///
/// // 3. Call a tool
/// let result = try await client.callTool(
///     name: "analyze_data",
///     arguments: ["input": .string("Hello, world!")]
/// )
/// print(result.content.first?.text ?? "No output")
/// ```
///
/// ## Notifications
///
/// After initialization, server-to-client notifications (progress updates,
/// log messages, list changes) are available via the ``notifications`` stream:
///
/// ```swift
/// for await notification in client.notifications {
///     switch notification {
///     case .progress(let p):
///         print("Progress: \(p.progress)/\(p.total ?? 0)")
///     case .logMessage(let msg):
///         print("[\(msg.level)] \(msg.data)")
///     default:
///         break
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// `MCPClientConnection` is an `actor`, so all method calls are serialized.
/// Request IDs are auto-incremented and guaranteed unique within a connection.
public actor MCPClientConnection: MCPClientProtocol {
    private let transport: MCPTransport
    private let requestTimeout: Duration
    private var nextRequestID: Int = 1
    private var isConnected: Bool = false
    private var dispatcher: MCPMessageDispatcher?
    private var rootsHandler: (@Sendable () async -> [MCPRoot])?
    private var samplingHandler: SamplingHandler?

    /// Stream of server-to-client notifications.
    ///
    /// This stream becomes active after ``initialize(clientName:clientVersion:)``
    /// is called and the message dispatcher starts. It yields notifications for
    /// progress updates, log messages, and list changes from the server.
    public var notifications: AsyncStream<MCPNotification> {
        if let dispatcher {
            return dispatcher.notificationStream
        }
        // Return an empty stream if not initialized yet
        return AsyncStream { $0.finish() }
    }

    /// Creates a new MCP client connection with the given transport.
    ///
    /// The transport is not connected until ``initialize(clientName:clientVersion:)``
    /// is called.
    ///
    /// - Parameters:
    ///   - transport: The transport to use for communication.
    ///   - requestTimeout: Maximum time to wait for a response. Defaults to 30 seconds.
    public init(transport: MCPTransport, requestTimeout: Duration = .seconds(30)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    /// Initialize the MCP connection, performing the protocol handshake.
    ///
    /// This method connects the transport (if not already connected), sends the
    /// MCP `initialize` request with the client's identity, waits for the server's
    /// response, then sends the required `notifications/initialized` notification.
    /// After the handshake, it starts the message dispatcher for bidirectional
    /// communication.
    ///
    /// This must be called before ``listTools()`` or ``callTool(name:arguments:)``.
    ///
    /// - Parameters:
    ///   - clientName: The name of this client application.
    ///   - clientVersion: The version of this client application.
    ///   - protocolVersion: The MCP protocol version to request. Defaults to `"2024-11-05"`.
    /// - Returns: The server's initialization result including capabilities.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport cannot connect.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server rejects the handshake.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func initialize(
        clientName: String,
        clientVersion: String,
        capabilities: ClientCapabilities = ClientCapabilities(),
        protocolVersion: String = "2024-11-05"
    ) async throws -> InitializeResult {
        if !isConnected {
            try await transport.connect()
            isConnected = true
        }

        // Encode client capabilities to AnyCodableValue
        let capsData = try JSONEncoder().encode(capabilities)
        let capsValue = try JSONDecoder().decode(AnyCodableValue.self, from: capsData)

        let params = AnyCodableValue.object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": capsValue,
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])

        // Initialize uses direct transport.receive() since the dispatcher
        // isn't running yet and no notifications can arrive before handshake.
        let response = try await sendRequestDirect(method: "initialize", params: params)
        let resultData = try JSONEncoder().encode(response)
        let initResult = try JSONDecoder().decode(InitializeResult.self, from: resultData)

        // The MCP spec says the server responds with the version it supports.
        // We accept any version — the protocol is designed to be forward-compatible
        // at the JSON-RPC level. Log but don't reject newer versions.

        // Send notifications/initialized per MCP spec (fire-and-forget, no response)
        let notification = JSONRPCNotification(method: "notifications/initialized")
        let notificationData = try JSONEncoder().encode(notification)
        try await transport.send(notificationData)

        // Start the message dispatcher for all subsequent communication
        let newDispatcher = MCPMessageDispatcher(transport: transport)
        await newDispatcher.start()
        self.dispatcher = newDispatcher

        return initResult
    }

    /// Discover available tools on the MCP server.
    ///
    /// Sends a `tools/list` request and decodes the response into an array
    /// of ``MCPTool`` definitions. Automatically paginates if the server
    /// returns a `nextCursor`. Returns an empty array if the server reports no tools.
    ///
    /// - Returns: An array of all tool definitions available on the server.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func listTools() async throws -> [MCPTool] {
        try await paginatedList(method: "tools/list", key: "tools")
    }

    /// Send a ping to the MCP server and await the response.
    ///
    /// Sends a `ping` request per the MCP specification. The server must
    /// respond with an empty result object `{}`.
    ///
    /// - Returns: `true` if the server responded successfully.
    /// - Throws: ``MCPError/timeout`` if no response within the transport timeout.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is disconnected.
    public func ping() async throws -> Bool {
        _ = try await sendRequest(method: "ping", params: nil)
        return true
    }

    /// Call a tool on the MCP server.
    ///
    /// Sends a `tools/call` request with the given tool name and arguments,
    /// then decodes the response into an ``MCPToolResult``. Check the result's
    /// ``MCPToolResult/isError`` property to determine if the tool execution
    /// itself reported a failure.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call (must match a name from ``listTools()``).
    ///   - arguments: The arguments to pass to the tool. Defaults to empty.
    /// - Returns: The tool's result containing one or more content blocks.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func callTool(name: String, arguments: [String: AnyCodableValue] = [:]) async throws -> MCPToolResult {
        try await callTool(name: name, arguments: arguments, progressToken: nil)
    }

    /// Call a tool on the MCP server with an optional progress token.
    ///
    /// When `progressToken` is provided, it is included as `_meta.progressToken`
    /// in the request, enabling the server to send progress notifications for
    /// this specific request.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call (must match a name from ``listTools()``).
    ///   - arguments: The arguments to pass to the tool. Defaults to empty.
    ///   - progressToken: Optional token for receiving progress notifications.
    /// - Returns: The tool's result containing one or more content blocks.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func callTool(
        name: String,
        arguments: [String: AnyCodableValue] = [:],
        progressToken: AnyCodableValue?
    ) async throws -> MCPToolResult {
        var paramsDict: [String: AnyCodableValue] = [
            "name": .string(name),
            "arguments": .object(arguments)
        ]
        if let progressToken {
            paramsDict["_meta"] = .object(["progressToken": progressToken])
        }
        let params = AnyCodableValue.object(paramsDict)

        let response = try await sendRequest(method: "tools/call", params: params)
        let resultData = try JSONEncoder().encode(response)
        let toolResult = try JSONDecoder().decode(MCPToolResult.self, from: resultData)
        return toolResult
    }

    // MARK: - Typed Notification Streams

    /// Stream of progress notifications only.
    ///
    /// Filters the underlying ``notifications`` stream, yielding only
    /// ``MCPProgressNotification`` values. The stream ends when the
    /// connection is disconnected.
    public var progressUpdates: AsyncStream<MCPProgressNotification> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .progress(let p) = notification {
                        continuation.yield(p)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Stream of log messages only.
    ///
    /// Filters the underlying ``notifications`` stream, yielding only
    /// ``MCPLogMessage`` values.
    public var logMessages: AsyncStream<MCPLogMessage> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .logMessage(let msg) = notification {
                        continuation.yield(msg)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Stream of tool list change events.
    ///
    /// Yields `Void` each time the server notifies that its tool list has changed.
    public var toolListChanges: AsyncStream<Void> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .toolsListChanged = notification {
                        continuation.yield(())
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Stream of resource update events.
    ///
    /// Yields the URI string of each resource that the server notifies has been updated.
    public var resourceUpdates: AsyncStream<String> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .resourceUpdated(let uri) = notification {
                        continuation.yield(uri)
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Lifecycle

    /// Gracefully shut down the connection.
    ///
    /// Stops the message dispatcher (cancels the background read loop, fails
    /// any pending requests with ``MCPError/transportClosed``, finishes the
    /// notification stream), then disconnects the transport.
    ///
    /// After calling `disconnect()`, all subsequent method calls will throw.
    /// To reconnect, create a new ``MCPClientConnection`` instance.
    public func disconnect() async throws {
        if let dispatcher {
            await dispatcher.stop()
            self.dispatcher = nil
        }
        if isConnected {
            try await transport.disconnect()
            isConnected = false
        }
    }

    // MARK: - Resources

    /// Discover available resources on the MCP server.
    ///
    /// Sends a `resources/list` request and auto-paginates if the server
    /// returns a `nextCursor`. Returns an empty array if no resources are available.
    ///
    /// - Returns: An array of all resource definitions.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func listResources() async throws -> [MCPResource] {
        try await paginatedList(method: "resources/list", key: "resources")
    }

    /// Discover available resource templates on the MCP server.
    ///
    /// Sends a `resources/templates/list` request and auto-paginates.
    ///
    /// - Returns: An array of all resource template definitions.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await paginatedList(method: "resources/templates/list", key: "resourceTemplates")
    }

    /// Read the contents of a resource by URI.
    ///
    /// Sends a `resources/read` request. A single URI may return multiple
    /// sub-resources (e.g., a directory listing).
    ///
    /// - Parameter uri: The resource URI to read.
    /// - Returns: An array of resource contents (text or blob).
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the resource is not found.
    public func readResource(uri: String) async throws -> [MCPResourceContents] {
        let params = AnyCodableValue.object(["uri": .string(uri)])
        let response = try await sendRequest(method: "resources/read", params: params)

        guard case .object(let resultObj) = response,
              case .array(let contentValues) = resultObj["contents"] else {
            return []
        }

        let contentsData = try JSONEncoder().encode(AnyCodableValue.array(contentValues))
        return try JSONDecoder().decode([MCPResourceContents].self, from: contentsData)
    }

    /// Subscribe to updates for a specific resource.
    ///
    /// Sends a `resources/subscribe` request. After subscribing, the server
    /// may send `notifications/resources/updated` when the resource changes.
    ///
    /// - Parameter uri: The resource URI to subscribe to.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func subscribeResource(uri: String) async throws {
        let params = AnyCodableValue.object(["uri": .string(uri)])
        _ = try await sendRequest(method: "resources/subscribe", params: params)
    }

    /// Unsubscribe from updates for a specific resource.
    ///
    /// - Parameter uri: The resource URI to unsubscribe from.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func unsubscribeResource(uri: String) async throws {
        let params = AnyCodableValue.object(["uri": .string(uri)])
        _ = try await sendRequest(method: "resources/unsubscribe", params: params)
    }

    // MARK: - Prompts

    /// Discover available prompts on the MCP server.
    ///
    /// Sends a `prompts/list` request and auto-paginates if the server
    /// returns a `nextCursor`.
    ///
    /// - Returns: An array of all prompt definitions.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func listPrompts() async throws -> [MCPPrompt] {
        try await paginatedList(method: "prompts/list", key: "prompts")
    }

    /// Get an expanded prompt by name with optional arguments.
    ///
    /// Sends a `prompts/get` request with the given name and string-valued
    /// arguments. Returns the prompt expanded into a sequence of messages.
    ///
    /// - Parameters:
    ///   - name: The prompt name (must match a name from ``listPrompts()``).
    ///   - arguments: String-valued arguments to fill prompt template placeholders.
    /// - Returns: The prompt result containing messages.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func getPrompt(name: String, arguments: [String: String] = [:]) async throws -> MCPPromptResult {
        var paramsDict: [String: AnyCodableValue] = ["name": .string(name)]
        if !arguments.isEmpty {
            let argsObject = AnyCodableValue.object(
                arguments.mapValues { AnyCodableValue.string($0) }
            )
            paramsDict["arguments"] = argsObject
        }

        let response = try await sendRequest(method: "prompts/get", params: .object(paramsDict))
        let resultData = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(MCPPromptResult.self, from: resultData)
    }

    // MARK: - Logging

    /// Set the minimum log level for server log messages.
    ///
    /// Sends a `logging/setLevel` request. After this call, the server should
    /// only send `notifications/message` at or above the specified severity.
    ///
    /// - Parameter level: The minimum log level to receive.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func setLogLevel(_ level: MCPLogLevel) async throws {
        let params = AnyCodableValue.object(["level": .string(level.rawValue)])
        _ = try await sendRequest(method: "logging/setLevel", params: params)
    }

    // MARK: - Cancellation

    /// Cancel an in-flight request by ID.
    ///
    /// Sends a `notifications/cancelled` notification to the server. The server
    /// SHOULD stop processing the request and NOT send a response.
    ///
    /// - Parameters:
    ///   - id: The request ID to cancel.
    ///   - reason: Optional human-readable reason for cancellation.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is not connected.
    public func cancelRequest(id: Int, reason: String? = nil) async throws {
        var paramsDict: [String: AnyCodableValue] = ["requestId": .integer(id)]
        if let reason {
            paramsDict["reason"] = .string(reason)
        }
        let notification = JSONRPCNotification(
            method: "notifications/cancelled",
            params: .object(paramsDict)
        )
        let data = try JSONEncoder().encode(notification)
        try await transport.send(data)
    }

    // MARK: - Completion

    /// Request autocompletion suggestions for a prompt or resource argument.
    ///
    /// Sends a `completion/complete` request to the server with a reference
    /// to what is being completed and the current argument value.
    ///
    /// - Parameters:
    ///   - ref: The prompt or resource being completed against.
    ///   - argumentName: The name of the argument being completed.
    ///   - argumentValue: The current partial value to match against.
    /// - Returns: The completion result with suggested values.
    /// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
    public func complete(
        ref: MCPCompletionRef,
        argumentName: String,
        argumentValue: String
    ) async throws -> MCPCompletionResult {
        let refValue: AnyCodableValue
        switch ref {
        case .prompt(let name):
            refValue = .object(["type": .string("ref/prompt"), "name": .string(name)])
        case .resource(let uri):
            refValue = .object(["type": .string("ref/resource"), "uri": .string(uri)])
        }

        let params = AnyCodableValue.object([
            "ref": refValue,
            "argument": .object([
                "name": .string(argumentName),
                "value": .string(argumentValue)
            ])
        ])

        let response = try await sendRequest(method: "completion/complete", params: params)

        guard case .object(let resultObj) = response,
              let completionValue = resultObj["completion"] else {
            throw MCPError.invalidResponse
        }

        let completionData = try JSONEncoder().encode(completionValue)
        return try JSONDecoder().decode(MCPCompletionResult.self, from: completionData)
    }

    // MARK: - Roots

    /// Register a handler that responds to `roots/list` requests from the server.
    ///
    /// When the server sends a `roots/list` request, the handler is called and
    /// its return value is sent back as the response.
    ///
    /// - Parameter handler: A closure that returns the current list of roots.
    public func setRootsHandler(_ handler: @Sendable @escaping () async -> [MCPRoot]) async {
        self.rootsHandler = handler
        await updateIncomingRequestHandler()
    }

    // MARK: - Sampling

    /// Register a handler that responds to `sampling/createMessage` requests from the server.
    ///
    /// When the server sends a `sampling/createMessage` request, the handler is called
    /// with the decoded ``MCPSamplingRequest``. The handler should invoke an LLM and return
    /// the result. For human-in-the-loop workflows, the handler can present the request
    /// to the user for review before proceeding.
    ///
    /// - Parameter handler: A closure that fulfills sampling requests.
    public func setSamplingHandler(_ handler: @escaping SamplingHandler) async {
        self.samplingHandler = handler
        await updateIncomingRequestHandler()
    }

    /// Notify the server that the client's roots have changed.
    ///
    /// Sends a `notifications/roots/list_changed` notification. The server
    /// should then re-request `roots/list`.
    ///
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is not connected.
    public func notifyRootsChanged() async throws {
        let notification = JSONRPCNotification(method: "notifications/roots/list_changed")
        let data = try JSONEncoder().encode(notification)
        try await transport.send(data)
    }

    // MARK: - Private

    /// Updates the dispatcher's incoming request handler to route to both roots and sampling handlers.
    private func updateIncomingRequestHandler() async {
        guard let dispatcher else { return }
        let rootsHandler = self.rootsHandler
        let samplingHandler = self.samplingHandler

        await dispatcher.setIncomingRequestHandler { _, method, params in
            switch method {
            case "roots/list":
                guard let rootsHandler else { return nil }
                let roots = await rootsHandler()
                let rootValues = roots.map { root -> AnyCodableValue in
                    var obj: [String: AnyCodableValue] = ["uri": .string(root.uri)]
                    if let name = root.name {
                        obj["name"] = .string(name)
                    }
                    return .object(obj)
                }
                return .object(["roots": .array(rootValues)])

            case "sampling/createMessage":
                guard let samplingHandler, let params else { return nil }
                do {
                    let paramsData = try JSONEncoder().encode(params)
                    let request = try JSONDecoder().decode(MCPSamplingRequest.self, from: paramsData)
                    let result = try await samplingHandler(request)
                    let resultData = try JSONEncoder().encode(result)
                    return try JSONDecoder().decode(AnyCodableValue.self, from: resultData)
                } catch {
                    return nil
                }

            default:
                return nil
            }
        }
    }

    /// Generic paginated list request.
    private func paginatedList<T: Decodable>(method: String, key: String) async throws -> [T] {
        var allItems: [T] = []
        var cursor: String? = nil

        repeat {
            let params: AnyCodableValue? = cursor.map { .object(["cursor": .string($0)]) }
            let response = try await sendRequest(method: method, params: params)

            guard case .object(let resultObj) = response,
                  case .array(let itemValues) = resultObj[key] else {
                break
            }

            let itemsData = try JSONEncoder().encode(AnyCodableValue.array(itemValues))
            let items = try JSONDecoder().decode([T].self, from: itemsData)
            allItems.append(contentsOf: items)

            if case .string(let nextCursor) = resultObj["nextCursor"] {
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allItems
    }

    /// Sends a JSON-RPC request using the dispatcher (post-initialization).
    private func sendRequest(method: String, params: AnyCodableValue?) async throws -> AnyCodableValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = JSONRPCRequest(id: requestID, method: method, params: params)
        let requestData = try JSONEncoder().encode(request)

        try await transport.send(requestData)

        let response: JSONRPCResponse
        if let dispatcher {
            response = try await withThrowingTimeout(duration: requestTimeout) {
                try await dispatcher.waitForResponse(id: requestID)
            }
        } else {
            // Fallback for pre-initialization calls (shouldn't happen in normal use)
            let responseData = try await transport.receive()
            do {
                response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
            } catch {
                throw MCPError.invalidResponse
            }
        }

        if let rpcError = response.error {
            throw MCPError.requestFailed(code: rpcError.code, message: rpcError.message, data: rpcError.data)
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return result
    }

    /// Races an async operation against a timeout.
    private func withThrowingTimeout<T: Sendable>(
        duration: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw MCPError.timeout
            }
            guard let result = try await group.next() else {
                throw MCPError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    /// Sends a JSON-RPC request using direct transport.receive() (for initialization).
    private func sendRequestDirect(method: String, params: AnyCodableValue?) async throws -> AnyCodableValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = JSONRPCRequest(id: requestID, method: method, params: params)
        let requestData = try JSONEncoder().encode(request)

        try await transport.send(requestData)
        let responseData = try await transport.receive()

        let response: JSONRPCResponse
        do {
            response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        } catch {
            throw MCPError.invalidResponse
        }

        if let rpcError = response.error {
            throw MCPError.requestFailed(code: rpcError.code, message: rpcError.message, data: rpcError.data)
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return result
    }
}
