# Choosing a Transport

Select the right transport for your MCP server connection.

## Overview

MCPClient communicates with MCP servers through pluggable transports that
conform to the ``MCPTransport`` protocol. Four ship with the library, each
suited to a different deployment.

For a remote server written against a current specification, reach for
``StreamableHTTPTransport``. ``HTTPSSETransport`` speaks the older HTTP+SSE
shape, which a shrinking set of servers still offers.
``WebSocketTransport`` and ``StdioTransport`` cover a persistent socket and a
local subprocess respectively.

| Transport | For | Server-initiated messages |
| :--- | :--- | :--- |
| ``StreamableHTTPTransport`` | Remote servers, current spec | Yes, over a `GET` stream |
| ``HTTPSSETransport`` | Remote servers, legacy HTTP+SSE | Yes, over the SSE stream |
| ``WebSocketTransport`` | Remote servers offering a socket | Yes |
| ``StdioTransport`` | A local server as a child process | Yes |

## Streamable HTTP — Remote Servers, Current Spec

``StreamableHTTPTransport`` implements the transport defined by MCP
2025-03-26, with the `MCP-Protocol-Version` header added in 2025-06-18.

```swift
// `initialize` opens a live connection, so it is shown inside a function this
// guide never calls.
func connectOverStreamableHTTP() async throws {
    guard let url = URL(string: "https://mcp.example.com/mcp") else { return }
    let transport = StreamableHTTPTransport(url: url)
    let client = MCPClientConnection(transport: transport)
    let info = try await client.initialize(
        clientName: "my-app",
        clientVersion: "1.0.0"
    )
    print("Connected to \(info.serverInfo.name)")
}
```

### Two channels, one queue

Requests go out as `POST`. The server answers either with a single JSON
document or with an SSE stream it may hold open while it works — a long tool
call can report progress as it goes, and those messages arrive *during* the
call rather than after it.

Alongside that, once initialization completes, the transport opens one
client-initiated `GET` stream. That is the channel the server uses to originate
messages: progress, log messages, sampling requests, list-changed
notifications. Without it a client's notification stream is permanently empty.

Both feed the same ``MCPTransport/receive()`` queue, so nothing in your code
needs to know which channel a message arrived on.

A server that originates nothing answers the `GET` with `405`. That is not an
error, and request/response keeps working — the client simply has no
server-initiated messages. To skip the channel entirely, pass
`openServerStream: false`, which restores POST-only behaviour.

### Keeping a session authorised

An OAuth session refreshes, and a header read once at connect time does not.
Pass the session rather than a token:

```swift
func connectWithOAuth(session: MCPOAuthSession) async throws {
    guard let url = URL(string: "https://mcp.example.com/mcp") else { return }
    let transport = StreamableHTTPTransport(
        url: url,
        authorization: { forcingRefresh in
            try await session.authorizationHeader(forcingRefresh: forcingRefresh)
        }
    )
    _ = MCPClientConnection(transport: transport)
}
```

The provider is asked before every request, and again after a `401` — that
second call is what recovers from a token the server has rejected before it
expired locally, which no clock on this side can predict.

### What survives a drop

The server stream reconnects on its own, carrying `Last-Event-ID` so the
server can continue rather than replay or skip. It backs off gently between
attempts, because losing this stream is not an outage: requests and responses
keep working without it.

A `404` answering a request that carried a session id means the server has
forgotten the session. The transport forgets it too, so a caller can
re-initialize rather than send every later request into the same wall.

### When to Use

- Remote servers written against MCP 2025-03-26 or later
- Anything needing progress notifications or sampling
- OAuth-protected servers — see ``MCPOAuthSession``

## HTTP/SSE — Remote Servers (Legacy)

## HTTP/SSE — Remote Servers

``HTTPSSETransport`` connects over the older HTTP+SSE shape: a long-lived SSE
stream for receiving, HTTP POST for sending. Prefer
``StreamableHTTPTransport`` for a server that offers it; this remains for
servers that have not moved.

The difference that matters is what a dead stream costs. Here the SSE stream is
the *only* channel for responses, so losing it ends the connection. Streamable
HTTP survives a dead server stream entirely — only server-initiated messages
stop. That is why the two are separate types rather than one with a mode flag.

```swift
// `initialize` opens a live connection, so it is shown inside a function this
// guide never calls. The signatures are checked by the compiler; no server is
// contacted when the guide runs.
func connectOverHTTPSSE() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let transport = HTTPSSETransport(
        url: url,
        headers: ["Authorization": "Bearer token123"],
        connectionTimeout: 30
    )
    let client = MCPClientConnection(transport: transport)
    let info = try await client.initialize(
        clientName: "my-app",
        clientVersion: "1.0.0"
    )
    print("Connected to \(info.serverInfo.name)")
}
```

The SSE connection is established on ``MCPTransport/connect()`` and maintained
until ``MCPTransport/disconnect()`` is called. A failed connect is retried with
an exponential backoff — three attempts by default, configurable through
`maxReconnectAttempts` and `reconnectBaseDelay`.

### When to Use

- Servers that offer only the legacy HTTP+SSE endpoints
- Cross-platform (macOS, iOS, tvOS, watchOS, Linux)

## Stdio — Local Subprocess

``StdioTransport`` launches an MCP server as a local child process and
communicates via newline-delimited JSON over stdin/stdout pipes. This is ideal
for development and testing against locally-installed MCP servers.

```swift
// Spawning the subprocess is likewise a live operation; shown, not run.
func connectOverStdio() async throws {
    let stdioTransport = StdioTransport(
        command: "/usr/local/bin/my-mcp-server",
        arguments: ["--verbose"],
        environment: ["MCP_LOG_LEVEL": "debug"]
    )
    let stdioClient = MCPClientConnection(transport: stdioTransport)
    let stdioInfo = try await stdioClient.initialize(
        clientName: "dev-tool",
        clientVersion: "0.1.0"
    )
    print("Connected to \(stdioInfo.serverInfo.name)")
}
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
// This is the shape `MCPTransport` already has — repeated here for reference,
// under a distinct name so the guide does not redeclare the real protocol.
protocol MyCustomTransport: Sendable {
    func connect() async throws
    func disconnect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
}
```

All four methods are required. The transport must be `Sendable` for use with
the ``MCPClientConnection`` actor. Message framing (how individual JSON-RPC
messages are delimited) is the transport's responsibility.
