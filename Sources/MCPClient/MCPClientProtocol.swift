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
}
