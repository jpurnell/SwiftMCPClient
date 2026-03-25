# Working with Resources

Read server-side data through the MCP resources capability.

## Overview

MCP resources represent data that a server makes available to clients — files,
database records, API responses, or live system data. Each resource has a
unique URI and optional metadata like MIME type and size.

## List Available Resources

After initialization, call ``MCPClientConnection/listResources()`` to discover
what the server exposes:

```swift
let resources = try await client.listResources()
for resource in resources {
    print("\(resource.name) (\(resource.uri))")
    if let desc = resource.description {
        print("  \(desc)")
    }
}
```

The result auto-paginates — you get the full list regardless of how many
pages the server returns.

## Read Resource Contents

Use ``MCPClientConnection/readResource(uri:)`` to fetch the actual content:

```swift
let contents = try await client.readResource(uri: "file:///logs/app.log")
for item in contents {
    switch item {
    case .text(let uri, let mimeType, let text):
        print("Text from \(uri): \(text.prefix(100))...")
    case .blob(let uri, let mimeType, let blob):
        print("Binary from \(uri): \(blob.count) bytes (base64)")
    }
}
```

A single URI may return multiple content items (e.g., a directory listing),
so the result is always an array.

## Resource Templates

Some servers expose parameterized resources via URI templates (RFC 6570).
Discover them with ``MCPClientConnection/listResourceTemplates()``:

```swift
let templates = try await client.listResourceTemplates()
for template in templates {
    print("\(template.name): \(template.uriTemplate)")
}
// Example: "User Profile: file:///users/{userId}/profile"
```

Expand the template with concrete values, then read it:

```swift
let contents = try await client.readResource(uri: "file:///users/42/profile")
```

## Subscriptions

If the server declares `subscribe: true` in its resources capability, you
can subscribe to change notifications for specific resources:

```swift
try await client.subscribeResource(uri: "file:///logs/app.log")
// ... later ...
try await client.unsubscribeResource(uri: "file:///logs/app.log")
```

> Note: Receiving the actual `notifications/resources/updated` notifications
> requires a notification listener, which will be added in a future release.

## Annotations

Resources and templates may carry ``MCPAnnotations`` with audience and
priority hints:

```swift
if let annotations = resource.annotations {
    print("Audience: \(annotations.audience ?? [])")
    print("Priority: \(annotations.priority ?? 0)")
}
```
