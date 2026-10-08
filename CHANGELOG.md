# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security
- **A redirect could send a request — custom headers, session id and body — to any origin,
  and from `https` to `http` (CWE-200, CWE-522, CWE-319).** `StreamableHTTPTransport` and
  `HTTPSSETransport` made their requests on an `AsyncHTTPClient` left at its default: follow up
  to five redirects, wherever they point. Across origins that client removes four headers —
  `Authorization`, `Cookie`, `Origin`, `Proxy-Authorization` — and nothing else. So a server
  answering `3xx` with a `Location` on another host or another port — over plaintext
  included — received, measured on the wire between two loopback servers:

  | Request | `301` / `302` | `303` | `307` / `308` |
  |---|---|---|---|
  | HTTP+SSE stream `GET` | `GET` + static headers | same | same |
  | HTTP+SSE `POST` | `GET` + static headers | same | `POST` + static headers + **body** |
  | Streamable HTTP first `POST` | `GET` + static headers | same | `POST` + static headers + **body** |
  | Streamable HTTP later `POST` | `GET` + static headers + `Mcp-Session-Id` | same | `POST` + static headers + `Mcp-Session-Id` + **body** |
  | Streamable HTTP server-stream `GET` | `GET` + static headers + `Mcp-Session-Id` + `MCP-Protocol-Version` | same | same |
  | Streamable HTTP resumption `GET` | `GET` + static headers + `Mcp-Session-Id` + `Last-Event-ID` | same | same |
  | Streamable HTTP `DELETE` | `DELETE` + static headers + `Mcp-Session-Id` | `GET` + the same | `DELETE` + the same |

  "Static headers" is everything passed in `headers:` other than `Authorization` and `Cookie`
  — an `X-API-Key`, for instance. The `authorization:` provider's token never crossed, and
  neither did a static `Authorization`. An `https` server redirecting to an `http` one was
  followed like any other, which put the same things on the network in the clear.

  **Now:** a redirect is followed only when its destination has the **same scheme, host
  (case-insensitive) and effective port** as the URL the transport was configured with — the
  comparison 0.14.0 introduced for the SSE `endpoint` event, and the same code
  (`HTTPOrigin.resolve`). For anything else every cell above is *nothing*: no request is made
  to the destination at all. The operation fails with the new
  `MCPError.redirectRejected(destination:reason:)`, the refusal is logged at error level
  naming the destination's origin only, and it is not retried — `HTTPSSETransport.connect()`
  does not loop on it, the Streamable HTTP server stream stops instead of reconnecting, and
  `MCPConnectionFactory` does not fall back to a second handshake through the same redirect.

  `WebSocketTransport` was checked and needed no change here: `WebSocketKit` sends one upgrade
  request and fails on any answer but `101`. That is now pinned by a wire test for all five
  redirect statuses.

  The TypeScript and Python reference clients restrict redirects to the request's origin too
  (`fetchWithinOrigin`, `stream_within_origin`). This is stricter than both in one respect:
  they treat `http` → `https` on the same host and default ports as staying within the
  origin, and this does not.

### Changed
- **Cross-origin redirects are no longer followed.** A deployment that answered the configured
  URL with a redirect to another host or port — or from `http://` to `https://` — worked
  before and fails now with `MCPError.redirectRejected`. Configure the transport with the URL
  the server redirects to; the error's `destination` is its origin. There is no opt-out and no
  allow-list: no deployment was found that needs one.
- **Same-origin redirects are followed by the transports themselves** rather than by
  `AsyncHTTPClient`, whose following is now switched off for the transports' client. The rules
  are that client's, kept: `301`/`302`/`303`/`307`/`308`, at most five, loops refused, `303`
  (and `301`/`302` for a `POST`) repeated as a `GET` without the body, `307`/`308` repeated as
  sent. Three differences: a `304` or `305` carrying a `Location` is no longer treated as a
  redirect; `POST /x` → `303` → `/x` is no longer mistaken for a loop; and the
  `authorization:` provider is asked again for each redirected request instead of the first
  request's token being reused.
- **A `Location` carrying userinfo is refused** even on the configured origin, as an
  `endpoint` carrying userinfo already was.
