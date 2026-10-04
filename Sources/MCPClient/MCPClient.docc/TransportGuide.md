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

## Self-Signed and Private-CA Servers

The three network transports — ``StreamableHTTPTransport``, ``HTTPSSETransport``
and ``WebSocketTransport`` — each take a ``ServerTrust``, which says which
certificate roots the server's chain may end at. It defaults to
``ServerTrust/system``: the platform's root store, which is what any publicly
certified server needs.

A development server with a self-signed certificate, or a server behind a
private certificate authority, is trusted by *supplying the certificate*:

```swift
// Shown inside functions this guide never calls: one reads a file that is not
// there when the guide runs, and both would open a connection.
func connectToSelfSignedServer() async throws {
    guard let url = URL(string: "https://dev.internal:8443/mcp") else { return }

    // The server's own certificate, and nothing else. A server presenting any
    // other certificate — including another self-signed one — is refused.
    let trust = try ServerTrust.onlyRoots([.pemFile("/etc/mcp/dev-server.pem")])

    let transport = StreamableHTTPTransport(url: url, serverTrust: trust)
    let client = MCPClientConnection(transport: transport)
    _ = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")
}

func connectBehindPrivateAuthority(rootPEM: String) throws {
    guard let url = URL(string: "wss://mcp.corp.example/ws") else { return }

    // The system roots as well as the private one, for a client that reaches
    // public servers too.
    let trust = try ServerTrust.additionalRoots([.pem(rootPEM)])

    // What was just trusted, as `openssl x509 -fingerprint -sha256` prints it.
    print(trust.rootFingerprints)

    _ = WebSocketTransport(url: url, serverTrust: trust)
}
```

### What is still checked

Everything. A supplied root changes who is allowed to have signed the server's
certificate; it does not change whether that is checked, and there is no option
that does. In particular:

- **The hostname.** The certificate must carry the host in the URL as a subject
  alternative name — a DNS name, or an IP address if the URL uses one. A trusted
  certificate issued for another name is refused.
- **The chain.** It must end at a supplied root, or for
  ``ServerTrust/additionalRoots(_:)`` at a supplied root or a system one.
- **The dates.** An expired certificate is refused even if it is the one you
  supplied.

On Apple platforms ``ServerTrust/additionalRoots(_:)`` is evaluated by the
system verifier, which applies Apple's own requirements for TLS server
certificates — among them an extended key usage of `serverAuth`.
``ServerTrust/onlyRoots(_:)`` is evaluated by BoringSSL on every platform.

### When it fails

A ``ServerTrust`` that cannot be built — a missing file, text holding no
certificate, an empty list — throws ``ServerTrustError`` where it is
constructed, before any transport exists. Nothing falls back to the system
roots.

A server that is refused surfaces as ``MCPError/connectionFailed(reason:)``
from the first request. The HTTP transports retry a failed connection until
`connectionTimeout` elapses, so a refusal is reported after that long rather
than at once.

### Why there is no "trust anything" switch

Versions before 0.13.0 had `trustSelfSignedCertificates: Bool`. It did not
trust a self-signed certificate; it turned verification off, which accepts any
certificate from anyone able to answer the connection. It has been removed —
the old spelling is a compile error that points here.

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
