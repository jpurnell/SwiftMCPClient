# Design Proposal: Phase 3 — Resources + Prompts (v0.3.0)

**Status:** Proposed
**Target:** v0.3.0

---

## Goal

Add MCP Resources and Prompts capabilities to MCPClientConnection, bringing the client to feature parity with the three core MCP capabilities (tools, resources, prompts).

## MCP Spec Reference

Protocol version: `2024-11-05`

### Resources Methods
- `resources/list` — paginated, returns `[Resource]` + `nextCursor`
- `resources/templates/list` — paginated, returns `[ResourceTemplate]` + `nextCursor`
- `resources/read` — returns `[ResourceContents]` (text or blob)
- `resources/subscribe` / `resources/unsubscribe` — per-URI subscription

### Prompts Methods
- `prompts/list` — paginated, returns `[Prompt]` + `nextCursor`
- `prompts/get` — returns `[PromptMessage]` with string-valued arguments

### Notifications (server → client)
- `notifications/resources/list_changed` — resource catalog changed
- `notifications/resources/updated` — subscribed resource changed (params: `uri`)
- `notifications/prompts/list_changed` — prompt catalog changed

> **Note:** Server-to-client notifications require a notification listener, which is beyond the current request/response model. Phase 3 will implement the **request methods only**. Notification handling is deferred to Phase 4.

---

## New Types

### Resource Types (MCPResourceTypes.swift)

```swift
/// A resource exposed by an MCP server.
public struct MCPResource: Codable, Sendable, Equatable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?
    public let size: Int?
}

/// A parameterized resource template (RFC 6570 URI template).
public struct MCPResourceTemplate: Codable, Sendable, Equatable {
    public let uriTemplate: String
    public let name: String
    public let description: String?
    public let mimeType: String?
}

/// Contents of a resource — either text or base64-encoded blob.
public enum MCPResourceContents: Codable, Sendable, Equatable {
    case text(uri: String, mimeType: String?, text: String)
    case blob(uri: String, mimeType: String?, blob: String)
}
```

### Prompt Types (MCPPromptTypes.swift)

```swift
/// A prompt template exposed by an MCP server.
public struct MCPPrompt: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    public let arguments: [MCPPromptArgument]?
}

/// An argument accepted by a prompt template.
public struct MCPPromptArgument: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    public let required: Bool?
}

/// A message in a prompt response.
public struct MCPPromptMessage: Codable, Sendable, Equatable {
    public let role: MCPRole
    public let content: MCPPromptContent
}

/// Role for prompt messages.
public enum MCPRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

/// Content within a prompt message — text, image, or embedded resource.
public enum MCPPromptContent: Codable, Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String)
    case resource(MCPResourceContents)
}

/// Result of prompts/get.
public struct MCPPromptResult: Codable, Sendable {
    public let description: String?
    public let messages: [MCPPromptMessage]
}
```

### Capability Updates

Extend `ServerCapabilities` to decode resources and prompts:

```swift
public struct ResourcesCapability: Codable, Sendable {
    public let subscribe: Bool?
    public let listChanged: Bool?
}

public struct PromptsCapability: Codable, Sendable {
    public let listChanged: Bool?
}
```

Add to `ServerCapabilities`:
```swift
public let resources: ResourcesCapability?
public let prompts: PromptsCapability?
```

---

## New Methods on MCPClientConnection

```swift
// Resources
public func listResources() async throws -> [MCPResource]
public func listResourceTemplates() async throws -> [MCPResourceTemplate]
public func readResource(uri: String) async throws -> [MCPResourceContents]
public func subscribeResource(uri: String) async throws
public func unsubscribeResource(uri: String) async throws

// Prompts
public func listPrompts() async throws -> [MCPPrompt]
public func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult
```

All list methods auto-paginate via cursor (same pattern as `listTools()`).

### MCPClientProtocol Updates

Add to the protocol:
```swift
func listResources() async throws -> [MCPResource]
func readResource(uri: String) async throws -> [MCPResourceContents]
func listPrompts() async throws -> [MCPPrompt]
func getPrompt(name: String, arguments: [String: String]) async throws -> MCPPromptResult
```

`listResourceTemplates`, `subscribeResource`, and `unsubscribeResource` are not on the protocol — they're advanced operations that most consumers won't need for mock injection.

---

