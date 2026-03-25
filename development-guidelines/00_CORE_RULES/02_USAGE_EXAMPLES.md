# Usage Examples for SwiftMCPClient

**Purpose:** Real-world API usage patterns and examples for reference.

---

## Quick Reference

### Basic Usage

```swift
import MCPClient

// 1. Create a transport
let transport = HTTPSSETransport(
    url: URL(string: "https://my-server.example.com/sse")!
)

// 2. Create and initialize the client
let client = MCPClientConnection(transport: transport)
let info = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")

// 3. Discover and call tools
let tools = try await client.listTools()
let result = try await client.callTool(name: tools.first!.name, arguments: [:])
print(result.content.first?.text ?? "No output")
```

---

## Core Patterns

### Pattern 1: Remote MCP Server via HTTP/SSE

**When to use:** Connecting to a hosted MCP server over the network.

```swift
let transport = HTTPSSETransport(
    url: URL(string: "https://mcp.example.com/sse")!,
    headers: ["Authorization": "Bearer my-api-key"],
    timeoutInterval: 30.0
)
let client = MCPClientConnection(transport: transport)
let info = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")
```

### Pattern 2: Protocol-Based Dependency Injection

**When to use:** When your code needs to be testable without a real MCP server.

```swift
struct AuditService {
    let client: any MCPClientProtocol

    func analyze(url: String) async throws -> String {
        let result = try await client.callTool(
            name: "analyze_url",
            arguments: ["url": .string(url)]
        )
        return result.content.first?.text ?? ""
    }
}

// Production
let service = AuditService(client: realClient)

// Tests
let mock = MockClient(result: MCPToolResult(content: [MCPContent(type: "text", text: "mocked")]))
let service = AuditService(client: mock)
```

---

## Common Workflows

### Workflow 1: Discover → Filter → Call

```swift
// Step 1: Initialize
let info = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")

// Step 2: Discover tools
let tools = try await client.listTools()

// Step 3: Filter for relevant tools
let analyzerTools = tools.filter { $0.name.hasPrefix("analyze_") }

// Step 4: Call each tool and collect results
var results: [String: MCPToolResult] = [:]
for tool in analyzerTools {
    let result = try await client.callTool(name: tool.name, arguments: arguments)
    results[tool.name] = result
}
```

### Workflow 2: Build Complex Arguments

```swift
let arguments: [String: AnyCodableValue] = [
    "url": .string("https://example.com"),
    "options": .object([
        "depth": .integer(3),
        "follow_redirects": .bool(true),
        "headers": .object([
            "User-Agent": .string("MyBot/1.0")
        ])
    ]),
    "tags": .array([.string("seo"), .string("performance")])
]

let result = try await client.callTool(name: "crawl_site", arguments: arguments)
```

---

## Error Handling Examples

### Handling Specific Errors

```swift
do {
    let result = try await client.callTool(name: "analyze", arguments: [:])
    print("Success: \(result.content.first?.text ?? "")")
} catch MCPError.connectionFailed(let reason) {
    print("Connection failed: \(reason)")
    // Retry with backoff, or show connection error UI
} catch MCPError.requestFailed(let code, let message) {
    print("Server error \(code): \(message)")
    // Log the error, possibly retry for transient errors
} catch MCPError.timeout {
    print("Request timed out")
    // Retry or increase timeout
} catch MCPError.invalidResponse {
    print("Could not decode server response")
    // Log for debugging, likely a protocol mismatch
}
```

### Tool-Level Error Handling

```swift
let result = try await client.callTool(name: "validate", arguments: args)

// Tool executed successfully at the transport level but reported a logical error
if result.isError == true {
    let errorMessage = result.content.first?.text ?? "Unknown tool error"
    print("Tool error: \(errorMessage)")
}
```

---

## Anti-Patterns (What NOT to Do)

### Anti-Pattern 1: Calling Tools Before Initialize

```swift
// ❌ BAD — transport not connected yet
let result = try await client.callTool(name: "analyze", arguments: [:])

// ✅ GOOD — always initialize first
let _ = try await client.initialize(clientName: "app", clientVersion: "1.0")
let result = try await client.callTool(name: "analyze", arguments: [:])
```

### Anti-Pattern 2: Ignoring Tool-Level Errors

```swift
// ❌ BAD — assumes tool always succeeds
let text = result.content.first!.text!

// ✅ GOOD — check for errors and handle missing content
guard result.isError != true else {
    throw MyError.toolFailed(result.content.first?.text ?? "Unknown error")
}
guard let text = result.content.first?.text else {
    throw MyError.emptyResult
}
```

### Anti-Pattern 3: Hardcoding Tool Names

```swift
// ❌ BAD — assumes tool exists
try await client.callTool(name: "score_technical_seo", arguments: [:])

// ✅ GOOD — discover tools first, validate existence
let tools = try await client.listTools()
guard tools.contains(where: { $0.name == toolName }) else {
    throw MyError.toolNotFound(toolName)
}
try await client.callTool(name: toolName, arguments: [:])
```

---

**Last Updated:** 2026-03-25
