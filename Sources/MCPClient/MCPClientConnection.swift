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
        var allTools: [MCPTool] = []
        var cursor: String? = nil

        repeat {
            let params: AnyCodableValue? = cursor.map { .object(["cursor": .string($0)]) }
            let response = try await sendRequest(method: "tools/list", params: params)

            guard case .object(let resultObj) = response,
                  case .array(let toolValues) = resultObj["tools"] else {
                break
            }

            let toolsData = try JSONEncoder().encode(AnyCodableValue.array(toolValues))
            let tools = try JSONDecoder().decode([MCPTool].self, from: toolsData)
            allTools.append(contentsOf: tools)

            // Check for next page
            if case .string(let nextCursor) = resultObj["nextCursor"] {
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allTools
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

    // MARK: - Private

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
