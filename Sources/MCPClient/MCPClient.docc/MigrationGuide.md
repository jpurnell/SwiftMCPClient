# Migrating to MCPClient v1.0.0

Upgrade from v0.4.0 to v1.0.0 with this guide covering all breaking changes.

## Overview

MCPClient v1.0.0 introduces two breaking changes to improve MCP specification
compliance. Both are straightforward to migrate. This guide shows before/after
code for each change, plus highlights the new features available in v1.0.

Every example below runs against this connection:

```swift
import MCPClient

// Each "after" example below is a function this guide defines but never calls.
// They need a live server, and one that reached for a server would throw or
// hang here with none to answer it. The compiler still checks every signature.
func connectedClient() async throws -> MCPClientConnection? {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return nil }
    let transport = HTTPSSETransport(url: url)
    let client = MCPClientConnection(transport: transport)
    _ = try await client.initialize(clientName: "my-app", clientVersion: "1.0")
    return client
}
```

## MCPContent is now a discriminated union

The biggest change: ``MCPContent`` was previously a struct with optional fields.
It is now an enum with cases for each content type, matching the MCP spec's
`TextContent | ImageContent | EmbeddedResource` union.

### Before (v0.4.0)

<!-- docs:illustrative -->
```swift
let result = try await client.callTool(name: "analyze", arguments: [:])
for block in result.content {
    if block.type == "text" {
        print(block.text ?? "")
    }
}
```

### After (v1.0.0)

```swift
func readContentUnion() async throws {
    guard let client = try await connectedClient() else { return }
    let result = try await client.callTool(name: "analyze", arguments: [:])
    for block in result.content {
        switch block {
        case .text(let str, let annotations):
            print(str)
            if let annotations { print("  annotations: \(annotations)") }
        case .image(let base64, let mimeType, _):
            print("image (\(mimeType)), \(base64.count) base64 characters")
        case .resource(let contents, _):
            print("embedded resource: \(contents)")
        }
    }
}
```

### Key differences

- **No more `block.type` / `block.text`** — use pattern matching instead
- **Annotations built in** — each case carries optional ``MCPAnnotations``
- **Type safety** — the compiler ensures you handle all content types
- **Unified with prompts** — ``MCPPromptContent`` is now a typealias for ``MCPContent``

## MCPError.requestFailed now includes data

The `.requestFailed` error case gained an optional `data` field to surface the
JSON-RPC error's `data` payload.

### Before (v0.4.0)

<!-- docs:illustrative -->
```swift
do {
    _ = try await client.callTool(name: "broken")
} catch MCPError.requestFailed(let code, let message) {
    print("Error \(code): \(message)")
}
```

### After (v1.0.0)

```swift
func catchRequestFailure() async throws {
    guard let client = try await connectedClient() else { return }
    do {
        _ = try await client.callTool(name: "broken")
    } catch MCPError.requestFailed(let code, let message, let data) {
        print("Error \(code): \(message)")
        if let data {
            print("Additional info: \(data)")
        }
    }
}
```

If you don't need the data field, use a wildcard:

<!-- docs:illustrative -->
```swift
} catch MCPError.requestFailed(let code, let message, _) {
```

## New features in v1.0.0

### Client capabilities

Declare client capabilities during initialization:

```swift
func initializeWithCapabilities() async throws {
    guard let client = try await connectedClient() else { return }
    let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
    let initializeResult = try await client.initialize(
        clientName: "my-app",
        clientVersion: "1.0",
        capabilities: caps
    )
}
```

### Progress tokens

Track progress for long-running tool calls:

```swift
func callToolWithProgressToken() async throws {
    guard let client = try await connectedClient() else { return }
    let progressResult = try await client.callTool(
        name: "slow_analysis",
        arguments: ["url": .string("https://example.com")],
        progressToken: .string("analysis-1")
    )
}
```

### Graceful disconnect

Clean up connections properly:

```swift
func closeTheConnection() async throws {
    guard let client = try await connectedClient() else { return }
    try await client.disconnect()
}
```

### Request timeouts

Configure per-connection timeout:

