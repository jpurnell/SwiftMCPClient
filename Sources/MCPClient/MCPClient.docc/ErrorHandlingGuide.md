# Error Handling

Understand and recover from errors in MCPClient.

## Overview

All MCPClient errors are represented by the ``MCPError`` enum. Each case
corresponds to a specific failure mode with descriptive associated values
to help diagnose and recover from problems.

## Error Cases

Every example below is a function this guide defines but never calls. Each one
needs a live server, and an example that reached for one would hang or crash
here with no server to answer it. The compiler still checks each signature.

```swift
import MCPClient

func connectedClient() async throws -> MCPClientConnection? {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return nil }
    let client = MCPClientConnection(transport: HTTPSSETransport(url: url))
    _ = try await client.initialize(clientName: "app", clientVersion: "1.0")
    return client
}
```

### connectionFailed

Thrown when the transport cannot establish or maintain a connection.

```swift
func handleConnectionFailure() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let client = MCPClientConnection(transport: HTTPSSETransport(url: url))
    do {
        _ = try await client.initialize(clientName: "app", clientVersion: "1.0")
    } catch MCPError.connectionFailed(let reason) {
        print("Connection failed: \(reason)")
        // Recovery: check network, retry with backoff, or try a different server
    }
}
```

**Common causes:**
- Network unreachable
- Server not running
- SSL/TLS certificate issues
- Protocol version mismatch (server returned incompatible version)

### requestFailed

Thrown when the server returns a JSON-RPC error response.

```swift
func handleRequestFailure() async throws {
    guard let client = try await connectedClient() else { return }
    do {
        _ = try await client.callTool(name: "nonexistent")
    } catch MCPError.requestFailed(let code, let message, let data) {
        switch code {
        case -32601:
            print("Method not found: \(message)")
        case -32602:
            print("Invalid params: \(message)")
        default:
            print("Server error \(code): \(message)")
        }
    }
}
```

**Standard JSON-RPC error codes:**

| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |

### timeout

Thrown when a request exceeds the configured timeout duration.

```swift
func handleTimeout() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let transport = HTTPSSETransport(url: url)
    let client = MCPClientConnection(
        transport: transport,
        requestTimeout: .seconds(10)
    )
    // ...
    do {
        _ = try await client.callTool(name: "slow_tool")
    } catch MCPError.timeout {
        print("Request timed out")
        // Recovery: increase timeout, cancel, or retry
    }
}
```

### invalidResponse

Thrown when the server's response cannot be decoded as valid JSON-RPC.

```swift
func handleInvalidResponse() async throws {
    guard let client = try await connectedClient() else { return }
    do {
        _ = try await client.listTools()
    } catch MCPError.invalidResponse {
        print("Server returned malformed response")
        // Recovery: check server logs, verify server compatibility
    }
}
```

### processSpawnFailed

Thrown by ``StdioTransport`` when the subprocess cannot be launched.

```swift
func handleSpawnFailure() async throws {
    let transport = StdioTransport(command: "/usr/bin/nonexistent")
    do {
        try await transport.connect()
    } catch MCPError.processSpawnFailed(let reason) {
        print("Cannot start server: \(reason)")
        // Recovery: check command path, permissions, arguments
    }
}
```

### transportClosed

Thrown when the transport connection closes unexpectedly.

```swift
func handleTransportClosed() async throws {
    guard let client = try await connectedClient() else { return }
    do {
        _ = try await client.listTools()
    } catch MCPError.transportClosed {
        print("Connection lost")
        // Recovery: reconnect with a new client instance
    }
}
```

### endpointRejected

Thrown by ``HTTPSSETransport`` when the server's `endpoint` event names a URL
that is not on the origin of the stream — another host, scheme or port, or a
URL carrying userinfo. Nothing has been sent to that URL, and the connect was
not retried.

```swift
func handleRejectedEndpoint() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let transport = HTTPSSETransport(url: url)
    do {
        try await transport.connect()
    } catch MCPError.endpointRejected(let endpoint, let reason) {
        print("Server asked for messages to go to \(endpoint): \(reason)")
        // Not transient: do not retry. Either the server is misconfigured
        // (advertising an internal address from behind a proxy, say) or it,
        // or something in front of it, is redirecting your session.
    }
}
```

`endpoint` is an origin only — `scheme://host[:port]` — with no path, query or
userinfo, so it is safe to log.

### redirectRejected

Thrown by ``StreamableHTTPTransport`` and ``HTTPSSETransport`` when the server
answers a request with a redirect to another origin — another host or port, or
`http` where the transport was configured with `https`. The redirect was not
followed and nothing was sent to its destination: no header, no session id, no
body.

```swift
func handleRejectedRedirect() async throws {
    guard let url = URL(string: "https://mcp.example.com/mcp") else { return }
    let client = MCPClientConnection(transport: StreamableHTTPTransport(url: url))
    do {
        _ = try await client.initialize(clientName: "app", clientVersion: "1.0")
    } catch MCPError.redirectRejected(let destination, let reason) {
        print("Server redirected to \(destination): \(reason)")
        // Not transient: do not retry. If `destination` is where the server
        // really lives now, configure the transport with that URL. If it is
        // not, something is trying to move your session.
    }
}
```

`destination` is an origin only, like `endpoint` above. The redirect's path and
query are left out: they are the server's to write, and an error is not where a
server gets to write into your logs.

It is a separate case from `endpointRejected` because what to do about it
differs. A cross-origin `endpoint` is a server misdescribing itself, and only
the server can fix that. A cross-origin redirect is very often a server that
moved, or one you reached over `http` that wants `https` — and the fix is the
URL you configured.

## Best Practices

### Use exhaustive switch for robust handling

```swift
import Logging

func logEveryErrorCase() async throws {
    guard let client = try await connectedClient() else { return }
    let logger = Logger(label: "com.example.my-app")
    let args: [String: AnyCodableValue] = ["url": .string("https://example.com")]

    do {
        _ = try await client.callTool(name: "analyze", arguments: args)
        // handle result
    } catch let error as MCPError {
        switch error {
        case .connectionFailed(let reason):
            logger.error("Connection: \(reason)")
        case .requestFailed(let code, let message, _):
            logger.error("Server error \(code): \(message)")
        case .timeout:
            logger.warning("Request timed out")
        case .invalidResponse:
            logger.error("Malformed response")
        case .processSpawnFailed(let reason):
            logger.error("Spawn failed: \(reason)")
        case .transportClosed:
            logger.warning("Transport closed")
        case .endpointRejected(let endpoint, let reason):
            logger.error("Refused endpoint on \(endpoint): \(reason)")
        case .redirectRejected(let destination, let reason):
            logger.error("Refused redirect to \(destination): \(reason)")
        }
    }
}
```

### Retry with backoff for transient failures

Timeouts and transport closures may be transient. Implement exponential
backoff for these cases while treating `requestFailed` errors as
non-retryable server-side issues. `endpointRejected` and `redirectRejected` are
never worth retrying: each is the server's answer, and it will give the same
one again.
