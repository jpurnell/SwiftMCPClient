# Choosing a Transport

Select the right transport for your MCP server connection.

## Overview

MCPClient communicates with MCP servers through pluggable transports that
conform to the ``MCPTransport`` protocol. The library ships two built-in
transports, each suited to a different deployment scenario.

## HTTP/SSE — Remote Servers

``HTTPSSETransport`` connects to MCP servers over HTTP using Server-Sent Events
(SSE) for receiving messages and HTTP POST for sending. This is the primary
transport for production use.

```swift
let transport = HTTPSSETransport(
    url: URL(string: "https://mcp.example.com/sse")!,
    headers: ["Authorization": "Bearer token123"],
    timeout: 30
)
let client = MCPClientConnection(transport: transport)
let info = try await client.initialize(
    clientName: "my-app",
    clientVersion: "1.0.0"
)
```

The SSE connection is established on ``MCPTransport/connect()`` and maintained
until ``MCPTransport/disconnect()`` is called. If the SSE stream terminates
unexpectedly, the transport attempts one automatic reconnection.

### When to Use

- Production deployments against hosted MCP servers
- Cross-platform (macOS, iOS, tvOS, watchOS, Linux)
- Servers behind authentication or reverse proxies

## Stdio — Local Subprocess

``StdioTransport`` launches an MCP server as a local child process and
communicates via newline-delimited JSON over stdin/stdout pipes. This is ideal
for development and testing against locally-installed MCP servers.

```swift
let transport = StdioTransport(
    command: "/usr/local/bin/my-mcp-server",
    arguments: ["--verbose"],
    environment: ["MCP_LOG_LEVEL": "debug"]
)
let client = MCPClientConnection(transport: transport)
let info = try await client.initialize(
    clientName: "dev-tool",
    clientVersion: "0.1.0"
)
```

The subprocess is spawned on ``MCPTransport/connect()`` and terminated
gracefully on ``MCPTransport/disconnect()`` (stdin close → SIGTERM → SIGKILL).

### When to Use

- Local development with `npx`-based MCP servers
- Testing against a server binary on your machine
- macOS and Linux only (requires `Foundation.Process`)

### Platform Availability

`StdioTransport` uses `Foundation.Process` for subprocess management and is
only available on macOS and Linux. It is **not** available on iOS, tvOS, or
watchOS. The type is conditionally compiled with `#if os(macOS) || os(Linux)`.

## Custom Transports

Implement ``MCPTransport`` to add support for other communication channels:

```swift
public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
}
```

All four methods are required. The transport must be `Sendable` for use with
the ``MCPClientConnection`` actor. Message framing (how individual JSON-RPC
messages are delimited) is the transport's responsibility.
