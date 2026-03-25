# Implementation Checklist: Phase 2 — Spec Compliance + StdioTransport

**Plan:** `02_IMPLEMENTATION_PLANS/UPCOMING/Phase2_SpecCompliance_StdioTransport.md`
**Target Version:** v0.2.0

---

## Delivery Order

### 1. JSONRPCNotification type
- [ ] RED: Tests for encoding, no `id` field, `params` optional
- [ ] GREEN: Implement JSONRPCNotification
- [ ] REFACTOR: Clean up

### 2. MCPError new cases
- [ ] RED: Tests for `.processSpawnFailed`, `.transportClosed`
- [ ] GREEN: Add cases to MCPError enum
- [ ] REFACTOR: Clean up

### 3. notifications/initialized
- [ ] RED: Test that initialize() sends notification after handshake
- [ ] GREEN: Add notification send to MCPClientConnection.initialize()
- [ ] REFACTOR: Clean up

### 4. ping()
- [ ] RED: Tests for ping success, ping error
- [ ] GREEN: Implement ping() on MCPClientConnection + MCPClientProtocol
- [ ] REFACTOR: Clean up

### 5. Configurable protocolVersion
- [ ] RED: Tests for default version, custom version
- [ ] GREEN: Add parameter to initialize()
- [ ] REFACTOR: Clean up

### 6. Pagination for tools/list
- [ ] RED: Tests for single page, multi-page, empty
- [ ] GREEN: Add cursor loop to listTools()
- [ ] REFACTOR: Clean up

### 7. StdioTransport
- [ ] RED: Tests for connect/send/receive/disconnect, spawn failure, process exit
- [ ] GREEN: Implement StdioTransport actor
- [ ] REFACTOR: Clean up

### 8. Documentation
- [ ] TransportGuide.md DocC article
- [ ] Update MCPClient.md overview
- [ ] DocC comments on all new public API

### 9. Release
- [ ] All tests passing, zero warnings
- [ ] Tag v0.2.0
- [ ] Push to GitHub