```swift
func clientWithLongerTimeout() async throws {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return }
    let transport = HTTPSSETransport(url: url)
    let patientClient = MCPClientConnection(
        transport: transport,
        requestTimeout: .seconds(60)
    )
}
```

### Sampling

Handle server requests for LLM completions:

```swift
func registerSamplingHandler() async throws {
    guard let client = try await connectedClient() else { return }
    // Stand-in for whichever model you call.
    struct MyLLM {
        func complete(_ messages: [MCPSamplingMessage]) async throws -> String {
            "a completion for \(messages.count) message(s)"
        }
    }
    let myLLM = MyLLM()

    await client.setSamplingHandler { request in
        let response = try await myLLM.complete(request.messages)
        return MCPSamplingResult(
            role: .assistant,
            content: .text(response),
            model: "my-model",
            stopReason: "endTurn"
        )
    }
}
```

### Typed notification streams

Subscribe to specific notification types:

```swift
func consumeProgressAndLogs() async throws {
    guard let client = try await connectedClient() else { return }
    for await progress in await client.progressUpdates {
        print("Progress: \(progress.progress)/\(progress.total ?? 0)")
    }

    for await message in await client.logMessages {
        print("[\(message.level)] \(message.data)")
    }
}
```

### WebSocket transport

Connect via WebSocket instead of HTTP/SSE:

```swift
func connectOverWebSocket() throws {
    guard let url = URL(string: "wss://mcp.example.com/ws") else { return }
    let webSocketTransport = WebSocketTransport(
        url: url,
        headers: ["Authorization": "Bearer token"]
    )
    _ = webSocketTransport
}
```

## Migrating to 0.13.0: `trustSelfSignedCertificates` is removed

The network transports no longer accept `trustSelfSignedCertificates`. Passing
`true` disabled certificate verification entirely — it did not trust a
self-signed certificate, it trusted whoever answered. The old spelling is now a
compile error.

Where the argument was `false`, delete it. Where it was `true`, supply the
certificate the server presents, or the authority that issued it, through
``ServerTrust``:

```swift
func connectWithSuppliedCertificate() throws {
    guard let url = URL(string: "https://dev.internal:8443/mcp") else { return }

    // Before: StreamableHTTPTransport(url: url, trustSelfSignedCertificates: true)
    let trust = try ServerTrust.onlyRoots([.pemFile("/etc/mcp/dev-server.pem")])
    _ = StreamableHTTPTransport(url: url, serverTrust: trust)
}
```

The certificate must name the host in the URL as a subject alternative name;
that check was skipped before and is not skippable now. See
<doc:TransportGuide> for the details.

## Migrating to 0.14.0: `MCPError` gains `endpointRejected`

``MCPError`` has a new case, ``MCPError/endpointRejected(endpoint:reason:)``. A `switch` over
`MCPError` with no `default` no longer compiles until it handles the case.

It is thrown by ``HTTPSSETransport`` when the server's `endpoint` event names a destination
off the origin of the URL the transport was given — another host, another port, or `http` for
an `https` stream. Before 0.14.0 the transport would have sent every message there, with the
`Authorization` header attached. Nothing is sent now, and the connection is not retried: the
server will say the same thing again.

```swift
func describeEndpointRejection(_ error: MCPError) -> String {
    switch error {
    case .endpointRejected(let endpoint, let reason):
        return "The server asked for messages to be sent to \(endpoint): \(reason)."
    default:
        return String(describing: error)
    }
}
```

A server that deliberately serves its message endpoint from another origin is not supported
by the legacy HTTP+SSE transport. Use ``StreamableHTTPTransport``, which posts only to the URL
it was given.

## After 0.14.0: cross-origin redirects are not followed, and `MCPError` gains `redirectRejected`

Two changes, one cause. ``StreamableHTTPTransport`` and ``HTTPSSETransport`` used to follow
a redirect wherever it pointed. They now follow one only to the origin of the URL they were
configured with — the same scheme, host and port.

**If your server redirects within its own origin** — `/mcp` to `/mcp/`, say — nothing changes.

**If it redirects to another origin**, the request now fails with
``MCPError/redirectRejected(destination:reason:)`` where it used to be repeated at the new
address. That includes `http://` to `https://` on the same host. Configure the transport with
the URL the server redirects *to*; `destination` in the error is its origin:

