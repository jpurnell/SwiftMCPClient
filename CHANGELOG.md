# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **A refreshed token now reaches the wire.** `StreamableHTTPTransport` takes an
  `AuthorizationProvider` and asks it for a header before every request, instead of holding
  the one it was built with. The refresh itself was never missing — SwiftOAuth exchanges,
  dedupes and persists — but both consumers read the header once at connect time and froze it,
  so the session refreshed underneath a transport that never looked again. That is why
  `updateAuthorization(_:)` existed and had no caller.
- **A refused request is retried once with a forcibly refreshed token.** A token can stop
  working before it expires here: the grant is revoked, the clock drifts, the dynamic client
  registration lapses (RFC 7591). None of that is visible to a transport that refreshes on
  schedule, and the only evidence is a `401`. The retry asks for a token obtained *now* —
  `MCPOAuthSession.authorizationHeader(forcingRefresh:)`, on
  `OAuthConnection.refreshedAccessToken()` from **SwiftOAuth 0.6.0**, which was added upstream
  for this. Once, not in a loop: a server refusing a just-refreshed token is refusing the
  grant, and each further attempt spends a rotation to learn the same thing.

  14 tests written first, against a real HTTP server on loopback rather than the transport's
  own idea of its headers — the defect being fixed was exactly a gap between what the
  transport believed it would send and what it sent (406 → 420).

- **Credentials are keyed by the authorization server that issued them.** MCP 2026-07-28
  (SEP-2352) requires a client to key persisted credentials by the **issuer identifier**, never
  reuse them with a different authorization server, and re-register when it changes. This
  package keyed by the *MCP server's* host and URL, which says nothing about which authorization
  server issued what it held — so an MCP server that moved to a new authorization server kept
  presenting a `client_id` that server never issued, and two MCP servers behind one
  authorization server were filed as if unrelated.

  A record filed under the old key is deliberately **not** migrated: its provenance is unknown,
  and the only conformant response to a credential of unknown provenance is to sign in again.

  One consequence, stated because it reverses a decision made the same day: `resume` and
  `hasStoredCredential` now discover **before** reading storage. The key is not knowable until
  the server names its authorization server, so the earlier "no network when nothing is stored"
  saving is not available. Guessing the key from the host is exactly what SEP-2352 forbids.

- **Verified against an independent implementation.** Every other test in this package checks
  the client against a stub written from the same reading of the same specification, by the
  same author, on the same day — which catches mistakes in the code and not in the reading.
  `ConformanceServerTests` runs against `@modelcontextprotocol/server-everything`, the
  reference server published by the specification's authors.

  It settles what Apollo could not. Apollo answers the server-initiated `GET` with `405`, so
  the largest piece of Phase 2 had never run against anything but a stub. The reference server
  accepts it — and proves our transport opened one, because a *second* `GET` is answered
  `409 Conflict` while ours is open, and `200` when `openServerStream: false`. Neither of those
  is observable from inside the client: a refused stream and an accepted quiet one look
  identical from here.

- **`MCPOAuthSession.persistent()` is now `#if canImport(Security)`.** It reaches for a
  Keychain, so it never could have compiled on Linux; the encrypted stores it builds are
  portable and can be constructed directly with a key from whatever secret store a deployment
  already has. This is what "Linux CI" was actually protecting against, and nothing was
  noticing: **GitHub Actions had been disabled at the repository level since 2026-07-04**, so
  ten pushes produced no runs.

- **`HTTPSSETransport` keeps its session authorised too.** It had the same frozen-header
  defect the Streamable transport just lost: a token read once at construction, under a session
  that refreshes. It now takes the same `AuthorizationProvider`, asked before every POST, again
  after a `401`, and each time the stream is opened — so a reconnect never presents the token
  that had already stopped working. The limit that remains is inherent: a header cannot change
  on a request already open, so a token expiring mid-stream is recoverable only at the next
  reconnect. Its inline reconnect backoff also moved to `StreamBackoff`, which bounded it —
  raising `maxReconnectAttempts` had been quietly buying delays that doubled without limit.
