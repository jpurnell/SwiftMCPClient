//
//  MCPClientProtocol.swift
//  MCPClient
//
//  Created by Justin Purnell on 2026-03-21.
//

import Foundation

/// Protocol for MCP tool invocation, extracted from ``MCPClientConnection`` for testability.
///
/// Consumers that only need to call tools (such as GEOAuditCore) depend on this protocol
/// rather than the concrete ``MCPClientConnection`` actor. This allows tests to inject a
/// mock without requiring a real transport layer.
///
/// ```swift
/// func runAudit(client: any MCPClientProtocol) async throws {
///     let result = try await client.callTool(
///         name: "score_technical_seo",
///         arguments: ["ssr_score": .number(95)]
///     )
///     print(result.content.first?.text ?? "No output")
/// }
/// ```
public protocol MCPClientProtocol: Sendable {
    /// Call a tool on the MCP server by name with given arguments.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call.
    ///   - arguments: The arguments to pass to the tool.
    /// - Returns: The tool's result containing one or more content blocks.
    /// - Throws: ``MCPError`` if the call fails.
    func callTool(name: String, arguments: [String: AnyCodableValue]) async throws -> MCPToolResult

    /// Send a ping to the MCP server and await the response.
    ///
    /// - Returns: `true` if the server responded successfully.
    /// - Throws: ``MCPError`` if the ping fails.
    func ping() async throws -> Bool

    /// Discover available resources on the MCP server.
    ///
    /// - Returns: An array of resource definitions.
    /// - Throws: ``MCPError`` if the request fails.
    func listResources() async throws -> [MCPResource]

    /// Read the contents of a resource by URI.
    ///
    /// - Parameter uri: The resource URI to read.
    /// - Returns: An array of resource contents (text or blob).
    /// - Throws: ``MCPError`` if the resource cannot be read.
    func readResource(uri: String) async throws -> [MCPResourceContents]

    /// Discover available prompts on the MCP server.
    ///
    /// - Returns: An array of prompt definitions.
    /// - Throws: ``MCPError`` if the request fails.
    func listPrompts() async throws -> [MCPPrompt]

    /// Get an expanded prompt by name with optional arguments.
    ///
    /// - Parameters:
    ///   - name: The prompt name.
    ///   - arguments: String-valued arguments for the prompt.
    /// - Returns: The prompt result with messages.
    /// - Throws: ``MCPError`` if the request fails.
    func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult

    /// Set the minimum log level for server log messages.
    ///
    /// - Parameter level: The minimum log level to receive.
    /// - Throws: ``MCPError`` if the request fails.
    func setLogLevel(_ level: MCPLogLevel) async throws

    /// Request autocompletion suggestions for a prompt or resource argument.
    ///
    /// - Parameters:
    ///   - ref: The prompt or resource being completed against.
    ///   - argumentName: The name of the argument being completed.
    ///   - argumentValue: The current partial value to match against.
    /// - Returns: The completion result with suggested values.
    /// - Throws: ``MCPError`` if the request fails.
    func complete(ref: MCPCompletionRef, argumentName: String, argumentValue: String) async throws -> MCPCompletionResult
}
