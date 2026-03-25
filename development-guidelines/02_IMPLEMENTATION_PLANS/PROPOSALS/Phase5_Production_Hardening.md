# Phase 5: Production Hardening (v1.0.0)

**Status:** APPROVED
**Author:** Claude
**Date:** 2026-03-25

---

## Goal

Harden SwiftMCPClient from v0.4.0 → v1.0.0 by closing spec compliance gaps, adding graceful lifecycle management, improving error fidelity, adding Sampling capability, WebSocket transport, performance benchmarks, AsyncSequence streaming API, and verifying cross-platform compatibility. Includes a thorough migration guide for geo-audit consumers.

---

## MCP Spec Compliance Audit (2024-11-05)

### Gap 1: MCPContent is a flat struct — should be a discriminated union

**Current:** `MCPContent` has `type`, `text`, `mimeType` as optional fields.
**Spec:** Tool call results use the same content types as prompt messages: `TextContent`, `ImageContent`, `EmbeddedResource`. Each has different required fields, plus optional `annotations`.

**Fix:** Replace `MCPContent` with a proper enum matching `MCPPromptContent` pattern:
```swift
public enum MCPContent: Codable, Sendable, Equatable {
    case text(String, annotations: MCPAnnotations?)
    case image(data: String, mimeType: String, annotations: MCPAnnotations?)
    case resource(MCPResourceContents, annotations: MCPAnnotations?)
}
```

**Breaking change.** Migration: `content.text` → `if case .text(let str, _) = content { ... }`

### Gap 2: Client capabilities not declared in initialize

**Current:** `initialize()` sends `"capabilities": {}` always.
**Spec:** Client should declare `roots` (with `listChanged`) and `sampling` if supported.

**Fix:** Add `ClientCapabilities` struct and parameter:
```swift
public struct ClientCapabilities: Codable, Sendable {
    public var roots: RootsCapability?
    public var sampling: SamplingCapability?
}
```

### Gap 3: No progress token support on requests

**Current:** No way for the client to attach `_meta.progressToken` to requests.
**Spec:** Clients can include `_meta: { progressToken: "..." }` on any request.

**Fix:** Add optional `progressToken` parameter to `callTool()` and other long-running methods. When provided, merge `_meta: { progressToken: value }` into the request params.

### Gap 4: ServerCapabilities missing logging

**Current:** `ServerCapabilities` only has `tools`, `resources`, `prompts`.
**Spec:** Server may also declare `logging: {}` capability.

**Fix:** Add `logging` field to `ServerCapabilities`.

### Gap 5: JSONRPCError data field not surfaced

**Current:** `MCPError.requestFailed(code:message:)` discards the `data` field.
**Spec:** JSON-RPC errors may include a `data` field with additional information.

**Fix:** `case requestFailed(code: Int, message: String, data: AnyCodableValue?)`

**Breaking change.** Migration: `.requestFailed(let code, let msg)` → `.requestFailed(let code, let msg, _)`

### Gap 6: No protocol version validation

**Current:** Client sends its version, accepts whatever the server returns.
**Spec:** Client SHOULD validate the server's protocol version is compatible.

**Fix:** Verify `protocolVersion` matches. If mismatch, throw `.connectionFailed(reason:)` with descriptive message.

---

## Sampling Capability

### Overview

MCP Sampling allows servers to request LLM completions from the client. The server sends a `sampling/createMessage` request; the client invokes its configured LLM and returns the result.

### Design

```swift
/// The handler the client provides to fulfill sampling requests.
public typealias SamplingHandler = @Sendable (MCPSamplingRequest) async throws -> MCPSamplingResult

public struct MCPSamplingRequest: Codable, Sendable {
    public let messages: [MCPSamplingMessage]
    public let modelPreferences: MCPModelPreferences?
    public let systemPrompt: String?
    public let includeContext: String?  // "none", "thisServer", "allServers"
    public let temperature: Double?
    public let maxTokens: Int
    public let stopSequences: [String]?
    public let metadata: AnyCodableValue?
}

public struct MCPSamplingMessage: Codable, Sendable {
    public let role: MCPRole
    public let content: MCPContent
}

public struct MCPModelPreferences: Codable, Sendable {
    public let hints: [MCPModelHint]?
    public let costPriority: Double?
    public let speedPriority: Double?
    public let intelligencePriority: Double?
}

public struct MCPModelHint: Codable, Sendable {
    public let name: String?
}

public struct MCPSamplingResult: Codable, Sendable {
    public let role: MCPRole
    public let content: MCPContent
    public let model: String
    public let stopReason: String?  // "endTurn", "stopSequence", "maxTokens"
}

public struct SamplingCapability: Codable, Sendable, Equatable {}
```

Integration in `MCPClientConnection`:
```swift
public func setSamplingHandler(_ handler: @escaping SamplingHandler) async
```

The dispatcher routes `sampling/createMessage` requests to this handler (same pattern as `roots/list`).

### Human-in-the-Loop

The spec recommends clients allow human review of sampling requests. The handler closure is the natural extension point — callers can implement approval UI before returning the result.

---

## WebSocket Transport

### Overview

Add `WebSocketTransport` as a third transport option, complementing HTTP/SSE and stdio.

### Design

```swift
public actor WebSocketTransport: MCPTransport {
    public init(url: URL, headers: [String: String] = [:])

    public func connect() async throws
    public func disconnect() async throws
    public func send(_ data: Data) async throws
    public func receive() async throws -> Data
}
```