- With an `authorization:` provider that returns `nil`, a static `Authorization` in `headers`
  is now left off the Streamable HTTP server stream's `GET` too. It was already left off every
  `POST`; the `GET` sent it.

### Added
- **`MCPError.redirectRejected(destination:reason:)`.** A new case on a public enum, so an
  exhaustive `switch` over `MCPError` needs one more arm. `destination` is an origin only
  (`scheme://host[:port]`) and safe to log. A separate case from `endpointRejected` because the
  remedy differs: a cross-origin `endpoint` is the server misdescribing itself, while a
  cross-origin redirect is usually a server that moved, and the fix is the configured URL.

### Fixed
- **A failed POST put the session id in the error (CWE-532).** `send(_:)`'s
  `MCPError.requestFailed` message was `HTTP 500 from POST to ` followed by the whole request
  URL. A legacy HTTP+SSE endpoint is usually `/messages?sessionId=…`, so the session id went
  wherever the error went — a log, an alert, a bug report. On `StreamableHTTPTransport` the
  same message carried the configured URL's query, which is where a key ends up when a server
  documents `?api_key=…`. Both now name the endpoint by origin and path only, through one
  function (`HTTPOrigin.redacted`) that removes query, fragment and userinfo.
- **Three more places a URL or a header reached error text**, found by reading every
  interpolation in the transports and the OAuth code:
  - An `endpoint` event that did not parse was quoted back in
    `connectionFailed("Invalid endpoint URL: …")`. It is no longer quoted.
  - `WebSocketTransport.connect()` reported a refused upgrade with `WebSocketKit`'s
    description of it, which prints the response head — every header the server sent,
    `Location` and `Set-Cookie` included. It now reports the status code.
  - `MCPOAuthError.metadataNotFound(url:status:)` carried the discovery URL with any userinfo
    the server URL had, and the matching debug log line printed it. Both are redacted.
- **`HTTPSSETransport` refused every `endpoint` when the configured URL itself carried
  userinfo.** A relative endpoint inherits it, and inherited userinfo was mistaken for
  userinfo the server had supplied. What the caller wrote is now told apart from what the
  server adds.

### Tests
- `TransportRedirectWireTests` — two loopback servers, every request each HTTP transport makes
  × `301`/`302`/`303`/`307`/`308`, asserting on what the *second* server received; the same
  with an `authorization:` provider; four spellings of "elsewhere"; an HTTPS first server
  redirecting to a plaintext second one; a chain that leaves and returns; loops and the hop
  limit; same-origin redirects still followed with the right method, headers and body, and
  still streaming; no retry.
- `HTTPOriginTests` — the decision function for the destinations loopback cannot be
  (look-alike hosts, `https` → `http` on one host), the request rewrite table, and redaction.
- `TransportErrorRedactionTests` — a failing request per site, with every rendering of the
  error searched for the value that must not be in it.
- 0.14.0's `redirectDoesNotForwardAuthorization` pinned `AsyncHTTPClient` following a
  cross-origin `307` without `Authorization`. It now asserts that the redirect is refused and
  the second server hears nothing.

## [0.14.0] — 2026-10-08

