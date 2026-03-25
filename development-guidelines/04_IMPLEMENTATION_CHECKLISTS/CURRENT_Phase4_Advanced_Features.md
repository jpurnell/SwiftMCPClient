# Implementation Checklist: Phase 4 — Advanced Features

**Plan:** `02_IMPLEMENTATION_PLANS/UPCOMING/Phase4_Advanced_Features.md`
**Target Version:** v0.4.0

---

## Delivery Order

### 1. MCPLogLevel + MCPLogMessage + MCPProgressNotification types
- [ ] RED: Tests for Codable, Equatable, Comparable (log levels)
- [ ] GREEN: Implement types in MCPNotificationTypes.swift
- [ ] REFACTOR

### 2. MCPNotification enum
- [ ] RED: Tests for all cases
- [ ] GREEN: Implement enum
- [ ] REFACTOR

### 3. MCPMessageDispatcher — response routing
- [ ] RED: Tests that responses route to correct pending request
- [ ] GREEN: Implement dispatcher with response routing
- [ ] REFACTOR
- [ ] Wire into MCPClientConnection, verify 207 existing tests pass

### 4. MCPMessageDispatcher — notification routing
- [ ] RED: Tests that notifications route to AsyncStream
- [ ] GREEN: Add notification stream to dispatcher
- [ ] REFACTOR

### 5. Progress token support on requests
- [ ] RED: Tests that _meta.progressToken appears in sent requests
- [ ] GREEN: Add progressToken to callTool/readResource/getPrompt
- [ ] REFACTOR

### 6. Request cancellation
- [ ] RED: Tests for cancelRequest sending correct notification
- [ ] GREEN: Implement cancelRequest()
- [ ] REFACTOR

### 7. Logging — setLogLevel
- [ ] RED: Tests for setLogLevel sending correct request
- [ ] GREEN: Implement setLogLevel()
- [ ] REFACTOR

### 8. Completion — complete()
- [ ] RED: Tests for complete() with prompt ref, resource ref
- [ ] GREEN: Implement complete() and MCPCompletionTypes
- [ ] REFACTOR

### 9. Roots — types + handler + notify
- [ ] RED: Tests for roots handler, notifyRootsChanged
- [ ] GREEN: Implement roots types, handler, notification
- [ ] REFACTOR

### 10. MCPMessageDispatcher — incoming request handling
- [ ] RED: Tests that incoming roots/list invokes handler
- [ ] GREEN: Wire dispatcher to call roots handler
- [ ] REFACTOR

### 11. Client capabilities in initialize
- [ ] RED: Tests that capabilities appear in initialize request
- [ ] GREEN: Add ClientCapabilities parameter
- [ ] REFACTOR

### 12. MCPClientProtocol updates
- [ ] Add relevant new methods to protocol
- [ ] Verify conformance

### 13. Documentation
- [ ] NotificationsGuide.md DocC article
- [ ] Update MCPClient.md topics

### 14. Release
- [ ] All tests passing, zero warnings
- [ ] Tag v0.4.0
- [ ] Push to GitHub
