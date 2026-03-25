# Implementation Checklist: Phase 2 — Spec Compliance + StdioTransport

**Plan:** `02_IMPLEMENTATION_PLANS/UPCOMING/Phase2_SpecCompliance_StdioTransport.md`
**Target Version:** v0.2.0

---

## Delivery Order

### 1. JSONRPCNotification type
- [x] RED: Tests for encoding, no `id` field, `params` optional
- [x] GREEN: Implement JSONRPCNotification
- [x] REFACTOR: Clean up

### 2. MCPError new cases
- [x] RED: Tests for `.processSpawnFailed`, `.transportClosed`
- [x] GREEN: Add cases to MCPError enum
- [x] REFACTOR: Clean up

### 3. notifications/initialized
- [x] RED: Test that initialize() sends notification after handshake
- [x] GREEN: Add notification send to MCPClientConnection.initialize()
- [x] REFACTOR: Clean up

### 4. ping()
- [x] RED: Tests for ping success, ping error
- [x] GREEN: Implement ping() on MCPClientConnection + MCPClientProtocol
- [x] REFACTOR: Clean up

### 5. Configurable protocolVersion
- [x] RED: Tests for default version, custom version
- [x] GREEN: Add parameter to initialize()
- [x] REFACTOR: Clean up

### 6. Pagination for tools/list
- [x] RED: Tests for single page, multi-page, empty
- [x] GREEN: Add cursor loop to listTools()
- [x] REFACTOR: Clean up

### 7. StdioTransport
- [x] RED: Tests for connect/send/receive/disconnect, spawn failure, process exit
- [x] GREEN: Implement StdioTransport actor
- [x] REFACTOR: Clean up

### 8. Documentation
- [x] TransportGuide.md DocC article
- [x] Update MCPClient.md overview
- [x] DocC comments on all new public API

### 9. Release
- [x] All tests passing, zero warnings (132 tests)
- [ ] Tag v0.2.0
- [ ] Push to GitHub