### Security
- **`HTTPSSETransport` would POST to wherever the server said, bearer token attached
  (CWE-918, CWE-522).** In the legacy HTTP+SSE handshake the server's first event, `endpoint`,
  names the URI every JSON-RPC message is then sent to. The transport resolved that value
  against the configured URL and used the result. For a path that is harmless. But it is
  resolved as a URL reference, so `https://other.example/x` — or `//other.example/x`, which
  looks like a path and is not one — replaced the host outright, and every subsequent POST
  went there carrying the `Authorization` header and any static `headers`. A compromised or
  malicious server, or anything able to write into the event stream, could collect the
  credential and the session's traffic.

  **Now:** the resolved endpoint must be on the **same origin** as the configured stream URL —
  same scheme, same host (case-insensitive), same effective port (a missing port is the
  scheme's default). The comparison is of parsed components, not string prefixes. An endpoint
  with userinfo (`user@host`) is refused even on the right host; a fragment is dropped.
  Otherwise `connect()` throws the new `MCPError.endpointRejected(endpoint:reason:)`, logs
  the offending origin at error level, sends nothing to the endpoint, and does not retry.

  **This is a behaviour change.** A server that sends a cross-origin endpoint — most plausibly
  one behind a reverse proxy that advertises its internal address, or an `http://` endpoint on
  an `https://` stream — connected before and is refused now. Have it send a path. There is no
  opt-out: the 2024-11-05 specification says only that the event contains "a URI", but the
  TypeScript and Python reference clients both refuse a cross-origin endpoint already, and no
  deployment was found that needs one.

  The line carried a `// SECURITY:` acknowledgement for `security.ssrf` — "URL is resolved from
  the server-provided endpoint path, caller controls the base URL" — which was true of a path
  and of nothing else the parser accepts.

### Added
- **`MCPError.endpointRejected(endpoint:reason:)`.** A new case on a public enum, so an
  exhaustive `switch` over `MCPError` needs one more arm. `endpoint` is an origin only
  (`scheme://host[:port]`) and safe to log.

### Tests
- A cross-origin `307` in answer to a POST does **not** carry `Authorization` to the new
  origin. That is `AsyncHTTPClient`'s behaviour rather than this package's, and is now pinned
  by a test so a dependency update that changed it would fail here. (Static `headers` other
  than `Authorization` and `Cookie`, and the request body, *are* still forwarded — see the
  transport guide; not changed in this release.)

### Removed
- **Seven `// SECURITY:` acknowledgements that answered no finding.** `security.ssrf` now reports
  a URL that reaches a request rather than one that is merely parsed, so these sat on lines the
  gate no longer flags. Each was decided by removing it and re-running the checker; the eight
  that still answer a finding are untouched.

## [0.13.0] — 2026-10-03

### Read this first: `trustSelfSignedCertificates` is gone, and it never did what it said

**Breaking, and a security fix (CWE-295).** All three network transports took
`trustSelfSignedCertificates: Bool`. Passing `true` set NIOSSL's `certificateVerification` to
`.none`. That does not trust a self-signed certificate — it stops checking certificates, so the
connection accepts whatever is presented by whoever answers it. Anyone on the path between a
client and its "development" server could read and rewrite the session, bearer token included.

The parameter is removed rather than deprecated. A deprecated flag that quietly began verifying
would compile, warn, and then fail at run time in exactly the environments that set it; a
deprecated flag that kept working would keep the hole. Each transport instead carries an
`unavailable` initializer under the old label, so the old spelling is a compile error whose
message says what to write.

**Migration.** Where the argument was `false`, delete it. Where it was `true`, supply the
certificate the server presents — or the private authority that issued it — as a trust root:

```swift
// before
let transport = StreamableHTTPTransport(url: url, trustSelfSignedCertificates: true)

// after
let trust = try ServerTrust.onlyRoots([.pemFile("/etc/mcp/dev-server.pem")])
let transport = StreamableHTTPTransport(url: url, serverTrust: trust)
```

Two things that used to be skipped are now checked, and a development server has to pass both:

- **The name.** The certificate must carry the host in the URL as a subject alternative name —
  a DNS name for `https://dev.internal`, an IP address for `https://127.0.0.1`. To export what a
  server presents: `openssl s_client -connect host:443 -showcerts </dev/null | openssl x509 >
  server.pem`. To make one that names its host: `openssl req -x509 -newkey ec -pkeyopt
  ec_paramgen_curve:prime256v1 -nodes -keyout key.pem -out server.pem -days 365 -subj
  "/CN=dev.internal" -addext "subjectAltName=DNS:dev.internal,IP:127.0.0.1" -addext
  "extendedKeyUsage=serverAuth"`.
- **The chain.** It must end at a root you supplied (or, for `additionalRoots`, at one of those
  or a system root).

There is no replacement for "verify nothing", by design.

### Added
- **`ServerTrust` — what a transport is prepared to believe about its server.** One type, used
  by `StreamableHTTPTransport`, `HTTPSSETransport` and `WebSocketTransport` through a new
  `serverTrust:` parameter that defaults to `.system`:
  - `ServerTrust.system` — the platform root store. The default; behaviour is unchanged.
  - `ServerTrust.additionalRoots(_:)` — the platform root store plus supplied certificates.
  - `ServerTrust.onlyRoots(_:)` — the supplied certificates and nothing else. With a self-signed
    server's own certificate this is a pin: a different self-signed certificate is refused.

  Certificates come from `ServerTrust.CertificateSource`: `.pem(String)`, `.der([UInt8])`,
  `.pemFile(String)`, `.derFile(String)`. They are read and parsed when the value is made, so a
  bad path or a mangled certificate throws `ServerTrustError` where the configuration is
  written. An empty list throws too; nothing falls back to the system roots.
  `rootFingerprints` exposes the SHA-256 of each supplied root — the value `openssl x509
  -fingerprint -sha256` prints — so an application can show what it trusts.
- **No hash pinning, deliberately.** Pinning by SHA-256 of a key or certificate needs NIOSSL's
  verification callback, which neither `AsyncHTTPClient` nor `WebSocketKit` lets a caller
  install, and which replaces chain validation rather than adding to it. A pin that only some
  transports could enforce would be worse than none.

### Changed
- **A transport with supplied roots runs on NIO's event loops, on every platform.** On Apple
  platforms `AsyncHTTPClient` normally runs on Network.framework and *translates* a NIOSSL
  `TLSConfiguration` for it; that translation ignores `additionalTrustRoots` altogether. With
  supplied roots the client is now built on `MultiThreadedEventLoopGroup.singleton`, so NIOSSL
  enforces the configuration and macOS behaves as Linux does. `.system` keeps the platform
  stack, so nothing changes for a caller who does not pass `serverTrust`.
- **`swift-nio-ssl` is a declared dependency.** The transports already imported it and received
  it transitively. `swift-certificates` and `swift-asn1` are added for the test target only,
  which mints its certificates at run time rather than committing a private key. All three were
  already in the resolved graph; `Package.resolved` is unchanged.
- **MCPExplorer's "Trust self-signed certificates" toggle is now a "Trusted certificate file"
  field.** It takes the path of a PEM file and trusts only what is in it; an unreadable path
  stops the connection instead of connecting without it. It applies to WebSocket connections
  too, which the toggle never reached.
- One `// SECURITY:` acknowledgement now says what was decided, ahead of the quality gate requiring a
  reason of at least eight words on every one.

### Fixed
- **A non-finite or oversized `connectionTimeout` stopped the process.** Both HTTP transports
  took the `TimeInterval` and converted it with `Int64(_:)` at every use — seven places — which
  traps on a NaN, an infinity, or anything past `Int64.max`. The conversion now happens once, in
  the initializer, through `TimeAmount.seconds(clamping:)`, which answers every `Double`: NaN and
  negatives become a wait of nothing, infinity and overflow become the longest wait NIO can hold,
  and fractional seconds keep their precision. The old path truncated to whole seconds, so a
  half-second timeout had been no timeout at all.
- **A failed `connect()` in MCPExplorer was recorded but never logged.** The catch block set the
  error state and stopped; it now logs like the other catch blocks around it.

### Changed
- **Thirteen test assertions no longer coalesce a missing value to `0`.** A nil priority or
  temperature had been asserted as if it were present; each now goes through `#require`, so an
  absent value fails the test that was meant to see it.

## [0.12.0] — 2026-09-03

### Read this first: the dependency identities changed

**This release renames two dependencies**, and if you consume this package you take them:

| was | now |
| :--- | :--- |
| `jpurnell/SwiftOAuth` (private) | `jpurnell/swift-oauth` (public) |
| `jpurnell/swift-sdk` | `jpurnell/swift-mcp-sdk` |

SwiftPM derives a package's identity from the last path component of its URL, so those are four
identities for two libraries. A dependency graph reaching both names for either fails to resolve
— `multiple similar targets 'MCP' appear in package 'swift-sdk' and 'swift-mcp-sdk'` — and no
version range fixes it, because it is not a version problem.

If anything else in your graph names the old identities, it must move too. `swift-oauth` is now
public, so this also removes the last private dependency: no token is needed to resolve this
package.

**Tags moved.** This repository's history was rewritten on 2026-09-03 to remove working notes
and a deployment hostname, and every tag from `v0.2.0` to `v0.11.0` now points at a different
commit. A `Package.resolved` pinning any of them holds a dead revision and will fail with
`does not match previously recorded value`. Recovering needs the pin dropped, the SwiftPM
repository cache cleared, and `~/.swiftpm/security/fingerprints/swiftmcpclient-*.json` deleted —
a pinned build does not repair the fingerprint record, so it survives until something resolves
fresh.

### Added
- **RFC 8707 resource indicators are sent.** The identifier comes from the server's own
  protected-resource metadata, which discovery already fetched and then discarded. A client that
  discovers the identifier it is meant to name and sends nothing is exactly the client a strict
  authorization server refuses — and swift-oauth 0.8.0 made strict the default. Requires
  swift-oauth 0.11.1, which is where the value gained somewhere to live.

- **`MCPExplorer` is a real macOS application.** `Scripts/build-app.sh` produces a signed
  `.app`; `--install` puts it in `/Applications`. The signature is not cosmetic: the Keychain
  grants access by code identity, so an unsigned build loses its saved OAuth tokens on every
  rebuild.

- **A conformance suite for the stateless era**, opt-in through `MCP_STATELESS_SERVER`. The
  reference implementation stops at `2025-11-25`, so every claim this client made about
  `2026-07-28` had been checked only against stubs written from the same reading of the same
  document.

### Fixed
- **The handshake negotiated `2024-11-05`.** `initialize` defaults to the oldest revision and
  the factory never overrode it, so a client that had just asked for `2025-11-25` shook hands
  two years older.
- **An empty-data SSE event read as a protocol error.** The reference server leads its stream
  with one; it is framing, not a message.
- **`connect()` leaked an HTTP client**, which surfaced as a crash on deinit.
- **Two Linux-only races** in the server-stream tests, both passing on macOS for no better
  reason than losing the race the other way.

## [0.11.0] — 2026-09-02

Everything below shipped since 0.10.0. Two protocol eras, both transports keeping their
sessions authorised, and the client verified against a live server, a reference implementation,
and Linux.

### Added
- **`MCPConnectionFactory`** — opens a connection to a server whose era is not known in advance,
  by asking `server/discover`. That one request is both the probe and the negotiation: its answer
  names every version the server speaks, so nothing is guessed.

  Era policy lives in the factory rather than the connection deliberately. MCP changed shape
  twice in a year — a handshake with sessions, then neither — and the part most likely to change
  again is the part that decides which shape a server speaks. A connection carrying that would be
  edited on every revision; here, adding an era is adding a case.

  It implements the inspection the specification asks for: a modern server answers `400` for an
  unsupported version, a missing capability, or a header mismatch, and all of those mean "you are
  talking to a modern server and got something wrong" rather than "this server is old". Only an
  unrecognised refusal justifies falling back to `initialize` — which a modern server has removed.

- **A conformance suite for the stateless era**, opt-in through `MCP_STATELESS_SERVER`, run
  against SwiftMCPServer's conformance target. The reference implementation stops at
  `2025-11-25`, so until now every claim this client made about `2026-07-28` was checked only
  against stubs written from the same reading of the same document. The stateless revision is
  where that gap matters most: there is no handshake to fail loudly, so a client that gets
  `_meta` wrong looks like one whose requests are merely being rejected.


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

- **The rest of MCP 2026-07-28.** `server/discover` with `bestMutualVersion(serverSupports:)` —
  the newest revision *both* sides know, which is neither the server's newest (this client may
  not be able to write it) nor ours (which ignores what the server just said).
  `subscriptions/listen`, returning what the server **granted** rather than what was asked for,
  since a server with nothing to watch declines and a client that assumed otherwise waits
  forever. Multi Round-Trip Requests, where the client answers a server's questions by retrying
  its own request — bounded, with `requestState` echoed untouched, and answering nothing ends
  the exchange rather than retrying into the same gap. `x-mcp-header` mirroring, where a
  malformed annotation costs only its own tool and never the whole listing.

  And era detection: a `400` carrying a **recognised modern** error means a modern server
  correcting you, not an old one. A client that read every `400` as "this must be an old server"
  would downgrade and then send `initialize` to a server that removed the method.
  Implementation-defined codes are deliberately not a signal — both eras emit them, so reading
  one would be reading a coincidence.

