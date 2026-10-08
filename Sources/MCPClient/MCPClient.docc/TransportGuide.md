# Choosing a Transport

Select the right transport for your MCP server connection.

## Overview

MCPClient communicates with MCP servers through pluggable transports that
conform to the ``MCPTransport`` protocol. Four ship with the library, each
suited to a different deployment.

For a remote server written against a current specification, reach for
``StreamableHTTPTransport``. ``HTTPSSETransport`` speaks the older HTTP+SSE
shape, which a shrinking set of servers still offers.
``WebSocketTransport`` and ``StdioTransport`` cover a persistent socket and a
local subprocess respectively.

| Transport | For | Server-initiated messages |
| :--- | :--- | :--- |
| ``StreamableHTTPTransport`` | Remote servers, current spec | Yes, over a `GET` stream |
| ``HTTPSSETransport`` | Remote servers, legacy HTTP+SSE | Yes, over the SSE stream |
| ``WebSocketTransport`` | Remote servers offering a socket | Yes |
| ``StdioTransport`` | A local server as a child process | Yes |

## Streamable HTTP — Remote Servers, Current Spec

``StreamableHTTPTransport`` implements the transport defined by MCP
2025-03-26, with the `MCP-Protocol-Version` header added in 2025-06-18.

```swift
// `initialize` opens a live connection, so it is shown inside a function this
// guide never calls.
func connectOverStreamableHTTP() async throws {
    guard let url = URL(string: "https://mcp.example.com/mcp") else { return }
    let transport = StreamableHTTPTransport(url: url)
    let client = MCPClientConnection(transport: transport)
    let info = try await client.initialize(
        clientName: "my-app",
        clientVersion: "1.0.0"
    )
    print("Connected to \(info.serverInfo.name)")
}
```

### Two channels, one queue

Requests go out as `POST`. The server answers either with a single JSON
document or with an SSE stream it may hold open while it works — a long tool
call can report progress as it goes, and those messages arrive *during* the
call rather than after it.

Alongside that, once initialization completes, the transport opens one
client-initiated `GET` stream. That is the channel the server uses to originate
messages: progress, log messages, sampling requests, list-changed
notifications. Without it a client's notification stream is permanently empty.

Both feed the same ``MCPTransport/receive()`` queue, so nothing in your code
needs to know which channel a message arrived on.

A server that originates nothing answers the `GET` with `405`. That is not an
error, and request/response keeps working — the client simply has no
server-initiated messages. To skip the channel entirely, pass
`openServerStream: false`, which restores POST-only behaviour.

### Keeping a session authorised

An OAuth session refreshes, and a header read once at connect time does not.
Pass the session rather than a token:

```swift
func connectWithOAuth(session: MCPOAuthSession) async throws {
    guard let url = URL(string: "https://mcp.example.com/mcp") else { return }
    let transport = StreamableHTTPTransport(
        url: url,
        authorization: { forcingRefresh in
            try await session.authorizationHeader(forcingRefresh: forcingRefresh)
        }
    )
    _ = MCPClientConnection(transport: transport)
}
```

The provider is asked before every request, and again after a `401` — that
second call is what recovers from a token the server has rejected before it
expired locally, which no clock on this side can predict. That includes the
`DELETE` that ends the session; see
<doc:TransportGuide#Ending-a-Streamable-HTTP-Session>.

### Where the OAuth requests themselves go

``MCPOAuthSession`` makes requests of its own — discovery, registration, the
token exchange, every refresh — and they are held to their origin as the
transports' are:

| Request | A redirect |
|---|---|
| Protected-resource and authorization-server metadata (`GET`) | followed only within the origin of the URL being fetched, at most five times |
| Dynamic client registration (`POST`) | never followed |
| Token exchange, refresh, revocation (`POST`) | never followed |

A metadata document is public, but it is only worth anything from the server
it describes: RFC 8414 §3 and RFC 9728 §3 put it at a well-known path on that
server's own host, and RFC 8414 §3.3 forbids using one whose `issuer` is not
the issuer it was fetched for — which is checked, and fails with
``MCPOAuthError/issuerMismatch(expected:found:)``. The `POST`s carry the
authorization code and its PKCE verifier, the refresh token and the client
secret; a `307` or `308` would re-send all of it, so no redirect from those
endpoints is followed, on any status, even within the origin.

