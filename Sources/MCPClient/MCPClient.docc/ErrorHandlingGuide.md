# Error Handling

Understand and recover from errors in MCPClient.

## Overview

All MCPClient errors are represented by the ``MCPError`` enum. Each case
corresponds to a specific failure mode with descriptive associated values
to help diagnose and recover from problems.

## Error Cases

### connectionFailed

Thrown when the transport cannot establish or maintain a connection.

```swift
do {
    _ = try await client.initialize(clientName: "app", clientVersion: "1.0")
} catch MCPError.connectionFailed(let reason) {
    print("Connection failed: \(reason)")
    // Recovery: check network, retry with backoff, or try a different server
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
```

### invalidResponse

Thrown when the server's response cannot be decoded as valid JSON-RPC.

```swift
do {
    _ = try await client.listTools()
} catch MCPError.invalidResponse {
    print("Server returned malformed response")
    // Recovery: check server logs, verify server compatibility
}
```

### processSpawnFailed

Thrown by ``StdioTransport`` when the subprocess cannot be launched.

```swift
let transport = StdioTransport(command: "/usr/bin/nonexistent")
do {
    try await transport.connect()
} catch MCPError.processSpawnFailed(let reason) {
    print("Cannot start server: \(reason)")
    // Recovery: check command path, permissions, arguments
}
```

### transportClosed

Thrown when the transport connection closes unexpectedly.

```swift
do {
    _ = try await client.listTools()
} catch MCPError.transportClosed {
    print("Connection lost")
    // Recovery: reconnect with a new client instance
}
```

## Best Practices

### Use exhaustive switch for robust handling

```swift
do {
    let result = try await client.callTool(name: "analyze", arguments: args)
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
    }
}
```

### Retry with backoff for transient failures

Timeouts and transport closures may be transient. Implement exponential
backoff for these cases while treating `requestFailed` errors as
non-retryable server-side issues.
