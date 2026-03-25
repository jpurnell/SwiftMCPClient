import Foundation

/// Errors that can occur during MCP client operations.
///
/// `MCPError` covers the error conditions specific to MCP protocol communication.
/// Transport-level errors (network failures, process crashes) are surfaced through
/// the ``MCPTransport`` protocol and may be wrapped in ``connectionFailed(reason:)``.
///
/// ## MCP Schema
///
/// JSON-RPC 2.0 error codes map to ``requestFailed(code:message:)``:
/// - `-32700`: Parse error
/// - `-32600`: Invalid request
/// - `-32601`: Method not found
/// - `-32602`: Invalid params
/// - `-32603`: Internal error
public enum MCPError: Error, Sendable, Equatable {
    /// Transport failed to connect to the MCP server.
    ///
    /// - Parameter reason: A human-readable description of the connection failure.
    case connectionFailed(reason: String)

    /// The MCP server returned a JSON-RPC error response.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: The error message from the server.
    ///   - data: Optional additional error context from the server.
    case requestFailed(code: Int, message: String, data: AnyCodableValue?)

    /// The request exceeded the configured timeout.
    case timeout

    /// The response could not be decoded as valid JSON-RPC.
    case invalidResponse

    /// The subprocess could not be spawned (StdioTransport).
    ///
    /// - Parameter reason: A human-readable description of the spawn failure.
    case processSpawnFailed(reason: String)

    /// The transport connection was closed unexpectedly (e.g., subprocess exited).
    case transportClosed
}