Implementation uses `URLSessionWebSocketTask` (Foundation, no external deps). Messages are newline-delimited JSON over WebSocket text frames, matching the MCP transport spec.

Reconnection follows the same exponential backoff pattern as HTTPSSETransport.

---

## Performance Benchmarks

### Strategy

Use Swift's `Benchmark` package or simple `ContinuousClock`-based measurements in a dedicated test target. Key metrics:

| Benchmark | What it measures |
|-----------|-----------------|
| JSON-RPC round-trip | Encode request → decode response (MockTransport) |
| AnyCodableValue encode/decode | Large nested JSON structures |
| SSEParser throughput | Parse 10K SSE events |
| Pagination (1000 items) | paginatedList with many pages |
| Dispatcher routing | 1000 concurrent requests routed to correct continuations |

Results stored in `Benchmarks/` as baseline files for regression detection.

### Approach

Lightweight — use `ContinuousClock` in a `BenchmarkTests` test file rather than adding a dependency on the Benchmark package. This keeps zero-dependency promise. Results printed to test output for manual review; can gate CI later.

---

## AsyncSequence Streaming API

### Overview

Expose notification streams as typed `AsyncSequence` values rather than requiring callers to switch on the `MCPNotification` enum.

### Design

```swift
extension MCPClientConnection {
    /// Stream of progress notifications only.
    public var progressUpdates: AsyncStream<MCPProgressNotification> { ... }

    /// Stream of log messages only.
    public var logMessages: AsyncStream<MCPLogMessage> { ... }

    /// Stream of tool list change events.
    public var toolListChanges: AsyncStream<Void> { ... }

    /// Stream of resource update events (yields the updated URI).
    public var resourceUpdates: AsyncStream<String> { ... }
}
```

These are computed properties that filter the underlying `notifications` stream. The raw `notifications` stream remains available for callers who want everything.

This is a natural fit for Swift's async/await ecosystem and avoids Combine dependency.

---

## Lifecycle Management

### Graceful disconnect

Add `disconnect()` method:
```swift
public func disconnect() async throws {
    await dispatcher?.stop()
    dispatcher = nil
    try await transport.disconnect()
    isConnected = false
}
```

### Dispatcher cleanup

Add `stop()` to `MCPMessageDispatcher` that cancels the read task and finishes the notification stream.

---

## Error Recovery

### Request-level timeouts

```swift
public init(transport: MCPTransport, requestTimeout: Duration = .seconds(30))
```

Race request against `Task.sleep(for: requestTimeout)`. Throw `MCPError.timeout` if exceeded.

---

## Cross-Platform

### Linux compatibility

1. Verify `URLSession` streaming delegate works on Linux Foundation
2. Add `#if canImport(FoundationNetworking)` conditional if needed
3. Add GitHub Actions CI workflow for Linux (Swift 6.0 Docker)
4. Remove or adjust platform restrictions in Package.swift

---

## Documentation

### Migration Guide (DocC article)

Detailed guide covering every breaking change with before/after code samples. Sections:
1. MCPContent enum migration (pattern matching)
2. MCPError.requestFailed data field (pattern matching update)
3. New capabilities parameter on initialize()
4. New disconnect() lifecycle
5. Sampling handler setup

### Error Handling Guide (DocC article)

When each error case is thrown, recovery strategies, example code.

---

## Implementation Order (TDD for each)

| # | Task | Breaking? | TDD |
|---|------|-----------|-----|
| 1 | MCPContent → discriminated union enum | YES | RED: new enum tests + update existing. GREEN: implement enum. REFACTOR. |
| 2 | requestFailed data field | YES | RED: test data propagation. GREEN: update error + callsites. |
| 3 | Client capabilities in initialize | No | RED: test capabilities encoding. GREEN: add struct + param. |
| 4 | ServerCapabilities + logging | No | RED: test decoding. GREEN: add field. |
| 5 | Progress token support | No | RED: test _meta injection. GREEN: add param + merge logic. |
| 6 | Protocol version validation | No | RED: test mismatch throws. GREEN: add check. |
| 7 | Graceful disconnect() | No | RED: test lifecycle. GREEN: implement. |
| 8 | Request-level timeouts | No | RED: test timeout fires. GREEN: implement race. |
| 9 | Sampling capability | No | RED: test handler routing + types. GREEN: implement. |
| 10 | WebSocket transport | No | RED: test connect/send/receive. GREEN: implement. |
| 11 | AsyncSequence streaming API | No | RED: test filtered streams. GREEN: implement. |
| 12 | Performance benchmarks | No | Write benchmark tests. |
| 13 | Linux CI + verification | N/A | CI config. |
| 14 | DocC articles (migration, error handling) | N/A | Write. |
| 15 | Public API audit + final polish | Maybe | Review + update. |
| 16 | Master plan update, tag v1.0.0 | N/A | N/A |

---

## Risk Assessment

- **MCPContent breaking change:** Low risk — only geo-audit consumes this, pre-release
- **requestFailed breaking change:** Low risk — same reasoning
- **Linux URLSession:** Medium risk — FoundationNetworking may not support streaming delegates. May need compile-time gate or alternative approach.
- **WebSocket transport:** Low risk — additive, URLSessionWebSocketTask is stable Foundation API
- **Sampling:** Low risk — follows established incoming-request-handler pattern from roots
- **Benchmarks:** Low risk — informational only, no regression gates initially
