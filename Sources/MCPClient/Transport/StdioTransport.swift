import Foundation

/// Spawns an MCP server as a local subprocess and communicates via stdin/stdout pipes.
///
/// This transport is intended for local development and testing. For production,
/// use ``HTTPSSETransport`` to connect to a remote MCP server.
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    public init(command: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    public func connect() async throws {
        fatalError("Not yet implemented")
    }

    public func disconnect() async throws {
        fatalError("Not yet implemented")
    }

    public func send(_ data: Data) async throws {
        fatalError("Not yet implemented")
    }

    public func receive() async throws -> Data {
        fatalError("Not yet implemented")
    }
}