## Delivery Order

Each step keeps tests green.

### 1. MCPResource + MCPResourceTemplate types
- New file: `MCPResourceTypes.swift`
- RED: Tests for Codable round-trip, Equatable, optional fields
- GREEN: Implement structs
- REFACTOR

### 2. MCPResourceContents type
- RED: Tests for text and blob variants, Codable encoding/decoding
- GREEN: Implement enum with custom Codable
- REFACTOR

### 3. ResourcesCapability on ServerCapabilities
- RED: Tests decoding capabilities with/without resources
- GREEN: Add `ResourcesCapability` struct and optional property
- REFACTOR

### 4. listResources() + listResourceTemplates()
- RED: Tests with MockTransport (single page, pagination, empty)
- GREEN: Implement on MCPClientConnection with cursor loop
- REFACTOR

### 5. readResource()
- RED: Tests returning text contents, blob contents, multiple contents
- GREEN: Implement on MCPClientConnection
- REFACTOR

### 6. subscribeResource() + unsubscribeResource()
- RED: Tests for subscribe/unsubscribe sending correct requests
- GREEN: Implement on MCPClientConnection
- REFACTOR

### 7. MCPPrompt + MCPPromptArgument types
- New file: `MCPPromptTypes.swift`
- RED: Tests for Codable round-trip, optional arguments
- GREEN: Implement structs
- REFACTOR

### 8. MCPPromptMessage + MCPPromptContent + MCPRole
- RED: Tests for text/image/resource content variants, role encoding
- GREEN: Implement with custom Codable for MCPPromptContent
- REFACTOR

### 9. PromptsCapability on ServerCapabilities
- RED: Tests decoding capabilities with/without prompts
- GREEN: Add `PromptsCapability` struct and optional property
- REFACTOR

### 10. listPrompts()
- RED: Tests with MockTransport (single page, pagination, empty)
- GREEN: Implement on MCPClientConnection with cursor loop
- REFACTOR

### 11. getPrompt()
- RED: Tests for basic get, with arguments, multiple messages
- GREEN: Implement on MCPClientConnection
- REFACTOR

### 12. MCPClientProtocol updates
- Add resource/prompt methods to protocol
- Verify existing mock conformance in tests
- REFACTOR

### 13. Documentation
- ResourcesGuide.md DocC article
- PromptsGuide.md DocC article
- Update MCPClient.md topics
- DocC comments on all new public API

### 14. Release
- All tests passing, zero warnings
- Tag v0.3.0
- Push to GitHub

---

## Codable Design Decisions

### MCPResourceContents
Uses a discriminator approach: if `text` key is present → `.text`, if `blob` key → `.blob`. Custom `init(from:)` and `encode(to:)`.

### MCPPromptContent
Uses the `type` discriminator field: `"text"`, `"image"`, `"resource"`. Custom Codable.

### Annotations
Included from the start. The `annotations` field (audience + priority) appears on resources, templates, and content blocks. Modeled as a shared struct:

```swift
public struct MCPAnnotations: Codable, Sendable, Equatable {
    public let audience: [MCPRole]?
    public let priority: Double?
}
```

Added as an optional property on `MCPResource`, `MCPResourceTemplate`, and all `MCPPromptContent` cases.

---

## Files Changed / Created

| File | Action |
|------|--------|
| `Sources/MCPClient/MCPResourceTypes.swift` | NEW |
| `Sources/MCPClient/MCPPromptTypes.swift` | NEW |
| `Sources/MCPClient/MCPTypes.swift` | MODIFY — add capability types |
| `Sources/MCPClient/MCPClientConnection.swift` | MODIFY — add 7 methods |
| `Sources/MCPClient/MCPClientProtocol.swift` | MODIFY — add 4 methods |
| `Sources/MCPClient/MCPClient.docc/MCPClient.md` | MODIFY — add topics |
| `Sources/MCPClient/MCPClient.docc/ResourcesGuide.md` | NEW |
| `Sources/MCPClient/MCPClient.docc/PromptsGuide.md` | NEW |
| `Tests/MCPClientTests/MCPResourceTypesTests.swift` | NEW |
| `Tests/MCPClientTests/MCPPromptTypesTests.swift` | NEW |
| `Tests/MCPClientTests/MCPClientConnectionTests.swift` | MODIFY — add ~20 tests |
