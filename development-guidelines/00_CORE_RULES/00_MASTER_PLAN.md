# SwiftMCPClient Master Plan

**Purpose:** Source of truth for project vision, architecture, and goals.

---

## Project Overview

### Mission

SwiftMCPClient is a zero-dependency Swift library implementing the Model Context Protocol (MCP) client specification. It enables any Swift application to connect to MCP servers, discover tools/resources/prompts, and invoke them — over HTTP/SSE (remote) or stdio (local subprocess) transports.

The goal is a production-quality, spec-compliant MCP client that works anywhere Swift runs: server-side (Vapor, Hummingbird), CLI tools, macOS/iOS apps, and embedded in AI agent pipelines.

### Target Users

- **Swift server-side developers** integrating MCP tools into Vapor/Hummingbird apps
- **AI agent builders** who need a Swift MCP client for tool-use workflows
- **CLI tool authors** connecting to local MCP servers (Claude Desktop pattern)
- **iOS/macOS app developers** adding MCP-powered features

### Key Differentiators

- **Zero dependencies** — Foundation only, no NIO/AsyncHTTPClient required
- **Swift 6 strict concurrency** — actor-based, fully Sendable, no data races
- **Multi-platform** — macOS 14+, iOS 17+, tvOS 17+, watchOS 10+
- **Pluggable transports** — protocol-based, easy to add custom transports
- **Spec-aligned** — tracks the MCP specification (currently 2024-11-05)

---

## Architecture

### Technology Stack

- **Language:** Swift 6.0
- **Frameworks:** Foundation only (zero external dependencies)
- **Build System:** Swift Package Manager
- **Testing:** Swift Testing framework
- **Documentation:** DocC

### Module Structure

```
SwiftMCPClient/
├── Sources/
│   └── MCPClient/
│       ├── MCPClientConnection.swift   # Core actor — init, discover, invoke
│       ├── MCPClientProtocol.swift     # Protocol for testability
│       ├── MCPTypes.swift              # MCP domain types
│       ├── MCPError.swift              # Error enum
│       ├── JSONRPCTypes.swift          # JSON-RPC 2.0 types
│       ├── AnyCodableValue.swift       # Type-safe JSON value wrapper
│       ├── Transport/
│       │   ├── MCPTransport.swift      # Transport protocol
│       │   ├── HTTPSSETransport.swift  # HTTP + SSE streaming
│       │   ├── StdioTransport.swift    # Local subprocess (stdin/stdout)
│       │   └── SSEParser.swift         # SSE protocol parser
│       └── MCPClient.docc/
│           ├── MCPClient.md
│           └── MCPClientGuide.md
├── Tests/
│   └── MCPClientTests/
└── Package.swift
```

### Key Types

| Type | Purpose |
|------|---------|
| `MCPClientConnection` | Actor managing MCP protocol lifecycle (init → discover → invoke) |
| `MCPClientProtocol` | Protocol for tool invocation — enables mock injection |
| `MCPTransport` | Protocol for pluggable transport layer |
| `HTTPSSETransport` | Remote server transport via HTTP POST + SSE streaming |
| `StdioTransport` | Local subprocess transport via stdin/stdout pipes |
| `SSEParser` | Stateful Server-Sent Events protocol parser |
| `AnyCodableValue` | Type-safe JSON value wrapper (string/number/bool/object/array/null) |
| `MCPTool` | Tool definition returned by `tools/list` |
| `MCPToolResult` | Result of `tools/call` with content blocks |
| `MCPContent` | Content block (text, image, resource) within a tool result |
| `InitializeResult` | Server capabilities and info from MCP handshake |
| `JSONRPCRequest` / `JSONRPCResponse` | JSON-RPC 2.0 message types |

### Data Flow

```
[Client App] → MCPClientConnection.initialize()
                    → Transport.connect() → Transport.send(initialize)
                    → Transport.receive() → InitializeResult

[Client App] → MCPClientConnection.listTools()
                    → Transport.send(tools/list) → Transport.receive()
                    → [MCPTool]

[Client App] → MCPClientConnection.callTool(name:arguments:)
                    → Transport.send(tools/call) → Transport.receive()
                    → MCPToolResult
```

---

## Current Status

### What's Working

- [x] MCPClientConnection actor with full lifecycle (init → discover → invoke)
- [x] MCPClientProtocol for testability
- [x] HTTPSSETransport with reconnection/backoff
- [x] SSEParser (spec-compliant, stateful, multi-chunk)
- [x] JSON-RPC 2.0 request/response types
- [x] AnyCodableValue for arbitrary JSON
- [x] MCPError with descriptive associated values
- [x] DocC documentation with Getting Started guide
- [x] 314 tests passing, zero warnings
- [x] StdioTransport actor (macOS/Linux) — subprocess via stdin/stdout
- [x] `notifications/initialized` post-handshake notification
- [x] `ping` request/response
- [x] Configurable protocol version
- [x] Cursor-based pagination for `tools/list`
- [x] JSONRPCNotification type
- [x] MCPClientProtocol for testability
- [x] TransportGuide DocC article

