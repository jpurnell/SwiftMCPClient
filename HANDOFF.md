# HANDOFF — resume point for the next session

**Written:** 2026-09-01, after OAuth session restore landed on a feature branch.
**Working directory note:** launch Claude from the Swift root
(`~/Dropbox/Computer/Development/Swift`) so the session memory loads, then work here.

## Current phase

**OAuth token refresh — DONE** (roadmap #3), on `main`. Session restore (#2) shipped earlier
the same day as **v0.10.0**. The OAuth arc is now feature-complete and **unverified against a
live server**, which is the next thing worth doing.

Refresh turned out not to be missing: SwiftOAuth already exchanged and deduped, and what was
missing was a transport that asked twice. See
`project/summaries/2026-09-01_OAuthTokenRefresh.md`.

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
- **Gate:** 0 errors / 0 warnings (`--no-cache`, 2026-09-01). **Tests:** 420 across two
  targets — 415 in `MCPClientTests`, 5 in the new `MCPExplorerTests`.
- **Depends on SwiftOAuth 0.6.0**, which was cut today specifically for this
  (`refreshedAccessToken()`). Both repos are pushed and tagged; they move together now.
- **`StubHTTPServer`** (`Tests/MCPClientTests/`) is new and reusable: a loopback NIO server
  that records what a request actually carried. Any future transport work that needs to assert
  wire behaviour should use it rather than reading `currentHeaders`. Tests using it **must**
  go through the `withStub` harness — `HTTPClient` traps in `deinit` if it is not shut down,
  and that kills the suite rather than failing a test.
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
8. Streamable HTTP full compliance (`project/plans/upcoming/StreamableHTTPFullCompliance.md`)
9. Linux CI verification
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

Session summaries: latest is `project/summaries/2026-09-01_OAuthTokenRefresh.md`.
