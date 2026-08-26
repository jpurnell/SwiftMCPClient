# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `ProcessRunner` — the single site in the package allowed to spawn a subprocess or read its
  pipes. `StdioTransport` now spawns through it.
- Test support: `String.utf8Data`, `requireURL(_:)`, `loopbackPort(of:)`, `loopbackURL(port:target:)`.

### Changed
- `StdioTransport` no longer blocks a cooperative thread while waiting on subprocess output.
  Reads run through `ProcessRunner`'s `readabilityHandler`, which is called only once bytes
  are buffered, and are awaited rather than blocked on.
- `FakeKeychain` (tests) guards its injected-status properties with the same lock as its storage.
- `MockTransport` (tests) is `Sendable` rather than `@unchecked Sendable`.

### Fixed
- `StdioTransport` framing: a server terminating lines with `\r\n` produced one unsplit blob.
  `"\r\n"` is a single Swift `Character`, so splitting on the `"\n"` literal never matched it.
- DocC guides documented API that does not exist: `MCPContent.text` as a property (it is an
  enum case), `HTTPSSETransport(timeout:)` (the parameter is `connectionTimeout:`), and a
  two-value `MCPError.requestFailed` pattern (it carries three).
- DocC guides referenced `client`, `transport`, `logger`, `args`, `resource`, and `myLLM`
  without ever defining them, and reused bindings across fences within one article.
- OAuth protected-resource discovery now logs each candidate URL it fails on.
- Two `Sendable` warnings in `LoopbackRedirectListener`: `CallbackHandler` now declares the
  EventLoop confinement its doc comment already argued, and the deferred `context.close` goes
  through `NIOLoopBound`.
- Quality gate: 0 errors / 0 warnings across 40 checkers (from 135 errors / 10 warnings).
  Removed 118 force unwraps from the test suite.

## [0.9.0] - 2026-06-30

### Added
- StreamableHTTP transport for MCP 2025-03-26 specification
- WebSocket transport via WebSocketKit for cross-platform support
- Swift DocC plugin for documentation generation

### Changed
- Migrated HTTP/SSE transport from URLSession to AsyncHTTPClient for cross-platform support
- Updated swift-tools-version from 6.0 to 6.2
- Improved documentation coverage to 100% of public APIs

### Fixed
- Quality gate compliance: safety, concurrency, logging, test quality, accessibility
- Increased sampling handler test timeout for Linux CI

## [0.4.0] - 2026-03-25

### Added
- Bidirectional communication with sampling handler support
- MCPExplorer macOS app for interactive server inspection
- Production hardening and full MCP spec compliance

## [0.3.0] - 2026-03-25

### Added
- Resources capability with resource listing and reading
- Prompts capability with prompt listing and retrieval
- Resource and prompt notification support

## [0.2.0] - 2026-03-25

### Added
- StdioTransport for local process communication
- Phase 2 spec compliance: notifications, ping, pagination, protocol version negotiation
- TransportGuide DocC article
- Initial MCPClient package with HTTP/SSE transport