A redirect that is not followed sends nothing to its destination and throws
``MCPError/redirectRejected(destination:reason:)``.

This is true of the defaults — ``MCPOAuthSetup/fetchMetadata(from:)`` and
``MCPOAuthTokenTransport``. A `fetch` or a `tokenTransport` you supply yourself
replaces them, and decides for itself what a redirect does:

```swift
func setupWithLoggedFetch() -> MCPOAuthSetup {
    // A fetch of your own that keeps the default's redirect rule by calling it.
    MCPOAuthSetup(fetch: { url in
        let document = try await MCPOAuthSetup.fetchMetadata(from: url)
        print("fetched \(document.count) bytes of metadata")
        return document
    })
}
```

### What survives a drop

The server stream reconnects on its own, carrying `Last-Event-ID` so the
server can continue rather than replay or skip. It backs off gently between
attempts, because losing this stream is not an outage: requests and responses
keep working without it.

A `404` answering a request that carried a session id means the server has
forgotten the session. The transport forgets it too, so a caller can
re-initialize rather than send every later request into the same wall.

### When to Use

- Remote servers written against MCP 2025-03-26 or later
- Anything needing progress notifications or sampling
- OAuth-protected servers — see ``MCPOAuthSession``

## HTTP/SSE — Remote Servers (Legacy)

## HTTP/SSE — Remote Servers

``HTTPSSETransport`` connects over the older HTTP+SSE shape: a long-lived SSE
stream for receiving, HTTP POST for sending. Prefer
``StreamableHTTPTransport`` for a server that offers it; this remains for
servers that have not moved.

The difference that matters is what a dead stream costs. Here the SSE stream is
the *only* channel for responses, so losing it ends the connection. Streamable
HTTP survives a dead server stream entirely — only server-initiated messages
stop. That is why the two are separate types rather than one with a mode flag.

```swift
// `initialize` opens a live connection, so it is shown inside a function this
// guide never calls. The signatures are checked by the compiler; no server is
// contacted when the guide runs.
func connectOverHTTPSSE() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let transport = HTTPSSETransport(
        url: url,
        headers: ["Authorization": "Bearer token123"],
        connectionTimeout: 30
    )
    let client = MCPClientConnection(transport: transport)
    let info = try await client.initialize(
        clientName: "my-app",
        clientVersion: "1.0.0"
    )
    print("Connected to \(info.serverInfo.name)")
}
```

The SSE connection is established on ``MCPTransport/connect()`` and maintained
until ``MCPTransport/disconnect()`` is called. A failed connect is retried with
an exponential backoff — three attempts by default, configurable through
`maxReconnectAttempts` and `reconnectBaseDelay`.

### Where Messages Are Sent

The first event on the stream, `endpoint`, is the server saying where to POST.
That makes it the server's choice where your `Authorization` header goes, so the
transport holds it to the **origin of the URL you configured**: the same scheme,
host and port.

| The server sends | Stream at `https://mcp.example.com/sse` |
|---|---|
| `/messages?sessionId=1` | accepted — `https://mcp.example.com/messages?sessionId=1` |
| `../messages` | accepted — `..` cannot leave the origin |
| `https://mcp.example.com/messages` | accepted — same origin |
| `https://mcp.example.com:443/messages` | accepted — 443 is the default port |
| `https://other.example/messages` | refused — another host |
| `//other.example/messages` | refused — another host; this is not a path |
| `http://mcp.example.com/messages` | refused — another scheme |
| `https://mcp.example.com:8443/messages` | refused — another port |
| `https://mcp.example.com.other.example/x` | refused — another host |
| `https://user@mcp.example.com/messages` | refused — userinfo |

A refused endpoint fails ``MCPTransport/connect()`` with
``MCPError/endpointRejected(endpoint:reason:)``. Nothing is sent to it, and the
connect is not retried. The TypeScript and Python reference clients apply the
same rule. There is no option to widen it; a server whose stream and message
endpoint genuinely live on different origins needs to be fronted by one.

### When to Use

- Servers that offer only the legacy HTTP+SSE endpoints
- Cross-platform (macOS, iOS, tvOS, watchOS, Linux)

