# Design Proposal: Phase 2 — Spec Compliance + StdioTransport

**Master Plan Reference:** Phase 2: Spec Compliance + StdioTransport (v0.2.0)
**Date:** 2026-03-25

---

## 1. Objective

Bring SwiftMCPClient into compliance with the MCP specification (2024-11-05) and implement the StdioTransport for local MCP servers. Phase 1 covered tools-only over HTTP/SSE. Phase 2 fills the protocol gaps that would cause failures with spec-compliant servers.

**Five deliverables:**
1. StdioTransport — spawn and communicate with local MCP server subprocesses
2. `notifications/initialized` — mandatory post-handshake notification
3. `ping` — bidirectional keepalive request/response
4. Configurable protocol version
5. Cursor-based pagination for `tools/list`

---

## 2. Proposed Architecture

### New Files

| File | Purpose |
|------|---------|
| `Sources/MCPClient/Transport/StdioTransport.swift` | **Rewrite** — Process-based transport via stdin/stdout |
| `Sources/MCPClient/JSONRPCNotification.swift` | New type for notifications (no `id` field) |
| `Tests/MCPClientTests/StdioTransportTests.swift` | Unit tests for StdioTransport |
| `Tests/MCPClientTests/PaginationTests.swift` | Tests for cursor-based pagination |

### Modified Files

| File | Changes |
|------|---------|
| `MCPClientConnection.swift` | Add `notifications/initialized` after handshake, add `ping()`, add `listTools()` pagination, accept `protocolVersion` parameter |
| `MCPClientProtocol.swift` | Add `ping()` method |
| `JSONRPCTypes.swift` | Add `JSONRPCNotification` struct (no `id` field) |
| `MCPTransport.swift` | Add `sendNotification(_:)` method (fire-and-forget, no response expected) |
| `MCPError.swift` | Add `.transportClosed` case for subprocess termination, `.processSpawnFailed(reason:)` for StdioTransport |

---

## 3. API Surface

### 3a. StdioTransport

```swift
/// Spawns an MCP server as a local subprocess and communicates via
/// newline-delimited JSON over stdin/stdout pipes.
public actor StdioTransport: MCPTransport {
    /// Creates a new stdio transport.
    ///
    /// - Parameters:
    ///   - command: Path to the MCP server executable.
    ///   - arguments: Command-line arguments for the server.
    ///   - environment: Additional environment variables (merged with current process env).
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    )

    public func connect() async throws    // Spawns subprocess
    public func disconnect() async throws // Closes stdin, waits, SIGTERM, SIGKILL
    public func send(_ data: Data) async throws
    public func receive() async throws -> Data
}
```

**Message framing:** Newline-delimited JSON per MCP spec. Each JSON-RPC message is one line on stdin/stdout. No embedded newlines in messages.

**Subprocess lifecycle:**
1. `connect()` — spawn `Process`, configure stdin/stdout pipes, start
2. `send()` — write JSON + `\n` to stdin pipe
3. `receive()` — read next line from stdout pipe, return as `Data`
4. `disconnect()` — close stdin, wait 5s, SIGTERM, wait 2s, SIGKILL

### 3b. notifications/initialized

Sent automatically by `MCPClientConnection.initialize()` after a successful handshake:

```swift
// Inside MCPClientConnection.initialize():
// 1. send "initialize" request, get response
// 2. send "notifications/initialized" notification (fire-and-forget)
// 3. return InitializeResult
```

JSON on the wire:
```json
{"jsonrpc":"2.0","method":"notifications/initialized"}
```

No `id`, no `params`, no response expected.

### 3c. JSONRPCNotification

```swift
/// A JSON-RPC 2.0 notification (no `id` field, no response expected).
public struct JSONRPCNotification: Codable, Sendable {
    public let jsonrpc: String  // Always "2.0"
    public let method: String
    public let params: AnyCodableValue?

    public init(method: String, params: AnyCodableValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}
```

### 3d. ping

```swift
// New method on MCPClientConnection:
/// Send a ping to the MCP server and await the response.
///
/// - Returns: `true` if the server responded.
/// - Throws: ``MCPError/timeout`` if no response within the transport timeout.
public func ping() async throws -> Bool

// New method on MCPClientProtocol:
func ping() async throws -> Bool
```

Request: `{"jsonrpc":"2.0","id":N,"method":"ping"}`
Response: `{"jsonrpc":"2.0","id":N,"result":{}}`

### 3e. Configurable Protocol Version

```swift
// Updated MCPClientConnection.initialize():
public func initialize(
    clientName: String,
    clientVersion: String,
    protocolVersion: String = "2024-11-05"
) async throws -> InitializeResult
```

Default is the current spec version. Users can override for testing or future versions.

### 3f. Pagination for tools/list

