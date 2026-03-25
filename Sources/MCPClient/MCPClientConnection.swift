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
/// ## Thread Safety
///
/// `MCPClientConnection` is an `actor`, so all method calls are serialized.
/// Request IDs are auto-incremented and guaranteed unique within a connection.
public actor MCPClientConnection: MCPClientProtocol {
    private let transport: MCPTransport
    private var nextRequestID: Int = 1
    private var isConnected: Bool = false

    /// Creates a new MCP client connection with the given transport.
    ///
    /// The transport is not connected until ``initialize(clientName:clientVersion:)``
    /// is called.
    ///
    /// - Parameter transport: The transport to use for communication.
    public init(transport: MCPTransport) {
        self.transport = transport
    }

    /// Initialize the MCP connection, performing the protocol handshake.
    ///
    /// This method connects the transport (if not already connected), sends the
    /// MCP `initialize` request with the client's identity, waits for the server's
    /// response, then sends the required `notifications/initialized` notification.
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
        protocolVersion: String = "2024-11-05"
    ) async throws -> InitializeResult {
        if !isConnected {
            try await transport.connect()
            isConnected = true
        }

        let params = AnyCodableValue.object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])

        let response = try await sendRequest(method: "initialize", params: params)
        let resultData = try JSONEncoder().encode(response)
        let initResult = try JSONDecoder().decode(InitializeResult.self, from: resultData)

        // Send notifications/initialized per MCP spec (fire-and-forget, no response)
        let notification = JSONRPCNotification(method: "notifications/initialized")
        let notificationData = try JSONEncoder().encode(notification)
        try await transport.send(notificationData)

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
        let params = AnyCodableValue.object([
            "name": .string(name),
            "arguments": .object(arguments)
        ])

        let response = try await sendRequest(method: "tools/call", params: params)
        let resultData = try JSONEncoder().encode(response)
        let toolResult = try JSONDecoder().decode(MCPToolResult.self, from: resultData)
        return toolResult
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

    // MARK: - Private

    /// Generic paginated list request.
    ///
    /// Sends repeated requests with cursor support, collecting items from the
    /// specified key in each response until no `nextCursor` is returned.
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

    /// Sends a JSON-RPC request and returns the result value.
    ///
    /// Handles request ID allocation, JSON encoding/decoding, and error extraction.
    private func sendRequest(method: String, params: AnyCodableValue?) async throws -> AnyCodableValue {
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
            throw MCPError.requestFailed(code: rpcError.code, message: rpcError.message)
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return result
    }
}
