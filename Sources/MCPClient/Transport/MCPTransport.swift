import Foundation

/// Protocol defining the transport layer for MCP communication.
///
/// Implementations handle the low-level details of sending and receiving
/// JSON-RPC messages. The two built-in transports are:
/// - ``HTTPSSETransport`` (primary): Connects to a remote MCP server via HTTP/SSE
/// - ``StdioTransport`` (secondary): Spawns a local MCP server subprocess
public protocol MCPTransport: Sendable {
    /// Establish the transport connection.
    func connect() async throws

    /// Close the transport connection and release resources.
    func disconnect() async throws

    /// Send raw JSON-RPC data to the MCP server.
    func send(_ data: Data) async throws

    /// Receive the next JSON-RPC message from the MCP server.
    func receive() async throws -> Data
}
