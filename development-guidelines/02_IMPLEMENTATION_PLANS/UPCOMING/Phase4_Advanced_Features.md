# Design Proposal: Phase 4 — Advanced Features (v0.4.0)

**Status:** Proposed
**Target:** v0.4.0

---

## Goal

Add bidirectional communication to MCPClientConnection — progress tracking,
request cancellation, server logging, argument completion, and roots. This
phase introduces the architectural foundation for handling server-to-client
notifications and requests.

## Architecture: The Notification Problem

Phases 1–3 used a simple request/response model: send a request, receive the
next message as the response. This breaks when the server interleaves
notifications (progress updates, log messages) between the request and response.

### Current Flow (breaks with notifications)

```
Client → send(request)
Client ← receive() → might get a notification instead of the response!
```

### New Flow: Message Dispatcher

```
Client → send(request)
         ↓
    [Message Loop] reads all incoming messages
         ├── JSON-RPC Response (has id) → route to pending request
         ├── Notification (no id)       → route to notification stream
         └── Request (has id + method)  → route to incoming request handler (roots)
```

### Implementation: MCPMessageDispatcher

A private actor within MCPClientConnection that:

1. **Runs a background read loop** consuming all transport messages
2. **Routes responses** to waiting continuations (keyed by request ID)
3. **Routes notifications** to an `AsyncStream<MCPNotification>`
4. **Routes incoming requests** (like `roots/list`) to a handler callback

```swift
private actor MCPMessageDispatcher {
    private let transport: MCPTransport
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var notificationContinuation: AsyncStream<MCPNotification>.Continuation?
    private var incomingRequestHandler: ((JSONRPCRequest) async -> JSONRPCResponse?)?
    private var readTask: Task<Void, Never>?

    func start()  // Begin reading from transport
    func stop()   // Cancel read task
    func waitForResponse(id: Int) async throws -> JSONRPCResponse
}
```

### Impact on MCPClientConnection

- `sendRequest()` changes: instead of calling `transport.receive()` directly,
  it registers a continuation with the dispatcher and awaits the response
- New public `notifications` property exposes `AsyncStream<MCPNotification>`
- New `setRootsHandler()` for registering a callback for `roots/list` requests

---

## MCP Spec Reference

### Progress Notifications

**Client sends** a `progressToken` in `params._meta` of any request:
```json
{"params": {"_meta": {"progressToken": "tok-1"}, "name": "tool_name", ...}}
```

**Server sends** `notifications/progress` referencing that token:
```json
{"method": "notifications/progress", "params": {"progressToken": "tok-1", "progress": 50, "total": 100}}
```

- `progressToken`: string | integer (unique per active request)
- `progress`: number (must increase monotonically)
- `total`: number? (total if known)

### Request Cancellation

**Either side** sends `notifications/cancelled`:
```json
{"method": "notifications/cancelled", "params": {"requestId": 1, "reason": "User cancelled"}}
```

- `requestId`: string | integer (the request ID to cancel)
- `reason`: string? (optional human-readable reason)
- `initialize` MUST NOT be cancelled
- Receiver SHOULD stop processing and NOT send a response

### Logging

**Client sends** `logging/setLevel` to set minimum severity:
```json
{"method": "logging/setLevel", "params": {"level": "info"}}
```

**Server sends** `notifications/message`:
```json
{"method": "notifications/message", "params": {"level": "error", "logger": "db", "data": "Connection failed"}}
```

Log levels (RFC 5424): debug, info, notice, warning, error, critical, alert, emergency

### Completion

**Client sends** `completion/complete`:
```json
{
    "method": "completion/complete",
    "params": {
        "ref": {"type": "ref/prompt", "name": "code_review"},
        "argument": {"name": "language", "value": "py"}
    }
}
```

**Response:**
```json
{"result": {"completion": {"values": ["python", "pytorch"], "total": 10, "hasMore": true}}}
```

Reference types: `ref/prompt` (name) or `ref/resource` (uri).

### Roots (Server → Client Request)

**Server sends** `roots/list` request TO the client.
**Client responds** with `{"roots": [{"uri": "file:///project", "name": "Project"}]}`.
**Client declares** `capabilities.roots.listChanged` in initialize.
**Client sends** `notifications/roots/list_changed` when roots change.

---

## New Types

### MCPNotification (MCPNotificationTypes.swift)

```swift
/// A server-to-client notification.
public enum MCPNotification: Sendable {
    case progress(MCPProgressNotification)
    case resourcesListChanged
    case resourceUpdated(uri: String)
    case promptsListChanged
    case toolsListChanged
    case logMessage(MCPLogMessage)
}

public struct MCPProgressNotification: Sendable, Equatable {
    public let progressToken: AnyCodableValue  // string or integer
    public let progress: Double
    public let total: Double?
}

public struct MCPLogMessage: Sendable, Equatable {
    public let level: MCPLogLevel
    public let logger: String?
    public let data: AnyCodableValue
}

public enum MCPLogLevel: String, Codable, Sendable, Equatable, Comparable {
    case debug, info, notice, warning, error, critical, alert, emergency
}
```

### MCPRoot (MCPRootTypes.swift)

```swift
public struct MCPRoot: Codable, Sendable, Equatable {
    public let uri: String
    public let name: String?
}
```

### MCPCompletionResult (MCPCompletionTypes.swift)

```swift
public struct MCPCompletionResult: Codable, Sendable {
    public let values: [String]
    public let total: Int?
    public let hasMore: Bool?
}

public enum MCPCompletionRef: Sendable, Equatable {
    case prompt(name: String)
    case resource(uri: String)
}
```

### Client Capabilities