- **A session can begin without a handshake.** MCP 2026-07-28 removed `initialize`, so
  `beginStateless(protocolVersion:clientName:clientVersion:)` connects, records what every
  request will declare, and starts routing responses. There is nothing to negotiate: a client
  declares a version and finds out.
- **`resultType` is honoured, including the rule that protects older servers.** A result tagged
  `input_required` is a server saying it cannot finish until the client supplies something, and
  handing that back as content would have a caller read an empty payload as "the work is done".
  It is refused, carrying the server's request, until Multi Round-Trip Requests can fulfil one.

  A result with **no** tag is `complete`. Servers on earlier revisions omit the field, and
  reading its absence as "unknown" would have broken every one of them the moment this client
  started looking for it.
- **A refused protocol version is readable.** Without a handshake, a `-32022` refusal is the
  only way a client learns what a server speaks, so `supportedVersions(from:)` reaches the list
  in the error's `data`. A refusal naming nothing yields an empty list rather than a failure —
  "the server did not say" and "the server supports none" are different problems.

- **Requests carry what MCP 2026-07-28 requires of them.** The stateless revision removed the
  handshake, so every request states its own protocol version, client identity and capabilities
  in `_meta`, and mirrors `Mcp-Method` and `Mcp-Name` into HTTP headers so intermediaries can
  route without parsing the body.

  The headers are derived from the bytes being sent rather than passed alongside them. A server
  that reads the body **MUST** reject a request whose headers disagree with it, and deriving
  makes agreement structural rather than something to remember at each call site. The version in
  `_meta` and the version in `MCP-Protocol-Version` come from one stored value for the same
  reason.

  `MCPHeaderValue` implements the Base64 sentinel — including the rule a reader skips: a value
  that is *already* plain ASCII must still be encoded when it looks like the sentinel, or a
  server would decode it into something the body never contained. All five of the
  specification's worked examples are test vectors.

  Everything here is gated on the negotiated revision. A 2025-era server sees none of it, since
  it performed a handshake and has no rule for headers that did not exist yet.