```swift
func describeRedirectRejection(_ error: MCPError) -> String {
    switch error {
    case .redirectRejected(let destination, let reason):
        return "The server redirected to \(destination), which was not followed: \(reason)."
    default:
        return String(describing: error)
    }
}
```

There is no option that restores the old behaviour.

``MCPError/redirectRejected(destination:reason:)`` is a new case on a public enum, so a
`switch` over `MCPError` with no `default` no longer compiles until it handles it.

### A `POST` answered `301`, `302` or `303` now fails

Those three statuses repeat a `POST` as a `GET` with no body. The transports
used to do that, which dropped the JSON-RPC message: on Streamable HTTP the
`GET` opened a stream, `send(_:)` returned, and the request timed out
unanswered. They now refuse the redirect with
``MCPError/redirectRejected(destination:reason:)``. A server that moves its
endpoint must answer `307` or `308`; a client can only be pointed at the new
URL. A `303` answering the closing `DELETE` is refused the same way. `GET`
requests still follow all five statuses within the origin.

### A redirect loop is `redirectRejected`, not `connectionFailed`

So is a sixth redirect in a row. Code that retried on `connectionFailed` no
longer retries these — which is the point: they are the server's
configuration, and ``HTTPSSETransport/connect()`` no longer spends its
reconnect attempts on them either.

### The session `DELETE` is authenticated

``StreamableHTTPTransport/disconnect()`` now asks the `authorization:`
provider for a header — once, unforced, and for no longer than
`connectionTimeout`. A provider is therefore called during `disconnect()`
where it was not before. If it does not answer in time, or throws, no `DELETE`
is sent.

### `WebSocketTransport`

A new initialiser takes an `authorization:` provider and a
`connectionTimeout`; the existing one is unchanged and still compiles.

```swift
func connectSocket(header: @escaping AuthorizationProvider) throws {
    guard let url = URL(string: "wss://mcp.example.com/ws") else { return }
    // `authorization:` is what selects the new initialiser; pass `nil` to set
    // only the timeout.
    _ = WebSocketTransport(url: url, authorization: header, connectionTimeout: 15)
}
```

Three behaviour changes apply to both initialisers. `connect()` now fails
after 30 seconds (or the timeout you pass) against a server that never answers
the upgrade; it used to wait for ever. A URL whose scheme is not `ws` or `wss`
fails `connect()` — `https://` was previously connected to as plaintext. And
`send(_:)` throws ``MCPError/connectionFailed(reason:)`` for a write that
fails, where it used to throw the socket library's error.

### OAuth requests are held to their origin

``MCPOAuthSetup``'s default `fetch` follows a redirect only within the origin
of the document it was asked for, and ``MCPOAuthSession``'s registration and
token requests follow none. A redirect that is not followed throws
``MCPError/redirectRejected(destination:reason:)`` from
``MCPOAuthSession/signIn(server:clientName:tenant:openURL:)``,
``MCPOAuthSession/resume(server:tenant:)`` or
``MCPOAuthSession/authorizationHeader(forcingRefresh:)``, and a network failure
throws ``MCPError/connectionFailed(reason:)`` where `URLError` used to
surface. The defaults are public — ``MCPOAuthSetup/fetchMetadata(from:)`` and
``MCPOAuthTokenTransport`` — and a `fetch` or `tokenTransport` you supply
yourself replaces them and decides for itself.

``MCPOAuthError`` has a new case,
``MCPOAuthError/issuerMismatch(expected:found:)``, thrown when an
authorization server's metadata names a different issuer from the one it was
fetched for (RFC 8414 §3.3). A `switch` over `MCPOAuthError` with no `default`
needs one more arm.

### Smaller things a caller could notice

- **`connectionFailed` text.** The reason for a network failure is now
  `Could not reach <origin>: <kind of failure>` rather than the networking
  library's own description. Code that matched on that text — `NIOSSL`,
  `NWTLSError`, `HTTPClientError` — matches nothing.
- **Path segments in error text.** A path segment that could be a credential
  is replaced with `-redacted-`; see
  <doc:ErrorHandlingGuide#What-an-error-says-about-a-URL>.