```swift
// Updated MCPClientConnection.listTools():
/// Discover available tools on the MCP server.
///
/// Automatically paginates if the server returns a `nextCursor`.
/// Returns all tools across all pages.
public func listTools() async throws -> [MCPTool]
```

The public API stays the same (returns `[MCPTool]`). Internally, it loops on `nextCursor` until all pages are fetched. No public cursor API needed — this is a convenience client, not a low-level protocol library.

---

## 4. MCPTransport Protocol Changes

```swift
public protocol MCPTransport: Sendable {
    func connect() async throws
    func disconnect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
}
```

**No changes to the protocol.** Notifications are sent via the existing `send()` method — the transport doesn't need to distinguish requests from notifications; that's the client's job.

---

## 5. Error Registry Updates

New cases to add to `MCPError`:

| Case | When Thrown |
|------|------------|
| `.processSpawnFailed(reason:)` | StdioTransport cannot start the subprocess |
| `.transportClosed` | Subprocess exited or pipe closed unexpectedly |

---

## 6. Constraints & Compliance

- **Concurrency:** StdioTransport is an `actor` — all subprocess state is isolated
- **Sendable:** All new types (JSONRPCNotification) are Sendable
- **Safety:** No force unwraps, no `fatalError`. Process termination uses graceful shutdown sequence
- **Zero dependencies:** Uses Foundation `Process`, `Pipe` — no external packages
- **Platform:** `Process` is available on macOS and Linux. Not available on iOS/tvOS/watchOS — StdioTransport will be `#if os(macOS) || os(Linux)` gated

---

## 7. Dependencies

**Internal:**
- `JSONRPCTypes.swift` — new `JSONRPCNotification` type
- `MCPError.swift` — new error cases
- `MCPClientConnection.swift` — all behavioral changes

**External:** None

---

## 8. Test Strategy

### StdioTransport Tests
- **Golden path:** Connect → send → receive → disconnect with a real `cat` process (echoes stdin to stdout)
- **Process spawn failure:** Invalid command → `.processSpawnFailed`
- **Process termination:** Server exits mid-conversation → `.transportClosed`
- **Disconnect sequence:** Verify SIGTERM sent after stdin close
- **Message framing:** Verify newline-delimited output

### notifications/initialized Tests
- **Verify sent after handshake:** MockTransport captures sent data, verify notification appears after initialize response
- **Verify no `id` field:** Decode sent notification, confirm no `id`
- **Verify no response consumed:** Initialize still returns the correct `InitializeResult`

### ping Tests
- **Golden path:** Send ping, receive `{"result":{}}`, return true
- **Timeout/error:** Server doesn't respond → throws MCPError

### Pagination Tests
- **Single page (no cursor):** Existing behavior unchanged
- **Multi-page:** MockTransport returns cursor on first call, tools on second call
- **Empty response:** No tools returned, no crash

### Protocol Version Tests
- **Default version:** Verify `"2024-11-05"` sent when not specified
- **Custom version:** Verify custom string passed through

**Reference truth:** MCP specification 2024-11-05 at spec.modelcontextprotocol.io

---

## 9. ADR Check

- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md` — no related decisions
- [ ] New ADR required: **Yes**

**New ADR Draft:**
- Title: StdioTransport uses Foundation Process (not posix_spawn)
- Category: architecture
- Key decision: Use `Foundation.Process` for subprocess management for portability between macOS and Linux, accepting that iOS/tvOS/watchOS are excluded via conditional compilation.

---

## 10. Open Questions

1. **Should `listTools()` expose a paginated API?** — Proposed: No. Auto-paginate internally. Simpler API wins for a client library. If someone needs page-by-page control, they can use `sendRequest` directly (or we add it later).

2. **Should `ping()` have a configurable timeout?** — Proposed: No. Use the transport's existing timeout. Keep the API minimal.

3. **StdioTransport on watchOS/tvOS/iOS?** — Proposed: Exclude via `#if`. These platforms don't spawn subprocesses. The Package.swift platform list stays as-is; the type just isn't available.

---

## 11. Documentation Strategy

**Documentation Type:** Narrative Article Required

- Combines 3+ APIs (StdioTransport, ping, notifications)
- Requires background on MCP stdio vs HTTP/SSE transport model
- New article: `TransportGuide.md` in MCPClient.docc

---

## 12. Implementation Order

Deliver in this sequence to keep tests green at each step:

1. **JSONRPCNotification type** + tests (new file, no existing code changes)
2. **MCPError new cases** + tests (additive)
3. **`notifications/initialized`** in `MCPClientConnection.initialize()` + tests
4. **`ping()`** on MCPClientConnection + MCPClientProtocol + tests
5. **Configurable `protocolVersion`** parameter + tests
6. **Pagination** for `tools/list` + tests
7. **StdioTransport** implementation + tests (biggest piece, saved for last so all protocol work is solid)
8. **DocC article** — TransportGuide.md
9. **Tag v0.2.0**