## Redirects

A redirect is a server saying "send that somewhere else", and the request it
is talking about carries your headers, your session id and your message. Both
HTTP transports follow one only when the destination is on the **origin of the
URL you configured** — the same scheme, host and port, which is the comparison
the `endpoint` event is held to, made by the same code.

Anything else is not followed. *Nothing* is sent to the destination: not the
request with its credentials removed, not a bare `GET`. The call that met the
redirect fails with ``MCPError/redirectRejected(destination:reason:)``, the
refusal is logged at error level naming the destination's origin, and it is not
retried — not by ``HTTPSSETransport``'s reconnect loop, and not by the
Streamable HTTP server stream, which stops instead of backing off into the same
answer.

| `Location`, for a transport at `https://mcp.example.com/mcp` | |
|---|---|
| `/v2/mcp` | followed — a path cannot leave the origin |
| `https://mcp.example.com/v2/mcp` | followed — same origin |
| `https://MCP.Example.com:443/v2/mcp` | followed — host case and the default port do not matter |
| `https://other.example/mcp` | refused — another host |
| `//other.example/mcp` | refused — another host; this is not a path |
| `https://mcp.example.com:8443/mcp` | refused — another port |
| `http://mcp.example.com/mcp` | refused — a downgrade to plaintext |
| `https://mcp.example.com.other.example/mcp` | refused — another host |
| `https://user:pw@mcp.example.com/mcp` | refused — userinfo |

The reverse of the downgrade is refused too. A transport configured with
`http://` that is redirected to `https://` on the same host does not follow —
the TypeScript and Python reference clients both do — because by the time the
redirect arrives the request that drew it has already crossed the network in
the clear, headers and body, and following quietly would let every later
request do the same. The error's reason says exactly that, and names the
`https` origin to configure instead.

This applies to every request the transports make:

| Request | Sent to another origin on a redirect |
|---|---|
| ``HTTPSSETransport`` — the stream's `GET`, including reconnects | nothing |
| ``HTTPSSETransport`` — each `POST` | nothing |
| ``StreamableHTTPTransport`` — each `POST` | nothing |
| ``StreamableHTTPTransport`` — the server stream's `GET` | nothing |
| ``StreamableHTTPTransport`` — a resumption `GET` (`Last-Event-ID`) | nothing |
| ``StreamableHTTPTransport`` — the closing `DELETE` | nothing |
| ``WebSocketTransport`` — the upgrade `GET` | nothing — it is never redirected at all |

Through 0.14.0 each of the HTTP rows was "the request, every header in
`headers` except `Authorization` and `Cookie`, `Mcp-Session-Id`,
`MCP-Protocol-Version`, `Last-Event-ID`, and for a `307` or `308` the JSON-RPC
body" — to any host, and from `https` to `http`.

### Within the origin

On the configured origin a redirect is followed **only if it repeats the
request as it was sent**:

| Request | `301` / `302` | `303` | `307` / `308` |
|---|---|---|---|
| A `GET` — the HTTP+SSE stream, the server stream, a resumption | followed | followed | followed |
| A `POST` — every JSON-RPC message | **refused** | **refused** | followed, with its body |
| The closing `DELETE` | followed | **refused** | followed |

The refused cells are the ones where a browser — and `AsyncHTTPClient`, which
these transports used to leave this to — repeats the request as a `GET` with no
body. For a JSON-RPC message that is not a redirect but a deletion: on
Streamable HTTP the `GET` then opened a stream, `send(_:)` returned as though
it had worked, and the caller waited for an answer to a message the server
never received. It now fails at once with
``MCPError/redirectRejected(destination:reason:)``, whose reason says the
server answered a `POST` with a redirect that cannot carry it, and that `307`
and `308` are the statuses that can. A server that moves its endpoint should
answer with one of those.

The rest:

- Up to five redirects are followed for one request, within one deadline. A
  sixth, or a loop, is refused with
  ``MCPError/redirectRejected(destination:reason:)`` — not
  ``MCPError/connectionFailed(reason:)``, because it is the server's
  configuration and will be the same on the next attempt. Nothing retries it.