```swift
public struct ClientCapabilities: Codable, Sendable {
    public let roots: RootsClientCapability?
}

public struct RootsClientCapability: Codable, Sendable {
    public let listChanged: Bool?
}
```

---

## New Methods on MCPClientConnection

```swift
// Notifications stream
public var notifications: AsyncStream<MCPNotification> { get }

// Logging
public func setLogLevel(_ level: MCPLogLevel) async throws

// Completion
public func complete(ref: MCPCompletionRef, argumentName: String, argumentValue: String) async throws -> MCPCompletionResult

// Cancellation
public func cancelRequest(id: Int, reason: String?) async throws

// Roots
public func setRootsHandler(_ handler: @Sendable @escaping () async -> [MCPRoot]) async
public func notifyRootsChanged() async throws

// Initialize — updated to accept client capabilities
public func initialize(
    clientName: String,
    clientVersion: String,
    protocolVersion: String = "2024-11-05",
    capabilities: ClientCapabilities? = nil
) async throws -> InitializeResult
```

### Progress Token Support

`callTool`, `readResource`, and `getPrompt` gain an optional `progressToken` parameter:

```swift
public func callTool(
    name: String,
    arguments: [String: AnyCodableValue] = [:],
    progressToken: AnyCodableValue? = nil
) async throws -> MCPToolResult
```

---

## Delivery Order

### 1. MCPLogLevel + MCPLogMessage + MCPProgressNotification types
- New file: `MCPNotificationTypes.swift`
- RED: Tests for Codable, Equatable, Comparable (log levels)
- GREEN: Implement types
- REFACTOR

### 2. MCPNotification enum
- RED: Tests for all cases
- GREEN: Implement enum
- REFACTOR

### 3. MCPMessageDispatcher — response routing
- RED: Tests that responses route to the correct pending request
- GREEN: Implement dispatcher with response routing only
- REFACTOR
- **Key milestone:** replaces direct `transport.receive()` in `sendRequest()`

### 4. MCPMessageDispatcher — notification routing
- RED: Tests that notifications route to AsyncStream
- GREEN: Add notification stream to dispatcher
- REFACTOR
- **Key milestone:** `MCPClientConnection.notifications` property works

### 5. Progress token support on requests
- RED: Tests that `_meta.progressToken` appears in sent requests
- GREEN: Add progressToken parameter to callTool/readResource/getPrompt
- REFACTOR

### 6. Request cancellation
- RED: Tests for cancelRequest sending correct notification
- GREEN: Implement cancelRequest()
- REFACTOR

### 7. Logging — setLogLevel
- RED: Tests for setLogLevel sending correct request
- GREEN: Implement setLogLevel()
- REFACTOR

### 8. Completion — complete()
- New file: `MCPCompletionTypes.swift`
- RED: Tests for complete() with prompt ref, resource ref
- GREEN: Implement complete() and types
- REFACTOR

### 9. Roots — types + handler + notify
- New file: `MCPRootTypes.swift`
- RED: Tests for roots handler, notifyRootsChanged
- GREEN: Implement roots types, handler, notification
- REFACTOR

### 10. MCPMessageDispatcher — incoming request handling (roots/list)
- RED: Tests that incoming roots/list requests invoke handler
- GREEN: Wire dispatcher to call roots handler and send response
- REFACTOR
- **Key milestone:** full bidirectional communication

### 11. Client capabilities in initialize
- RED: Tests that capabilities appear in initialize request
- GREEN: Add ClientCapabilities parameter to initialize()
- REFACTOR

### 12. MCPClientProtocol updates
- Add relevant new methods to protocol
- REFACTOR

### 13. Documentation
- NotificationsGuide.md DocC article
- Update MCPClient.md topics
- DocC comments on all new public API

### 14. Release
- All tests passing, zero warnings
- Tag v0.4.0
- Push to GitHub

---

## Risk: Breaking Change to sendRequest()

Step 3 replaces the `transport.receive()` call in `sendRequest()` with
dispatcher-based response routing. This is internal but critical — all
existing tests MUST keep passing. The dispatcher is tested in isolation first,
then wired in. If any existing test breaks, it means the dispatcher isn't
correctly routing responses to pending requests.

## Risk: Background Task Lifecycle

The dispatcher's read loop is a background `Task`. It must:
- Start on first `connect()`/`initialize()`
- Stop on `disconnect()`
- Handle transport closure gracefully (complete the notification stream)
- Not leak — cancelled tasks must clean up pending continuations

---

## Files Changed / Created

| File | Action |
|------|--------|
| `Sources/MCPClient/MCPNotificationTypes.swift` | NEW |
| `Sources/MCPClient/MCPCompletionTypes.swift` | NEW |
| `Sources/MCPClient/MCPRootTypes.swift` | NEW |
| `Sources/MCPClient/MCPMessageDispatcher.swift` | NEW |
| `Sources/MCPClient/MCPClientConnection.swift` | MODIFY — dispatcher integration, new methods |
| `Sources/MCPClient/MCPClientProtocol.swift` | MODIFY — new methods |
| `Sources/MCPClient/MCPTypes.swift` | MODIFY — ClientCapabilities |
| `Sources/MCPClient/MCPClient.docc/MCPClient.md` | MODIFY — topics |
| `Sources/MCPClient/MCPClient.docc/NotificationsGuide.md` | NEW |
| `Tests/MCPClientTests/MCPNotificationTypesTests.swift` | NEW |
| `Tests/MCPClientTests/MCPCompletionTypesTests.swift` | NEW |
| `Tests/MCPClientTests/MCPRootTypesTests.swift` | NEW |
| `Tests/MCPClientTests/MCPMessageDispatcherTests.swift` | NEW |
| `Tests/MCPClientTests/MCPClientConnectionTests.swift` | MODIFY — ~25 new tests |
