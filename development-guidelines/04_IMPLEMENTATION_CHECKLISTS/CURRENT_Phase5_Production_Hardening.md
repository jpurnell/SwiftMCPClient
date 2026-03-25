# Phase 5: Production Hardening (v1.0.0) — Checklist

## Spec Compliance
- [x] MCPContent → discriminated union enum (breaking)
- [x] MCPError.requestFailed data field (breaking)
- [x] Client capabilities in initialize
- [x] ServerCapabilities + logging capability
- [x] Progress token support (_meta.progressToken)
- [x] Protocol version validation

## Lifecycle & Reliability
- [x] Graceful disconnect()
- [x] Request-level timeouts

## New Capabilities
- [x] Sampling capability (sampling/createMessage)
- [x] WebSocket transport
- [x] AsyncSequence streaming API (typed notification streams)

## Quality & Verification
- [x] Performance benchmarks
- [x] Linux CI (GitHub Actions workflow)
- [x] Public API audit + DocC catalog update

## Documentation
- [x] Migration guide (v0.4 → v1.0)
- [x] Error handling guide
- [x] Master plan update
- [ ] Tag v1.0.0 (after commit + push)