- Every header goes with a followed redirect, and the `authorization:` provider
  is asked again for each request, so a redirected request carries a current
  token.
- A redirected stream still streams.

A `Location` that will not parse is not followed and not refused: the `3xx` is
reported as the failed request it is.

There is no option to follow redirects to other origins, and no list of
additional origins to allow. If a server has moved, point the transport at
where it is.

## Ending a Streamable HTTP Session

``StreamableHTTPTransport/disconnect()`` sends `DELETE` with the session id.
It is authenticated like every other request: the `authorization:` provider is
asked for a current header — once, and without forcing a refresh — and that
header goes on the `DELETE`, a redirected one included.

Asking can mean a token refresh, and a refresh can stall. So the ask and the
`DELETE` share one deadline, `connectionTimeout`, and `disconnect()` returns
within it whether or not the provider does. If no credential arrives in time,
or the provider throws, **no `DELETE` is sent**: an unauthenticated termination
is the request a server refuses, so it is not sent at all, and the reason is
logged at warning level. The server then expires the session on its own
schedule. A provider that answers `nil` — not signed in — sends the `DELETE`
with no `Authorization` header, as it does every other request.

## WebSocket

``WebSocketTransport`` makes one HTTP request, the upgrade, and that request is
where everything it will ever say about who you are is said.

- **The URL** must be `ws://` or `wss://`, read case-insensitively. Anything
  else — `https://` included — fails ``WebSocketTransport/connect()`` before
  anything is sent. (`WebSocketKit` on its own compares the scheme with the
  exact string `wss`, so `WSS://` or `https://` was connected to as plaintext
  on port 80 in a release build, and stopped a debug build on an assertion.)
- **Credentials.** `headers` go on the upgrade. Pass `authorization:` to have a
  provider asked for a current `Authorization` header first; its answer
  replaces a static one, `nil` sends none, and a provider that throws fails
  `connect()`. A `401` on the upgrade is retried once with a forced refresh,
  as a `401` on a `POST` is on the HTTP transports.
- **Time.** `connectionTimeout` (30 seconds unless you pass another) bounds the
  upgrade. A server that accepts the connection and never answers — or hangs
  up without answering, which `WebSocketKit` does not report — fails
  `connect()` when it runs out, where it used to leave it waiting for ever.
- **Redirects** are never followed: any answer but `101` fails the upgrade.

```swift
func connectSocketWithOAuth(session: MCPOAuthSession) async throws {
    guard let url = URL(string: "wss://mcp.example.com/ws") else { return }
    let transport = WebSocketTransport(
        url: url,
        authorization: { forcing in
            try await session.authorizationHeader(forcingRefresh: forcing)
        },
        connectionTimeout: 15)
    try await transport.connect()
}
```

## Plaintext URLs

None of the network transports refuses `http://` or `ws://`. That is how a
server on loopback or a private network is reached, and ``ServerTrust`` — below
— decides *which certificate* an `https://` or `wss://` server may present, not
whether there is one. The rule is the same for all three: the scheme you
configure is the scheme that is used, it is never upgraded or downgraded for
you, and a redirect that would change it is refused.

What all three do is warn. When a transport is configured with headers or an
`authorization:` provider and its URL is `http://` or `ws://` to any host but
this machine (`localhost`, `127.0.0.0/8`, `::1`), `connect()` logs one warning
naming the origin: those credentials are about to cross a network unencrypted.

## Self-Signed and Private-CA Servers

The three network transports — ``StreamableHTTPTransport``, ``HTTPSSETransport``
and ``WebSocketTransport`` — each take a ``ServerTrust``, which says which
certificate roots the server's chain may end at. It defaults to
``ServerTrust/system``: the platform's root store, which is what any publicly
certified server needs.

A development server with a self-signed certificate, or a server behind a
private certificate authority, is trusted by *supplying the certificate*:

