import AppKit
import Foundation
import MCPClient
#if canImport(os)
import os
#endif

/// Dumps an MCP server's tool catalog as JSON.
///
/// Signs in over OAuth (browser consent), connects over Streamable HTTP, and prints the
/// complete `tools/list` result — names, descriptions, and input schemas — to stdout as
/// pretty-printed JSON. Written to audit servers whose tool count outgrows a browsing UI;
/// MCPExplorer shows tools three at a time, which is no way to read 69 schemas.
///
/// Usage: `swift run MCPDump [server-url]` — the URL defaults to Apollo's MCP endpoint.
@main
struct MCPDump {
    private static let logger = os.Logger(subsystem: "MCPDump", category: "cli")

    static func main() async {
        do {
            try await run()
            exit(0)
        } catch {
            Self.logger.error("MCPDump failed: \(error, privacy: .public)")
            // The unified log is invisible from a terminal; the operator needs stderr.
            FileHandle.standardError.write(Data("MCPDump failed: \(String(describing: error))\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let urlString = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "https://mcp.apollo.io/mcp"

        // Same bar as MCPExplorer's sign-in: the string is about to name the host an
        // OAuth flow runs against, so https is required.
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw MCPError.connectionFailed(reason: "Pass an https:// MCP server URL")
        }

        let session = try MCPOAuthSession.persistent()

        // Restoring first is the whole point of persisting the registration: every browser
        // sign-in leaves another dynamic registration behind at the server, and a tool run from
        // a shell is run repeatedly.
        if try await session.resume(server: url) {
            FileHandle.standardError.write(Data("Restored a stored session for \(host).\n".utf8))
        } else {
            FileHandle.standardError.write(
                Data("Signing in to \(host) — approve in the browser…\n".utf8))
            try await session.signIn(server: url, clientName: "MCPDump") { authorizationURL in
                NSWorkspace.shared.open(authorizationURL)
            }
        }

        guard try await session.authorizationHeader() != nil else {
            throw MCPError.connectionFailed(reason: "Sign-in completed without a credential")
        }

        // The session, not a copy of one header it produced. Dumping a large catalogue can
        // outlast an access token, and a frozen header would start failing partway through
        // with no way to recover but to sign in again.
        let transport = StreamableHTTPTransport(
            url: url,
            authorization: { [session] forcing in
                try await session.authorizationHeader(forcingRefresh: forcing)
            })
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(60))
        let serverInfo = try await connection.initialize(
            clientName: "MCPDump",
            clientVersion: "1.0.0")
        FileHandle.standardError.write(
            Data("Connected: \(serverInfo.serverInfo.name) \(serverInfo.serverInfo.version)\n".utf8))

        let tools = try await connection.listTools()
        FileHandle.standardError.write(Data("Tools: \(tools.count)\n".utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(tools)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        try await connection.disconnect()
    }
}
