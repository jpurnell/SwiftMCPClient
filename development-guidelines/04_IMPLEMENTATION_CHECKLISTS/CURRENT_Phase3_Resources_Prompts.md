# Implementation Checklist: Phase 3 — Resources + Prompts

**Plan:** `02_IMPLEMENTATION_PLANS/UPCOMING/Phase3_Resources_Prompts.md`
**Target Version:** v0.3.0

---

## Delivery Order

### 1. MCPAnnotations + MCPResource + MCPResourceTemplate types
- [ ] RED: Tests for Codable, Equatable, optional fields, annotations
- [ ] GREEN: Implement structs in MCPResourceTypes.swift
- [ ] REFACTOR

### 2. MCPResourceContents type
- [ ] RED: Tests for text/blob variants, custom Codable
- [ ] GREEN: Implement enum with custom Codable
- [ ] REFACTOR

### 3. ResourcesCapability + PromptsCapability on ServerCapabilities
- [ ] RED: Tests decoding capabilities with resources/prompts
- [ ] GREEN: Add capability structs and properties
- [ ] REFACTOR

### 4. listResources() + listResourceTemplates()
- [ ] RED: Tests with MockTransport (single page, pagination, empty)
- [ ] GREEN: Implement on MCPClientConnection
- [ ] REFACTOR

### 5. readResource()
- [ ] RED: Tests for text/blob/multiple contents
- [ ] GREEN: Implement on MCPClientConnection
- [ ] REFACTOR

### 6. subscribeResource() + unsubscribeResource()
- [ ] RED: Tests for correct request shape
- [ ] GREEN: Implement on MCPClientConnection
- [ ] REFACTOR

### 7. MCPPrompt + MCPPromptArgument types
- [ ] RED: Tests for Codable, optional arguments
- [ ] GREEN: Implement structs in MCPPromptTypes.swift
- [ ] REFACTOR

### 8. MCPRole + MCPPromptContent + MCPPromptMessage types
- [ ] RED: Tests for text/image/resource content, role, annotations
- [ ] GREEN: Implement with custom Codable for MCPPromptContent
- [ ] REFACTOR

### 9. listPrompts()
- [ ] RED: Tests with MockTransport (single page, pagination, empty)
- [ ] GREEN: Implement on MCPClientConnection
- [ ] REFACTOR

### 10. getPrompt()
- [ ] RED: Tests for basic get, with arguments, multiple messages
- [ ] GREEN: Implement on MCPClientConnection
- [ ] REFACTOR

### 11. MCPClientProtocol updates
- [ ] Add resource/prompt methods to protocol
- [ ] Verify MCPClientConnection conformance

### 12. Documentation
- [ ] ResourcesGuide.md DocC article
- [ ] PromptsGuide.md DocC article
- [ ] Update MCPClient.md topics

### 13. Release
- [ ] All tests passing, zero warnings
- [ ] Tag v0.3.0
- [ ] Push to GitHub
