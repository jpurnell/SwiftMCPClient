# SwiftMCPClient

A Swift 6 client library for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io), enabling Swift applications to connect to MCP servers over HTTP/SSE, WebSocket, or stdio.

## Features

- **Three transports** — HTTP/SSE (production), WebSocket, and stdio (local dev)
- **Full MCP spec coverage** — tools, resources, prompts, sampling, roots, notifications, progress, autocompletion
- **Swift 6 strict concurrency** — actor-based client, all types `Sendable`
- **Cross-platform** — macOS, Linux (via AsyncHTTPClient + NIO)
- **Testable** — `MCPClientProtocol` for mocking in tests
- **Bi-directional** — handles server-to-client requests (`roots/list`, `sampling/createMessage`)
- **Auto-reconnect** — HTTP/SSE transport reconnects with exponential backoff
- **MCPExplorer** — included SwiftUI macOS app for interactive server exploration

## Requirements

- Swift 6.0+
- macOS 14+ / iOS 17+ / tvOS 17+ / watchOS 10+
- Linux (Ubuntu 22.04+ tested)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/SwiftMCPClient.git", branch: "main")
]
```

Then add `MCPClient` to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "MCPClient", package: "SwiftMCPClient")
    ]
)
```

## Quick Start

### Connect to a remote MCP server via HTTP/SSE

```swift
import MCPClient

let transport = HTTPSSETransport(url: URL(string: "https://mcp.example.com/sse")!)
let client = MCPClientConnection(transport: transport)

// Initialize the connection
let serverInfo = try await client.initialize(
    clientName: "MyApp",
    clientVersion: "1.0.0"
)

// Discover available tools
let tools = try await client.listTools()
for tool in tools {
    print("\(tool.name): \(tool.description ?? "")")
}

// Call a tool
let result = try await client.callTool(
    name: "analyze_content",
    arguments: ["url": .string("https://example.com")]
)

for content in result.content {
    if case .text(let text, _) = content {
        print(text)
    }
}

// Disconnect when done
try await client.disconnect()
```

### Connect via WebSocket

```swift
let transport = WebSocketTransport(url: URL(string: "wss://mcp.example.com/ws")!)
let client = MCPClientConnection(transport: transport)
let _ = try await client.initialize(clientName: "MyApp", clientVersion: "1.0.0")
```

### Connect to a local server via stdio

```swift
let transport = StdioTransport(
    command: "/usr/local/bin/my-mcp-server",
    arguments: ["--mode", "stdio"]
)
let client = MCPClientConnection(transport: transport)
let _ = try await client.initialize(clientName: "MyApp", clientVersion: "1.0.0")
```

## Transports

| Transport | Use Case | Protocol | Auto-Reconnect |
|-----------|----------|----------|---------------|
| `HTTPSSETransport` | Remote servers (production) | GET for SSE stream, POST for requests | Yes |
| `WebSocketTransport` | Remote servers (bidirectional) | WebSocket text frames | No |
| `StdioTransport` | Local development | Subprocess stdin/stdout | No |

### HTTPSSETransport Options

```swift
let transport = HTTPSSETransport(
    url: URL(string: "https://mcp.example.com/sse")!,
    headers: ["Authorization": "Bearer token123"],
    connectionTimeout: 30,
    maxReconnectAttempts: 3,
    reconnectBaseDelay: 1.0,
    trustSelfSignedCertificates: false  // true only for dev/testing
)
```

## MCP Operations

### Tools

```swift
let tools = try await client.listTools()
let result = try await client.callTool(name: "score_page", arguments: [
    "url": .string("https://example.com"),
    "depth": .integer(2)
])
```

### Resources

```swift
let resources = try await client.listResources()
let contents = try await client.readResource(uri: "file:///config.json")

// Subscribe to resource changes
try await client.subscribeResource(uri: "file:///data.json")
for await uri in client.resourceUpdates {
    print("Resource updated: \(uri)")
}
```

### Prompts

```swift
let prompts = try await client.listPrompts()
let result = try await client.getPrompt(
    name: "analyze",
    arguments: ["topic": "performance"]
)
for message in result.messages {
    print("\(message.role): \(message.content)")
}
```

### Autocompletion

```swift
let completions = try await client.complete(
    ref: .prompt(name: "analyze"),
    argumentName: "topic",
    argumentValue: "perf"
)
// completions.values: ["performance", "permissions", ...]
```

### Notifications

```swift
// All notifications
for await notification in client.notifications {
    switch notification {
    case .progress(let p): print("Progress: \(p.progress)/\(p.total ?? 0)")
    case .logMessage(let m): print("Log [\(m.level)]: \(m.data)")
    case .toolsListChanged: print("Tools changed")
    default: break
    }
}

// Filtered streams
for await progress in client.progressUpdates { ... }
for await log in client.logMessages { ... }
```

### Server-to-Client (Bi-directional)

```swift
// Handle roots/list requests from the server
client.setRootsHandler {
    return [MCPRoot(uri: "file:///project", name: "My Project")]
}

// Handle sampling requests from the server
client.setSamplingHandler { request in
    // Forward to your LLM, return the response
    return MCPSamplingResponse(
        model: "claude-3",
        role: .assistant,
        content: .text("Response text")
    )
}
```

## Testing

Use `MCPClientProtocol` to mock the client in your tests:

```swift
final class MockMCPClient: MCPClientProtocol {
    func callTool(name: String, arguments: [String: AnyCodableValue]?) async throws -> MCPToolResult {
        return MCPToolResult(content: [.text("mocked result")])
    }
    // ... implement other protocol methods
}
```

## Error Handling

```swift
do {
    let result = try await client.callTool(name: "analyze", arguments: [:])
} catch let error as MCPError {
    switch error {
    case .connectionFailed(let reason): print("Connection failed: \(reason)")
    case .requestFailed(let code, let message, _): print("RPC error \(code): \(message)")
    case .timeout: print("Request timed out")
    case .invalidResponse: print("Invalid server response")
    case .transportClosed: print("Connection closed unexpectedly")
    case .processSpawnFailed(let reason): print("Subprocess failed: \(reason)")
    }
}
```

## MCPExplorer

The package includes **MCPExplorer**, a SwiftUI macOS app for interactively connecting to MCP servers, browsing tools/resources/prompts, and watching notifications in real time.

Build and run:

```bash
swift build --product MCPExplorer
.build/debug/MCPExplorer
```

## Architecture

```
MCPClient/
├── MCPClientConnection     # Actor — manages connection lifecycle and JSON-RPC
├── MCPClientProtocol       # Protocol — testable interface
├── MCPMessageDispatcher    # Request/response correlation
├── Transport/
│   ├── MCPTransport        # Protocol — pluggable transport layer
│   ├── HTTPSSETransport    # HTTP POST + Server-Sent Events
│   ├── WebSocketTransport  # WebSocket text frames
│   ├── StdioTransport      # Subprocess stdin/stdout
│   └── SSEParser           # SSE event stream parser
├── AnyCodableValue         # Type-safe JSON value wrapper
├── JSONRPCTypes            # JSON-RPC 2.0 envelope types
├── MCPTypes                # Capabilities, initialization
├── MCPError                # Error enum
└── *Types.swift            # Resources, prompts, sampling, roots, notifications, completion
```

## License

MIT
