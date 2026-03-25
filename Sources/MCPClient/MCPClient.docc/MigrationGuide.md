# Migrating to MCPClient v1.0.0

Upgrade from v0.4.0 to v1.0.0 with this guide covering all breaking changes.

## Overview

MCPClient v1.0.0 introduces two breaking changes to improve MCP specification
compliance. Both are straightforward to migrate. This guide shows before/after
code for each change, plus highlights the new features available in v1.0.

## MCPContent is now a discriminated union

The biggest change: ``MCPContent`` was previously a struct with optional fields.
It is now an enum with cases for each content type, matching the MCP spec's
`TextContent | ImageContent | EmbeddedResource` union.

### Before (v0.4.0)

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
    case .image(let data, let mimeType, _):
        // Handle base64 image
        break
    case .resource(let contents, _):
        // Handle embedded resource
        break
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

```swift
} catch MCPError.requestFailed(let code, let message, _) {
```

## New features in v1.0.0

### Client capabilities

Declare client capabilities during initialization:

```swift
let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
let result = try await client.initialize(
    clientName: "my-app",
    clientVersion: "1.0",
    capabilities: caps
)
```

### Progress tokens

Track progress for long-running tool calls:

```swift
let result = try await client.callTool(
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
let client = MCPClientConnection(
    transport: transport,
    requestTimeout: .seconds(60)
)
```

### Sampling

Handle server requests for LLM completions:

```swift
await client.setSamplingHandler { request in
    let response = try await myLLM.complete(request.messages)
    return MCPSamplingResult(
        role: .assistant,
        content: .text(response.text),
        model: "my-model",
        stopReason: "endTurn"
    )
}
```

### Typed notification streams

Subscribe to specific notification types:

```swift
for await progress in client.progressUpdates {
    print("Progress: \(progress.progress)/\(progress.total ?? 0)")
}

for await message in client.logMessages {
    print("[\(message.level)] \(message.data)")
}
```

### WebSocket transport

Connect via WebSocket instead of HTTP/SSE:

```swift
let transport = WebSocketTransport(
    url: URL(string: "wss://mcp.example.com/ws")!,
    headers: ["Authorization": "Bearer token"]
)
```
