# Working with Notifications

Handle server-to-client notifications for progress, logging, and list changes.

## Overview

After initialization, MCP servers can send notifications to the client
at any time. These are routed through a background message dispatcher and
exposed as an `AsyncStream` on ``MCPClientConnection``.

## Consuming Notifications

Access the notification stream via ``MCPClientConnection/notifications``:

```swift
let client = MCPClientConnection(transport: transport)
_ = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")

Task {
    for await notification in client.notifications {
        switch notification {
        case .progress(let p):
            print("Progress: \(p.progress)/\(p.total ?? 0)")
        case .logMessage(let msg):
            print("[\(msg.level)] \(msg.logger ?? "server"): \(msg.data)")
        case .toolsListChanged:
            let tools = try? await client.listTools()
            print("Tools updated: \(tools?.count ?? 0) available")
        case .resourcesListChanged:
            print("Resources changed — re-fetch if needed")
        case .resourceUpdated(let uri):
            print("Resource updated: \(uri)")
        case .promptsListChanged:
            print("Prompts changed — re-fetch if needed")
        }
    }
}
```

## Logging

Control the minimum log level with ``MCPClientConnection/setLogLevel(_:)``:

```swift
try await client.setLogLevel(.warning)
// Server will now only send warning, error, critical, alert, emergency
```

Log levels follow RFC 5424 (syslog) severity, from least to most severe:
`debug` < `info` < `notice` < `warning` < `error` < `critical` < `alert` < `emergency`

## Request Cancellation

Cancel an in-flight request by its ID:

```swift
try await client.cancelRequest(id: 5, reason: "User navigated away")
```

The server SHOULD stop processing and not send a response.

## Autocompletion

Request argument completion suggestions for prompts or resources:

```swift
let result = try await client.complete(
    ref: .prompt(name: "code_review"),
    argumentName: "language",
    argumentValue: "py"
)
for value in result.values {
    print("  \(value)")  // "python", "pytorch", "pyside"
}
```

## Roots

Register a handler for the server's `roots/list` requests:

```swift
await client.setRootsHandler {
    [
        MCPRoot(uri: "file:///project", name: "My Project"),
        MCPRoot(uri: "file:///data", name: "Data Directory")
    ]
}
```

Notify the server when roots change:

```swift
try await client.notifyRootsChanged()
```
