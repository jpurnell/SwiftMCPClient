# Migrating to MCPClient v1.0.0

Upgrade from v0.4.0 to v1.0.0 with this guide covering all breaking changes.

## Overview

MCPClient v1.0.0 introduces two breaking changes to improve MCP specification
compliance. Both are straightforward to migrate. This guide shows before/after
code for each change, plus highlights the new features available in v1.0.

Every example below runs against this connection:

```swift
import MCPClient

// Each "after" example below is a function this guide defines but never calls.
// They need a live server, and one that reached for a server would throw or
// hang here with none to answer it. The compiler still checks every signature.
func connectedClient() async throws -> MCPClientConnection? {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return nil }
    let transport = HTTPSSETransport(url: url)
    let client = MCPClientConnection(transport: transport)
    _ = try await client.initialize(clientName: "my-app", clientVersion: "1.0")
    return client
}
```

## MCPContent is now a discriminated union

The biggest change: ``MCPContent`` was previously a struct with optional fields.
It is now an enum with cases for each content type, matching the MCP spec's
`TextContent | ImageContent | EmbeddedResource` union.

### Before (v0.4.0)

<!-- docs:illustrative -->
```swift
let result = try await client.callTool(name: "analyze", arguments: [:])
for block in result.content {
    if block.type == "text" {
        print(block.text ?? "")
    }
}
```

### After (v1.0.0)

```swift
func readContentUnion() async throws {
    guard let client = try await connectedClient() else { return }
    let result = try await client.callTool(name: "analyze", arguments: [:])
    for block in result.content {
        switch block {
        case .text(let str, let annotations):
            print(str)
            if let annotations { print("  annotations: \(annotations)") }
        case .image(let base64, let mimeType, _):
            print("image (\(mimeType)), \(base64.count) base64 characters")
        case .resource(let contents, _):
            print("embedded resource: \(contents)")
        }
    }
}
```

### Key differences

- **No more `block.type` / `block.text`** — use pattern matching instead
- **Annotations built in** — each case carries optional ``MCPAnnotations``
- **Type safety** — the compiler ensures you handle all content types
- **Unified with prompts** — ``MCPPromptContent`` is now a typealias for ``MCPContent``

## MCPError.requestFailed now includes data

The `.requestFailed` error case gained an optional `data` field to surface the
JSON-RPC error's `data` payload.

### Before (v0.4.0)

<!-- docs:illustrative -->
```swift
do {
    _ = try await client.callTool(name: "broken")
} catch MCPError.requestFailed(let code, let message) {
    print("Error \(code): \(message)")
}
```

### After (v1.0.0)

```swift
func catchRequestFailure() async throws {
    guard let client = try await connectedClient() else { return }
    do {
        _ = try await client.callTool(name: "broken")
    } catch MCPError.requestFailed(let code, let message, let data) {
        print("Error \(code): \(message)")
        if let data {
            print("Additional info: \(data)")
        }
    }
}
```

If you don't need the data field, use a wildcard:

<!-- docs:illustrative -->
```swift
} catch MCPError.requestFailed(let code, let message, _) {
```

## New features in v1.0.0

### Client capabilities

Declare client capabilities during initialization:

```swift
func initializeWithCapabilities() async throws {
    guard let client = try await connectedClient() else { return }
    let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
    let initializeResult = try await client.initialize(
        clientName: "my-app",
        clientVersion: "1.0",
        capabilities: caps
    )
}
```

### Progress tokens

Track progress for long-running tool calls:

```swift
func callToolWithProgressToken() async throws {
    guard let client = try await connectedClient() else { return }
    let progressResult = try await client.callTool(
        name: "slow_analysis",
        arguments: ["url": .string("https://example.com")],
        progressToken: .string("analysis-1")
    )
}
```

### Graceful disconnect

Clean up connections properly:

```swift
func closeTheConnection() async throws {
    guard let client = try await connectedClient() else { return }
    try await client.disconnect()
}
```

### Request timeouts

Configure per-connection timeout:

```swift
func clientWithLongerTimeout() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let transport = HTTPSSETransport(url: url)
    let patientClient = MCPClientConnection(
        transport: transport,
        requestTimeout: .seconds(60)
    )
}
```

### Sampling

Handle server requests for LLM completions:

```swift
func registerSamplingHandler() async throws {
    guard let client = try await connectedClient() else { return }
    // Stand-in for whichever model you call.
    struct MyLLM {
        func complete(_ messages: [MCPSamplingMessage]) async throws -> String {
            "a completion for \(messages.count) message(s)"
        }
    }
    let myLLM = MyLLM()

    await client.setSamplingHandler { request in
        let response = try await myLLM.complete(request.messages)
        return MCPSamplingResult(
            role: .assistant,
            content: .text(response),
            model: "my-model",
            stopReason: "endTurn"
        )
    }
}
```

### Typed notification streams

Subscribe to specific notification types:

```swift
func consumeProgressAndLogs() async throws {
    guard let client = try await connectedClient() else { return }
    for await progress in await client.progressUpdates {
        print("Progress: \(progress.progress)/\(progress.total ?? 0)")
    }

    for await message in await client.logMessages {
        print("[\(message.level)] \(message.data)")
    }
}
```

### WebSocket transport

Connect via WebSocket instead of HTTP/SSE:

```swift
func connectOverWebSocket() throws {
    guard let url = URL(string: "wss://mcp.example.com/ws") else { return }
    let webSocketTransport = WebSocketTransport(
        url: url,
        headers: ["Authorization": "Bearer token"]
    )
    _ = webSocketTransport
}
```
