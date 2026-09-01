# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **MCPExplorer remembers the last server, and restores its session at launch.** The restore
  proposal (§15) wanted auto-resume at launch and could not have it: the URL field was empty
  on every launch, so a session that had survived the restart intact had no address to be
  restored against, and the user went back through browser consent anyway. `LastServer`
  persists the one value; whitespace reads as nothing and a cleared field forgets rather than
  resurrecting the old URL. First tests for the Explorer target, which had none (401 → 406).

## [0.10.0] - 2026-09-01

### Added
- **A signed-in session survives a restart.** `MCPOAuthSession.resume(server:tenant:)`
  rebuilds the signed-in state from storage without opening a browser. The missing piece was
  never the credential — that has persisted since 0.9.0 — but the dynamic client registration
  that obtained it: a refresh token is bound to its `client_id` (RFC 6749 §6), so a client
  that registered again at every launch could never use the credential it already had.

  `RegistrationRecordStore` persists one registration per connection, AES-GCM-sealed in
  `registrations.enc` beside `credentials.enc` and opened by the same Keychain key. A store
  that cannot be decrypted throws rather than reporting itself empty, because empty means
  "never signed in" and sends the caller to a sign-in that mints a fresh registration over the
  top of a credential it has just orphaned.

  Endpoints are re-discovered at resume rather than stored — public metadata, one round trip,
  and a server that moves its token endpoint should not strand every client that cached the
  old one. `resume` returns `false` when nothing or only half is stored, and reaches the
  network only when both halves are present.

  `signIn` now records the registration, but only after the token exchange succeeds, and a
  failure to record it is logged rather than thrown: the sign-in did succeed, and failing it
  would send the user back through consent, registering a second client on the way.
  `signOut` removes the record — it carries a `client_secret`, and a secret that outlives its
  session is one nothing comes back for.

  MCPDump restores before it signs in; MCPExplorer restores when connecting and before
  opening a browser. 19 tests written first (382 → 401), including the one that matters:
  resume never calls the registration endpoint.

### Fixed
- **A rejected handshake no longer crashes the client.** `MCPClientConnection.initialize`
  connected the transport but, when the server refused the handshake (Apollo MCP's 401
  for an unauthenticated `initialize`, first observed live in MCPExplorer), threw without
  disconnecting. The dropped transport still held a live `HTTPClient`, tripping
  AsyncHTTPClient's shutdown-before-deinit precondition — `SIGTRAP` in debug builds.
  `initialize` now releases the transport on the error path and resets connection state,
  so a failed handshake surfaces as the server's error and the connection is retryable.
  Three tests written first: failed handshake disconnects the transport, initialize
  retries after failure, and a failed `connect()` leaves nothing half-open (379 → 382).
- **DocC articles terminate.** `doc-run` executes each `.docc` article as a
  program. All eight drove a live connection to `mcp.example.com`, a server that
  does not answer: five were killed at the 30-second deadline, one segfaulted
  spawning `/usr/bin/nonexistent`, and `MigrationGuide` threw
  `connectionFailed("Not connected — call connect() first")` at top level because
  its setup fence constructed a client without initializing it.

  Each example is now a function the article defines but never calls, with a
  `connectedClient()` factory beside it. The compiler still checks every
  signature — which is what the check is worth — and no article contacts a
  server. `ErrorHandlingGuide` also used `client` before any fence declared it;
  its examples are self-contained now, so that ordering trap is gone. The eight
  articles run in 1.8s total.

- **`## Usage` examples compile.** `doc-comment-code` errors surfaced when that
  checker briefly entered the default set upstream; they had been wrong for as
  long as they existed.

  `AnyCodableValue` and `MCPContent` used a `client` nothing defined — both fences
  now take one as a parameter. `MCPClientProtocol` read `result.content.first?.text`,
  but `MCPContent` is an enum, so `.text` is a case to match rather than a property
  to read; the example now matches it, which is what a caller has to write.

  One file is deliberately not included: `MCPClientConnection.swift` carries
  unrelated in-progress work in the same tree, so its two doc fixes are applied
  in the working copy but left for whoever commits that work. Its errors were the
  same two shapes — an undefined `client`, and `.text` read as a property — plus
  `notifications` needing `await`, since it is actor-isolated.

### Added
- `MCPDump` (macOS executable target) — signs in over OAuth, connects over Streamable
  HTTP, and dumps a server's complete `tools/list` as pretty-printed JSON on stdout.
  Built because MCPExplorer's tool list is a browsing surface, and auditing a 69-tool
  catalog (Apollo MCP: 349K of schemas) needs the catalog in a file. ~70 lines reusing
  `MCPOAuthSession` + `StreamableHTTPTransport`; errors go to the unified log (privacy-
  annotated) and stderr, keeping stdout a clean JSON stream.
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