- **A clean disconnect no longer logs as a failure.** Cancelling the SSE stream reported
  "SSE stream ended with error" at warning level on every shutdown, which trains an operator to
  ignore the line that matters.

- **Streamable HTTP is a multiplexer (ADR-002).** Two gaps closed together, because they are
  the same architectural change.

  *POST responses stream.* An SSE response is consumed as it arrives rather than collected, so
  `send(_:)` returns once the request is answered instead of when the work finishes. Progress
  notifications on a long call now arrive during it — the one moment they are worth anything —
  and a response no longer fails for exceeding a 10MB buffer.

  *The server-initiated `GET` channel exists.* `MCPClientConnection`'s notification stream was
  permanently empty over this transport; server-originated messages now arrive on it. Opened
  once initialization completes, because that is when the session exists to open it for. A
  `405` means the server originates nothing and is not an error. Exactly one stream at a time,
  per the specification, reconnecting with `Last-Event-ID` under a deliberately gentle backoff
  — request and response keep working without it, so hammering to restore it spends requests
  on something nothing is blocked on.

  `StreamBackoff` makes that delay a pure policy rather than arithmetic inside a `Task.sleep`,
  which is the only way it can be tested without sleeping — including the overflow that turns
  doubling nanoseconds negative somewhere past attempt 60.

  **Behavioural, and deliberate:** applications begin receiving notifications that previously
  never arrived. `openServerStream: false` restores the earlier POST-only behaviour exactly.
  15 tests written first (449 → 464).

- **`StreamableHTTPSession` and the `MCP-Protocol-Version` header.** Session identity, the
  negotiated protocol version, and the last event seen on each stream now live in one actor
  that decides what every request carries — so the header rules are unit tests rather than
  something inferred from a request nobody can inspect. Spec 2025-06-18 requires
  `MCP-Protocol-Version` on every request after initialization, and a server enforcing it was
  rejecting us; it is now echoed with the version the server **accepted**, which differs from
  the one requested whenever it negotiates down. `MCPTransport` gained
  `didNegotiate(protocolVersion:)` with a default no-op, so no conformance broke.
- **A `404` against a live session now forgets it.** The server saying it has forgotten a
  session was previously indistinguishable from a missing endpoint, and the transport kept
  sending an id the server had dropped — every later request into the same wall, with no way
  for a caller to re-initialize past it.

- **`SSEEventStream`** — decodes a byte stream into Server-Sent Events as they arrive, holding
  parser state across buffer boundaries that fall wherever the network put them, including
  inside a `\r\n`. The first piece of Streamable HTTP Phase 2 (ADR-002); framing rules stay in
  `SSEParser`, which both the streaming and collected paths share.

- **A way to verify the OAuth work against a real server.** `Tests/MCPClientTests/LiveApolloTests.swift`
  runs only with `MCP_LIVE_APOLLO` set, so the ordinary suite and the quality gate never reach
  a browser or an account. It restores a session, forces a refresh against a real token
  endpoint, and drives the retry path by handing the transport a deliberately invalid token
  until it is asked with `forcingRefresh` — a real `401`, recovered from, without waiting for
  anything to expire. It reports what it measures: token lifetime, and whether the provider
  rotates refresh tokens.
- **`client_secret_expires_at` is read and logged at registration.** RFC 7591 §3.2.1 lets a
  server say when a client secret expires; `ClientRegistrationResponse` does not model it, so
  the value was discarded at the one moment it exists. A registration that expires then does
  so invisibly, surfacing weeks later as a refresh failing `invalid_client` with nothing to
  connect it to. `RegistrationLifetime` distinguishes "the server said never" from "the server
  said nothing", because reading silence as a guarantee is how that surprise gets built in.

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
