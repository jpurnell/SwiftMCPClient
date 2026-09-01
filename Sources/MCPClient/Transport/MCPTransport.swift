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

    /// Tells the transport which protocol version the server accepted.
    ///
    /// Called once, after `initialize` succeeds. Most transports have no use for it; Streamable
    /// HTTP must echo it on every later request, because spec 2025-06-18 requires the
    /// `MCP-Protocol-Version` header and a server enforcing it rejects requests without one.
    ///
    /// The version is the one the server **accepted**, not the one requested — they differ
    /// whenever it negotiates down.
    ///
    /// - Parameter protocolVersion: The version from the initialization result.
    func didNegotiate(protocolVersion: String) async
}

public extension MCPTransport {

    /// Ignores the negotiated version.
    ///
    /// The default, so a transport with no use for it does not have to say so, and so adding
    /// this requirement broke no existing conformance.
    func didNegotiate(protocolVersion: String) async {}
}
