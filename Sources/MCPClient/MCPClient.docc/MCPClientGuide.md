# Getting Started with MCPClient

Connect to an MCP server, discover tools, and call them from Swift.

## Overview

This guide walks through the three-step MCP workflow: connect, discover, and
invoke. All examples are playground-ready and use the public API surface.

## Connect to a Server

Create a transport and pass it to ``MCPClientConnection``. Use
``HTTPSSETransport`` for remote servers:

```swift
import MCPClient

let transport = HTTPSSETransport(
    url: URL(string: "https://mcp.example.com/sse")!
)
let client = MCPClientConnection(transport: transport)

let info = try await client.initialize(
    clientName: "my-app",
    clientVersion: "1.0.0"
)
print("Connected to \(info.serverInfo.name) v\(info.serverInfo.version)")
```

For local development, use ``StdioTransport`` to launch a server process:

```swift
let transport = StdioTransport(
    command: "npx",
    arguments: ["-y", "@anthropic/my-mcp-server"]
)
let client = MCPClientConnection(transport: transport)
let info = try await client.initialize(
    clientName: "my-app",
    clientVersion: "1.0.0"
)
```

## Discover Available Tools

After initialization, call ``MCPClientConnection/listTools()`` to retrieve
the server's tool catalog:

```swift
let tools = try await client.listTools()
for tool in tools {
    print("  \(tool.name): \(tool.description ?? "No description")")
}
```

Each ``MCPTool`` includes an optional ``MCPTool/inputSchema`` property
containing the JSON Schema for its expected arguments.

## Call a Tool

Invoke a tool by name, passing arguments as a dictionary of
``AnyCodableValue``:

```swift
let result = try await client.callTool(
    name: "score_technical_seo",
    arguments: [
        "ssr_score": .number(95),
        "meta_tags_score": .number(75),
        "crawlability_score": .number(90)
    ]
)

// Check for tool-level errors
if result.isError == true {
    print("Tool error: \(result.content.first?.text ?? "Unknown")")
} else {
    print(result.content.first?.text ?? "No output")
}
```

## Handle Errors

MCPClient uses ``MCPError`` for protocol-level failures:

```swift
do {
    let result = try await client.callTool(name: "nonexistent_tool")
} catch let error as MCPError {
    switch error {
    case .connectionFailed(let reason):
        print("Connection failed: \(reason)")
    case .requestFailed(let code, let message):
        print("Server error \(code): \(message)")
    case .timeout:
        print("Request timed out")
    case .invalidResponse:
        print("Could not decode server response")
    }
}
```

## Thread Safety

``MCPClientConnection`` is an `actor`, so all method calls are automatically
serialized. Request IDs are auto-incremented and guaranteed unique within a
single connection instance.
