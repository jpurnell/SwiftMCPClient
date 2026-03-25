import Foundation

/// A JSON-RPC 2.0 request message sent to an MCP server.
///
/// Requests are serialized as JSON and sent via the active ``MCPTransport``.
/// The ``MCPClientConnection`` actor manages request ID allocation automatically.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "jsonrpc": "2.0",
///     "id": 1,
///     "method": "tools/call",
///     "params": {
///         "name": "score_technical_seo",
///         "arguments": {"ssr_score": 95}
///     }
/// }
/// ```
public struct JSONRPCRequest: Codable, Sendable {
    /// The JSON-RPC protocol version. Always `"2.0"`.
    public let jsonrpc: String

    /// The request identifier, auto-incremented by ``MCPClientConnection``.
    public let id: Int

    /// The MCP method name (e.g., `"initialize"`, `"tools/list"`, `"tools/call"`).
    public let method: String

    /// Optional parameters for the method. `nil` for parameterless methods like `tools/list`.
    public let params: AnyCodableValue?

    /// Creates a new JSON-RPC request.
    ///
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - method: The MCP method name.
    ///   - params: Optional method parameters.
    public init(id: Int, method: String, params: AnyCodableValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC 2.0 notification message (no `id`, no response expected).
///
/// Notifications are one-way messages. The MCP protocol uses them for
/// signals like `notifications/initialized` (sent after handshake)
/// and `notifications/progress` (sent during long-running operations).
///
/// ## MCP Schema
///
/// ```json
/// {"jsonrpc": "2.0", "method": "notifications/initialized"}
/// ```
public struct JSONRPCNotification: Codable, Sendable {
    /// The JSON-RPC protocol version. Always `"2.0"`.
    public let jsonrpc: String

    /// The notification method name.
    public let method: String

    /// Optional parameters for the notification.
    public let params: AnyCodableValue?

    /// Creates a new JSON-RPC notification.
    ///
    /// - Parameters:
    ///   - method: The notification method name.
    ///   - params: Optional parameters. Defaults to `nil`.
    public init(method: String, params: AnyCodableValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC 2.0 response message received from an MCP server.
///
/// A response contains either a ``result`` (on success) or an ``error`` (on failure),
/// but never both. The ``id`` matches the request that triggered this response.
///
/// ## MCP Schema
///
/// Success:
/// ```json
/// {"jsonrpc": "2.0", "id": 1, "result": {"content": [...]}}
/// ```
///
/// Error:
/// ```json
/// {"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "Method not found"}}
/// ```
public struct JSONRPCResponse: Codable, Sendable {
    /// The JSON-RPC protocol version. Always `"2.0"`.
    public let jsonrpc: String

    /// The request identifier this response corresponds to. `nil` for notifications.
    public let id: Int?

    /// The successful result, if the request succeeded.
    public let result: AnyCodableValue?

    /// The error object, if the request failed.
    public let error: JSONRPCError?
}

/// A JSON-RPC 2.0 error object embedded in a response.
///
/// Contains a numeric error code, a human-readable message, and optional
/// structured data with additional details.
public struct JSONRPCError: Codable, Sendable, Equatable {
    /// The JSON-RPC error code (e.g., `-32601` for "Method not found").
    public let code: Int

    /// A human-readable error message.
    public let message: String

    /// Optional structured data providing additional error context.
    public let data: AnyCodableValue?

    /// Creates a new JSON-RPC error.
    ///
    /// - Parameters:
    ///   - code: The numeric error code.
    ///   - message: A human-readable description of the error.
    ///   - data: Optional additional error context.
    public init(code: Int, message: String, data: AnyCodableValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}