- **`MCPConnectionFactory`** returns the connection it began with when it falls
  back to a handshake, instead of a second one on the same transport, and a
  stateless connection's `disconnect()` now disconnects its transport.

- **Error text.** ``MCPError/requestFailed(code:message:data:)`` from a failed POST names the
  endpoint by origin and path — `HTTP 500 from POST to https://mcp.example.com/messages` —
  where it used to include the query. Code that parsed a session id out of that message has
  nothing to parse; code that only logged it is unaffected.
  ``MCPOAuthError/metadataNotFound(url:status:)`` likewise carries the URL without userinfo
  or query.
- **A provider that returns `nil`.** With an `authorization:` provider that returns `nil`, a
  static `Authorization` in `headers` is now left off the Streamable HTTP server stream's
  `GET`, as it already was off every `POST`.

## Migrating to 0.15.0: the Keychain types are SwiftKeychain's

``CredentialStoreKey`` keeps its key through
[SwiftKeychain](https://github.com/jpurnell/SwiftKeychain) instead of Keychain code
written here. **Stored credentials are unaffected:** the key is read from the same Keychain
item every earlier version wrote — the same service and account, readable after the first
unlock on this device only, not synchronized, in the application's own access group, and on
macOS in the login keychain rather than the data-protection keychain. Nothing is migrated,
and nobody is asked to sign in again.

What changes is the API around it. MCPClient no longer declares `KeychainAccess`,
`SystemKeychain` or `CredentialKeyError`; SwiftKeychain's types take their place, and
MCPClient does not re-export them. Code that names any of them adds the dependency and
imports `SwiftKeychain` itself. In `Package.swift`, beside the dependency on this package:

<!-- docs:illustrative -->
```swift
.package(url: "https://github.com/jpurnell/SwiftKeychain.git", from: "0.1.1"),
```

Code that only calls ``CredentialStoreKey/loadOrCreate()`` or
`MCPOAuthSession.persistent()` and catches errors generically needs no change.

| Before (0.14.0) | After (0.15.0) |
|---|---|
| `MCPClient.KeychainAccess` | `SwiftKeychain.KeychainAccess` |
| `MCPClient.SystemKeychain()` | `SwiftKeychain.SystemKeychain(dataProtection: false)` — the default ``CredentialStoreKey`` uses |
| a test double conforming to `KeychainAccess` | `SwiftKeychain.InMemoryKeychain()` |
| `CredentialKeyError.keychain(OSStatus)` | `KeychainError.locked`, `.missingEntitlement` or `.status(Int32)` |
| `CredentialKeyError.malformedKey` | `KeychainError.malformed(String)` |
| `throws` (untyped) | `throws(KeychainError)` |

### Before (0.14.0)

<!-- docs:illustrative -->
```swift
import MCPClient

do {
    let key = try CredentialStoreKey(keychain: SystemKeychain()).loadOrCreate()
    use(key)
} catch CredentialKeyError.keychain(let status) where status == errSecInteractionNotAllowed {
    showLockedBanner()
} catch CredentialKeyError.malformedKey {
    showCorruptKeyBanner()
}
```

### After (0.15.0)

<!-- docs:illustrative -->
```swift
import MCPClient
import SwiftKeychain

do {
    let key = try CredentialStoreKey().loadOrCreate()
    use(key)
} catch .locked {
    showLockedBanner()
} catch .malformed {
    showCorruptKeyBanner()
} catch {
    showKeychainFailure(error)
}
```

In tests, `CredentialStoreKey(keychain: InMemoryKeychain())` replaces a hand-written fake.
A fake of your own now conforms to SwiftKeychain's `KeychainAccess`, whose methods take a
`KeychainItem` rather than a service and an account; ``CredentialStoreKey/item`` is the item
the key lives in.

### Platforms

``CredentialStoreKey`` and `MCPOAuthSession.persistent()` exist on macOS, iOS and visionOS,
the platforms SwiftKeychain supports. On tvOS and watchOS they are no longer compiled, as on
Linux: construct the session with `EncryptedFileClientStorage` and
``EncryptedFileRegistrationStore`` and a key from the platform's own secret store.