### What's Not Working / Missing

All MCP spec 2024-11-05 features are implemented. See Future Considerations for features beyond the current spec.

### Known Issues

None.

### Current Priorities

v1.0.0 release — all features complete, pending Linux CI verification on GitHub Actions.

---

## Quality Standards

### Code Quality

- All code follows `01_CODING_RULES.md`
- Test coverage target: 100% of public API
- Documentation for all public APIs
- No warnings in build output
- Swift 6 strict concurrency throughout
- Zero external dependencies (Foundation only)

### Documentation Quality

- DocC comments for all public functions
- Usage examples in documentation
- Articles for complex topics (transport selection, error handling)

---

## Error Registry

> **Purpose:** Single source of truth for all error types in the project. Consult this
> registry during the Design Proposal Phase to ensure new error cases don't duplicate
> existing ones. Update it whenever new error types are introduced.

### Error Types

| Error Enum | Case | When Thrown | Module |
|------------|------|------------|--------|
| `MCPError` | `.connectionFailed(reason:)` | Transport cannot connect or connection lost | MCPClient |
| `MCPError` | `.requestFailed(code:message:)` | Server returns JSON-RPC error response | MCPClient |
| `MCPError` | `.timeout` | Request exceeds deadline | MCPClient |
| `MCPError` | `.invalidResponse` | Response cannot be decoded as valid JSON-RPC | MCPClient |
| `MCPError` | `.processSpawnFailed(reason:)` | StdioTransport failed to launch subprocess | MCPClient |
| `MCPError` | `.transportClosed` | Transport connection closed unexpectedly | MCPClient |

### Error Design Principles

- **One error enum per module boundary** — `MCPError` covers all client errors
- **Descriptive associated values** — include reason strings, error codes, messages
- **No overlapping cases** — each error has a single meaning
- **Consult this registry** before creating new error cases in a Design Proposal

---

## Roadmap

### Phase 1: Tool Calling Foundation — COMPLETE (v0.1.0)

- [x] MCPClientConnection with initialize/listTools/callTool
- [x] HTTPSSETransport (production-ready, reconnection, backoff)
- [x] SSEParser (spec-compliant)
- [x] JSON-RPC 2.0 types
- [x] AnyCodableValue
- [x] MCPClientProtocol for testability
- [x] DocC documentation
- [x] 108 tests

### Phase 2: Spec Compliance + StdioTransport — COMPLETE (v0.2.0)

- [x] StdioTransport — spawn local MCP server subprocess
- [x] `notifications/initialized` — post-handshake notification
- [x] `ping` request/response
- [x] Configurable protocol version
- [x] Pagination for `tools/list` (cursor support)
- [x] JSONRPCNotification type
- [x] TransportGuide DocC article
- [x] 132 tests

### Phase 3: Resources + Prompts — COMPLETE (v0.3.0)

- [x] `resources/list` and `resources/read`
- [x] `resources/subscribe` and `resources/unsubscribe`
- [x] `prompts/list` and `prompts/get`
- [x] Resource templates
- [x] MCPAnnotations (audience/priority)
- [x] ResourcesGuide + PromptsGuide DocC articles
- [x] 207 tests

### Phase 4: Advanced Features — COMPLETE (v0.4.0)

- [x] Notification listener architecture (AsyncStream-based)
- [x] Progress notifications (`notifications/progress`)
- [x] Request cancellation (`notifications/cancelled`)
- [x] Logging support (`logging/setLevel` + `notifications/message`)
- [x] Completion support (`completion/complete`)
- [x] Roots capability (`roots/list` — server-to-client request)
- [x] Client capability declaration in initialize

### Phase 5: Production Hardening — COMPLETE (v1.0.0)

- [x] Full MCP specification compliance audit
- [x] MCPContent → discriminated union enum (breaking)
- [x] MCPError.requestFailed data field (breaking)
- [x] Client capabilities + ServerCapabilities logging
- [x] Progress token support, protocol version validation
- [x] Graceful disconnect(), request-level timeouts
- [x] Sampling capability (sampling/createMessage)
- [x] WebSocket transport
- [x] AsyncSequence typed notification streams
- [x] Performance benchmarks
- [x] Migration guide + error handling guide (DocC)
- [x] GitHub Actions CI (macOS + Linux)
- [x] 314 tests, zero warnings

### Future Considerations

- MCP Sampling capability (client-side LLM invocation)
- WebSocket transport
- gRPC transport
- Combine/AsyncSequence streaming API for notifications
- SwiftUI integration helpers

---

**Last Updated:** 2026-03-25