- **The protocol surface comes from the shared SDK now, not a second copy here.** This package
  depends on `jpurnell/swift-sdk` at `2.0.0-alpha.1`, pinned exactly, for the MCP wire types —
  the same source SwiftMCPServer uses. The transports, OAuth discovery, loopback listener,
  credential and registration storage, and the two applications remain this package's own.

  The duplication was found the way these things usually are: by writing some. The tasks
  extension was implemented here in full before anyone noticed it already existed in the SDK,
  along with `ProtocolMeta`, `Discover`, `Subscriptions`, `MultiRoundTrip`, `ResultType` and
  `CacheableResult` — which between them are most of the remaining 2026-07-28 work.

- **The `io.modelcontextprotocol/tasks` extension, client side.** A task is how a server
  answers a request it cannot finish now: it returns a handle, and the work outlives the request
  that started it. `getTask(id:)`, `updateTask(id:inputResponses:)`, and `awaitTask(id:)` which
  polls until the task stops moving on its own.

  The types are the SDK's, so there is one definition rather than two that agree by hand.
  `MCPTask` rather than `Task` because Swift concurrency has that name.

  The polling loop stops on `input_required` as well as the terminal states: a task waiting for
  the client will not move until the client answers it, and polling one is how a caller waits
  forever for something it is itself holding up. A failed task is **returned, not thrown** —
  "the work failed" is an answer, and the caller needs the status message that came with it. The
  server's stated poll interval is honoured unless it is zero or negative, which would spin, and
  the loop is bounded so a task that never finishes ends the wait rather than the process.

- **A dropped response stream is now recovered.** 2025-11-25 (SEP-1699) settles how:
  resumption is always via `GET`, whichever stream dropped — the request is never re-issued,
  since that would run the work twice. This package recorded per-request event ids from the day
  the streaming path landed and never used them, so a response stream cut off mid-flight simply
  lost its response and the caller saw a request that never answered. One attempt: a resume that
  fails leaves the caller exactly where it already was, and retrying a stream the server has
  stopped feeding turns a lost response into a loop.
- **A server that closes a stream is no longer treated as a server in trouble.** SEP-1699 lets a
  server disconnect at will and expects clients to poll. A quiet close now returns to a steady
  cadence rather than climbing the backoff, which had meant a healthy but idle server was
  checked progressively less often until it was effectively unwatched. Failures still escalate.

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

[Unreleased]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.4.0...v0.9.0
[0.4.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jpurnell/SwiftMCPClient/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jpurnell/SwiftMCPClient/releases/tag/v0.2.0