```swift
// Shown inside functions this guide never calls: one reads a file that is not
// there when the guide runs, and both would open a connection.
func connectToSelfSignedServer() async throws {
    guard let url = URL(string: "https://dev.internal:8443/mcp") else { return }

    // The server's own certificate, and nothing else. A server presenting any
    // other certificate — including another self-signed one — is refused.
    let trust = try ServerTrust.onlyRoots([.pemFile("/etc/mcp/dev-server.pem")])

    let transport = StreamableHTTPTransport(url: url, serverTrust: trust)
    let client = MCPClientConnection(transport: transport)
    _ = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")
}

func connectBehindPrivateAuthority(rootPEM: String) throws {
    guard let url = URL(string: "wss://mcp.corp.example/ws") else { return }

    // The system roots as well as the private one, for a client that reaches
    // public servers too.
    let trust = try ServerTrust.additionalRoots([.pem(rootPEM)])

    // What was just trusted, as `openssl x509 -fingerprint -sha256` prints it.
    print(trust.rootFingerprints)

    _ = WebSocketTransport(url: url, serverTrust: trust)
}
```

### What is still checked

Everything. A supplied root changes who is allowed to have signed the server's
certificate; it does not change whether that is checked, and there is no option
that does. In particular:

- **The hostname.** The certificate must carry the host in the URL as a subject
  alternative name — a DNS name, or an IP address if the URL uses one. A trusted
  certificate issued for another name is refused.
- **The chain.** It must end at a supplied root, or for
  ``ServerTrust/additionalRoots(_:)`` at a supplied root or a system one.
- **The dates.** An expired certificate is refused even if it is the one you
  supplied.

On Apple platforms ``ServerTrust/additionalRoots(_:)`` is evaluated by the
system verifier, which applies Apple's own requirements for TLS server
certificates — among them an extended key usage of `serverAuth`.
``ServerTrust/onlyRoots(_:)`` is evaluated by BoringSSL on every platform.

### When it fails

A ``ServerTrust`` that cannot be built — a missing file, text holding no
certificate, an empty list — throws ``ServerTrustError`` where it is
constructed, before any transport exists. Nothing falls back to the system
roots.

A server that is refused surfaces as ``MCPError/connectionFailed(reason:)``
from the first request, with a reason that says the TLS handshake failed and
names the server's origin. The HTTP transports retry a failed connection until
`connectionTimeout` elapses, so a refusal is reported after that long rather
than at once.

### Why there is no "trust anything" switch

Versions before 0.13.0 had `trustSelfSignedCertificates: Bool`. It did not
trust a self-signed certificate; it turned verification off, which accepts any
certificate from anyone able to answer the connection. It has been removed —
the old spelling is a compile error that points here.

## Stdio — Local Subprocess

``StdioTransport`` launches an MCP server as a local child process and
communicates via newline-delimited JSON over stdin/stdout pipes. This is ideal
for development and testing against locally-installed MCP servers.

```swift
// Spawning the subprocess is likewise a live operation; shown, not run.
func connectOverStdio() async throws {
    let stdioTransport = StdioTransport(
        command: "/usr/local/bin/my-mcp-server",
        arguments: ["--verbose"],
        environment: ["MCP_LOG_LEVEL": "debug"]
    )
    let stdioClient = MCPClientConnection(transport: stdioTransport)
    let stdioInfo = try await stdioClient.initialize(
        clientName: "dev-tool",
        clientVersion: "0.1.0"
    )
    print("Connected to \(stdioInfo.serverInfo.name)")
}
```

The subprocess is spawned on ``MCPTransport/connect()`` and terminated
gracefully on ``MCPTransport/disconnect()`` (stdin close → SIGTERM → SIGKILL).

### When to Use

- Local development with `npx`-based MCP servers
- Testing against a server binary on your machine
- macOS and Linux only (requires `Foundation.Process`)

### Platform Availability

`StdioTransport` uses `Foundation.Process` for subprocess management and is
only available on macOS and Linux. It is **not** available on iOS, tvOS, or
watchOS. The type is conditionally compiled with `#if os(macOS) || os(Linux)`.

## Custom Transports

Implement ``MCPTransport`` to add support for other communication channels:

```swift
// This is the shape `MCPTransport` already has — repeated here for reference,
// under a distinct name so the guide does not redeclare the real protocol.
protocol MyCustomTransport: Sendable {
    func connect() async throws
    func disconnect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
}
```

All four methods are required. The transport must be `Sendable` for use with
the ``MCPClientConnection`` actor. Message framing (how individual JSON-RPC
messages are delimited) is the transport's responsibility.
