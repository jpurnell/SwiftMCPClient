# HANDOFF — resume point for the next session

**Written:** 2026-09-01, after OAuth session restore landed on a feature branch.
**Working directory note:** launch Claude from the Swift root
(`~/Dropbox/Computer/Development/Swift`) so the session memory loads, then work here.

## Current phase

**Streamable HTTP Phase 2 — DONE** (roadmap #7), on `main`, unreleased. The transport is now a
multiplexer over POST response streams and one server-initiated `GET`, both feeding one receive
queue. All four gaps closed: streaming bodies, the `GET` channel, `Last-Event-ID` resumption,
and the `MCP-Protocol-Version` header. ADR-002 recorded; ADR-001 entered late and says so.

The OAuth arc (#2, #3) shipped earlier the same day and is verified live against Apollo.

## Exact next step (start here)

1. **Token refresh**, design-first per the usual workflow. (Three fully-merged local
   branches are still lying around — `feature/oauth-session-restore`,
   `feature/handshake-cleanup-mcpdump`, `feature/streamable-http-phase1` — deletable
   whenever.) Read
   `project/summaries/2026-09-01_OAuthSessionRestore.md` first — it records three things
   the refresh work inherits:
   - SwiftOAuth's `OAuthConnection.validAccessToken()` already refreshes internally; what
     is missing is telling a live transport about the new token.
   - `ClientRegistrationResponse` carries no `client_secret_expires_at`, so a registration
     that expires server-side cannot be predicted yet — only reacted to.
   - Apollo's real behaviour on both points is unverified. Worth one live run before
     designing around assumptions.

## State of the world

- **Branch:** `main`, clean. **v0.10.0** is tagged; the refresh work sits after it, unreleased.
- **Gate:** 0 errors / 0 warnings (`--no-cache`, 2026-09-01). **Tests:** 474 across two
  targets — 469 in `MCPClientTests`, 5 in `MCPExplorerTests`.
- **Depends on SwiftOAuth 0.6.0**, which was cut today specifically for this
  (`refreshedAccessToken()`). Both repos are pushed and tagged; they move together now.
- **Test servers, and the rule for using them.** `StubHTTPServer` records what a request
  actually carried and can serve the `GET` channel; `FlushProbeServer` holds a response open
  until the client signals, which is how "delivered before the response closed" is asserted as
  an ordering rather than a duration. Any transport work that needs wire behaviour should use
  them rather than reading `currentHeaders`. Tests **must** disconnect the transport and shut
  down any `HTTPClient` on both paths — it traps in `deinit`, killing the suite rather than
  failing a test. `withStub` does this for you.
- **Assert reconnect behaviour on the wire, not through the session.** A mechanism that is
  correct and uncalled has now happened three times here (`updateAuthorization`,
  `didNegotiate`, and `Last-Event-ID` on reconnect). The session's unit tests passed while the
  transport was not sending the header.
- **The toolchain moved on 2026-09-01.** The OS update left `xcode-select` on
  `/Library/Developer/CommandLineTools`, which ships no `Testing.swiftmodule` — every
  `import Testing` failed to compile until it was pointed at Xcode-beta 27.0:
  `sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer`. Same Swift 6.4,
  but local builds now use a **beta** SDK while the deployment server is on 6.3.3. If a fresh
  session sees "no such module 'Testing'", this is why.
- **History was rewritten and force-pushed 2026-09-01** (sensitive strings removed; old
  SHAs invalid). Backup: `../SwiftMCPClient-prerewrite-2026-09-01.bundle` — private, delete
  when confident. Do not reintroduce content from the bundle.
- **`project/notes/` is gitignored, local-only, by design.** Field notes (Apollo survey
  delta log, 69-tool catalog JSON, teardown draft) live there. Do not un-ignore.

## Approved roadmap (re-ranked 2026-09-01)

1. ~~Privacy decision on pushed history~~ — done: rewritten + force-pushed.
2. ~~OAuth session restore~~ — **done 2026-09-01**, `7df8652`, unmerged.
3. ~~OAuth token refresh~~ — **done 2026-09-01**
4. ~~Live verification against Apollo~~ — **done 2026-09-01**: refresh, rotation and the 401
   retry all confirmed live
5. AsyncHTTPClient chunk-flushing spike (timeboxed; can shrink Phase 2's scope) ← YOU ARE HERE
   is arguably #8 instead; see the note below
6. Explorer tools pane: height + JSON export
7. TransportGuide.md Phase 1 revision (carried three times now)
8. ~~Streamable HTTP full compliance~~ — **done 2026-09-01**
9. **Linux CI verification** ← the last item before v1.0.0 is defensible
10. `HTTPSSETransport` has the same frozen-header defect the Streamable transport just lost,
    and no `updateAuthorization(_:)` at all — a long-lived stream cannot re-authenticate
    without reconnecting (OAuthTokenRefresh.md §15.2)
11. Deliberate v1.0.0 tag (after 8, 9 — latest tag is **v0.10.0**, cut 2026-09-01)

## Blockers / decisions

- ~~Should MCPExplorer persist the last server URL?~~ **Decided 2026-09-01: yes.**
  `LastServer` persists it, and `restoreRememberedSession()` runs at launch, so §15 of the
  restore proposal is now true rather than aspirational.
- **Nothing blocking.**
- **Worth knowing before the next OAuth decision:** Apollo issues **30-day** access tokens.
  The proactive half of the refresh work — asking the provider before each request — protects
  against an expiry that will not happen on this server; it earns its place by enabling the
  `401` retry and by being right for providers with hour-long tokens. Apollo **rotates**
  refresh tokens, so never race a refresh. Apollo states **no** `client_secret_expires_at`,
  so registration lifetime is unknown and cannot be predicted — only reacted to.
- External context for this work (deadline, artifacts) lives in session memory
  (`apollo-pm-opportunity`), **not** in this repo. Keep it that way.

## Conventions reminder

Design-first TDD (red → green → refactor), quality gate 0/0 with **no** suppressions or
override comments, CHANGELOG + session summary ride the feature commit, `project/notes/`
never gets committed. Auditor tripwires: catch blocks log or rethrow; logger interpolation
needs `privacy:` annotations in the app targets (os.Logger) and a `// logging:` marker in
MCPClient (swift-log); `import os` goes inside `#if canImport(os)`.

Session summaries: latest is `project/summaries/2026-09-01_StreamableHTTPPhase2.md`.
