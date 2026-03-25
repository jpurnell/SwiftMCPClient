# Coding Rules for SwiftMCPClient

**Updated:** March 25, 2026
**Purpose:** Establish consistent patterns across the codebase for safety, concurrency, and protocol correctness

---

## 1. File Organization

### Structure
- **One primary concept per file** (actor, struct, enum, or protocol)
- **Directory structure reflects conceptual hierarchy**
  ```
  Sources/MCPClient/
  ├── MCPClientConnection.swift     # Core actor
  ├── MCPClientProtocol.swift       # Testability protocol
  ├── MCPTypes.swift                # MCP domain types
  ├── MCPError.swift                # Error enum
  ├── JSONRPCTypes.swift            # JSON-RPC 2.0 types
  ├── AnyCodableValue.swift         # JSON value wrapper
  └── Transport/
      ├── MCPTransport.swift        # Transport protocol
      ├── HTTPSSETransport.swift    # HTTP/SSE implementation
      ├── StdioTransport.swift      # Stdio implementation
      └── SSEParser.swift           # SSE protocol parser
  ```
- **File naming**: PascalCase for type files, descriptive names
- **Transport implementations** live in `Transport/` subdirectory

### File Headers
```swift
//
//  FileName.swift
//  MCPClient
//
//  Created by Justin Purnell on [Date].
//

import Foundation
```

**No other imports allowed.** This is a zero-dependency library.

---

## 2. Code Style

### Protocol-Oriented Design
- Define protocols for all extension points (`MCPTransport`, `MCPClientProtocol`)
- Prefer protocol conformance over inheritance
- Use `any Protocol` for existential types in public APIs

```swift
public func runWorkflow(client: any MCPClientProtocol) async throws {
    let result = try await client.callTool(name: "analyze", arguments: [:])
    // ...
}
```

### Function Signatures
- **Public API**: All user-facing functions/types marked `public`
- **Descriptive parameter labels**: Use external labels for clarity
  ```swift
  public func initialize(clientName: String, clientVersion: String) async throws -> InitializeResult
  ```
- **Default parameters**: Provide sensible defaults where appropriate
  ```swift
  public func callTool(name: String, arguments: [String: AnyCodableValue] = [:]) async throws -> MCPToolResult
  ```

### Guard Clauses & Safety Patterns

Use `guard` statements for state validation. **Never use force operations in production code.**

#### Forbidden Patterns (MANDATORY)

The following patterns are **prohibited** in production code:

| Pattern | Problem | Alternative |
|---------|---------|-------------|
| `value!` | Crashes if nil | `guard let value else { throw/return }` |
| `value as! Type` | Crashes if wrong type | `guard let typed = value as? Type else { throw }` |
| `try!` | Crashes on any error | `do { try ... } catch { ... }` |
| `array.first!` | Crashes if empty | `guard let first = array.first else { throw }` |
| `fatalError()` | Unrecoverable crash | `throw MCPError(...)` |
| `precondition()` | Disabled in Release | `guard ... else { throw }` |

#### Exception: Test Code

Force unwraps are acceptable in test code only when the test is specifically verifying a value exists, and a crash is the desired behavior if the assertion fails.

#### Safe Patterns

```swift
// ❌ BAD: Force unwrap
let url = URL(string: urlString)!

// ✅ GOOD: Safe unwrap with error
guard let url = URL(string: urlString) else {
    throw MCPError.connectionFailed(reason: "Invalid URL: \(urlString)")
}
```

```swift
// ❌ BAD: Assume response exists
let result = response.result!

// ✅ GOOD: Check and throw
guard let result = response.result else {
    throw MCPError.invalidResponse
}
```

---

## 3. Concurrency & Thread Safety

### Actor Isolation (MANDATORY)

All mutable state must be protected by actor isolation or Sendable conformance.

```swift
// ✅ GOOD: Actor for mutable connection state
public actor MCPClientConnection {
    private var nextRequestID: Int = 1
    private var isConnected: Bool = false
    // ...
}
```

### Sendable Conformance

All public types must be `Sendable`:

| Type Kind | Approach |
|-----------|----------|
| Immutable struct | Automatic `Sendable` conformance |
| Actor | Inherently `Sendable` |
| Class with mutable state | Use `actor` instead, or `@unchecked Sendable` with manual synchronization |
| Protocol | Include `: Sendable` in definition |
| Enum | Automatic if all associated values are `Sendable` |

```swift
// ✅ Transport protocol requires Sendable
public protocol MCPTransport: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func disconnect() async throws
}
```

### Async/Await Patterns

- All transport and client operations are `async throws`
- Never block threads — always use structured concurrency
- Use `Task` groups for parallel operations where appropriate
- Avoid `Task.detached` unless truly needed

