# Migrating to MCPClient v1.0.0

Upgrade from v0.4.0 to v1.0.0 with this guide covering all breaking changes.

## Overview

MCPClient v1.0.0 introduces two breaking changes to improve MCP specification
compliance. Both are straightforward to migrate. This guide shows before/after
code for each change, plus highlights the new features available in v1.0.

Every example below runs against this connection:

```swift
import MCPClient

let transport = HTTPSSETransport(url: URL(string: "https://mcp.example.com/sse")!)
let client = MCPClientConnection(transport: transport)
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
do {
    _ = try await client.callTool(name: "broken")
} catch MCPError.requestFailed(let code, let message, let data) {
    print("Error \(code): \(message)")
    if let data {
        print("Additional info: \(data)")
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
let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
let initializeResult = try await client.initialize(
    clientName: "my-app",
    clientVersion: "1.0",
    capabilities: caps
)
```

### Progress tokens

Track progress for long-running tool calls:

```swift
let progressResult = try await client.callTool(
    name: "slow_analysis",
    arguments: ["url": .string("https://example.com")],
    progressToken: .string("analysis-1")
)
```

### Graceful disconnect

Clean up connections properly:

```swift
try await client.disconnect()
```

### Request timeouts

Configure per-connection timeout:

```swift
let patientClient = MCPClientConnection(
    transport: transport,
    requestTimeout: .seconds(60)
)
```

### Sampling

Handle server requests for LLM completions:

```swift
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
```

### Typed notification streams

Subscribe to specific notification types:

```swift
for await progress in await client.progressUpdates {
    print("Progress: \(progress.progress)/\(progress.total ?? 0)")
}

for await message in await client.logMessages {
    print("[\(message.level)] \(message.data)")
}
```

### WebSocket transport

Connect via WebSocket instead of HTTP/SSE:

```swift
let webSocketTransport = WebSocketTransport(
    url: URL(string: "wss://mcp.example.com/ws")!,
    headers: ["Authorization": "Bearer token"]
)
```