```swift
// ❌ BAD: Blocking wait
let result = semaphore.wait(timeout: .now() + 30)

// ✅ GOOD: Async wait
let result = try await transport.receive()
```

---

## 4. Error Handling

### Single Error Enum

All errors use `MCPError`. Do not create additional error types without updating the Error Registry in `00_MASTER_PLAN.md`.

```swift
public enum MCPError: Error, Sendable, Equatable {
    case connectionFailed(reason: String)
    case requestFailed(code: Int, message: String)
    case timeout
    case invalidResponse
}
```

### Error Propagation

- Transport errors should be wrapped in `MCPError`
- Never swallow errors silently
- Include context in error messages

```swift
// ❌ BAD: Silent failure
let data = try? transport.receive()

// ✅ GOOD: Explicit error handling
do {
    let data = try await transport.receive()
    return data
} catch {
    throw MCPError.connectionFailed(reason: "Transport receive failed: \(error)")
}
```

---

## 5. JSON-RPC & MCP Protocol Compliance

### Request ID Management

- Request IDs must be unique within a connection
- Use auto-incrementing integers
- Never reuse IDs, even after reconnection

### Message Encoding

- All JSON-RPC messages use `Codable` for encoding/decoding
- Use `JSONEncoder`/`JSONDecoder` with default settings
- `AnyCodableValue` wraps arbitrary JSON values type-safely

### MCP Specification Alignment

- Protocol version must match the MCP spec version being implemented
- All MCP method names must match the spec exactly (e.g., `tools/list`, not `listTools`)
- Response types must handle optional fields gracefully (MCP servers vary)

---

## 6. Transport Layer Rules

### Transport Protocol Contract

All `MCPTransport` implementations must:
1. Be safe to call `connect()` multiple times (idempotent or throw)
2. Throw `MCPError.connectionFailed` if `send()`/`receive()` called before `connect()`
3. Be safe to call `disconnect()` without prior `connect()`
4. Clean up resources on `disconnect()` (no leaks)

### HTTPSSETransport Specifics

- SSE connection runs as a background `Task`
- Reconnection uses exponential backoff
- HTTP POST for sending, SSE stream for receiving
- Endpoint URL discovered from SSE `endpoint` event

### StdioTransport Specifics

- Must manage subprocess lifecycle (spawn, communicate, terminate)
- stdin for sending, stdout for receiving
- stderr should be captured but not mixed with JSON-RPC messages
- Process termination must be handled gracefully

---

## 7. Testing Standards

### Test Organization

- One test file per source file (e.g., `MCPClientConnectionTests.swift`)
- Mock types in dedicated files (`MockTransport.swift`, `MockURLProtocol.swift`)
- Use Swift Testing framework (`@Test`, `#expect`, `@Suite`)

### Mock Strategy

- `MockTransport` for testing `MCPClientConnection` without network
- `MockURLProtocol` for testing `HTTPSSETransport` without network
- Mocks should be configurable (inject responses, simulate errors)

### Test Naming

Use descriptive test names that read as sentences:

```swift
@Test("callTool sends correct request and returns result")
func callToolSendsCorrectRequest() async throws { ... }

@Test("Throws connectionFailed when transport fails to connect")
func throwsConnectionFailedWhenTransportFails() async throws { ... }
```

### What to Test

- All public API methods
- Error paths (connection failure, invalid response, timeout)
- Edge cases (empty responses, missing fields, reconnection)
- Protocol compliance (correct JSON-RPC structure, MCP method names)

---

## 8. Documentation Standards

### DocC Requirements

All public types and methods must have:
1. A summary line
2. Parameter documentation (for methods with parameters)
3. Return value documentation
4. Throws documentation (for throwing methods)
5. Usage example for key types

```swift
/// Call a tool on the MCP server.
///
/// Sends a `tools/call` request with the given tool name and arguments,
/// then decodes the response into an ``MCPToolResult``.
///
/// - Parameters:
///   - name: The name of the tool to call (must match a name from ``listTools()``).
///   - arguments: The arguments to pass to the tool. Defaults to empty.
/// - Returns: The tool's result containing one or more content blocks.
/// - Throws: ``MCPError/requestFailed(code:message:)`` if the server returns an error.
/// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
public func callTool(name: String, arguments: [String: AnyCodableValue] = [:]) async throws -> MCPToolResult
```

### Documentation Must Be Generic

All doc examples must use generic MCP concepts, not project-specific references (no geo-audit, GeoSEO, etc.).

---

## 9. Dependency Rules (MANDATORY)

### Zero External Dependencies

This library imports **Foundation only**. No exceptions.

- No AsyncHTTPClient
- No SwiftNIO
- No swift-log
- No swift-metrics
- No Combine (use async/await instead)

If a feature requires an external dependency, it must be proposed as an optional extension or separate package.

---

**Last Updated:** 2026-03-25
