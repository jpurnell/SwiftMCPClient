# Working with Prompts

Use server-provided prompt templates to generate conversation messages.

## Overview

MCP prompts are pre-defined templates that servers offer for common
interactions. They accept arguments and expand into a sequence of messages
ready to feed into an LLM conversation.

## List Available Prompts

These examples run against an initialized connection:

```swift
import MCPClient

// Every example below is a function this guide defines but never calls.
// `initialize` and the calls that follow need a live server, and an example
// that reached for one would hang here with no server to answer. The compiler
// still checks every signature.
func connectedClient() async throws -> MCPClientConnection? {
    guard let url = URL(string: "https://mcp.example.com/sse") else { return nil }
    let client = MCPClientConnection(transport: HTTPSSETransport(url: url))
    _ = try await client.initialize(clientName: "my-app", clientVersion: "1.0.0")
    return client
}
```

Call ``MCPClientConnection/listPrompts()`` to discover what the server offers:

```swift
func listAvailablePrompts() async throws {
    guard let client = try await connectedClient() else { return }
    let prompts = try await client.listPrompts()
    for prompt in prompts {
        print("\(prompt.name): \(prompt.description ?? "No description")")
        for arg in prompt.arguments ?? [] {
            let req = arg.required == true ? " (required)" : ""
            print("  - \(arg.name)\(req)")
        }
    }
}
```

## Get a Prompt

Expand a prompt template by name, passing string-valued arguments:

```swift
func expandCodeReviewPrompt() async throws {
    guard let client = try await connectedClient() else { return }
    let result = try await client.getPrompt(
        name: "code_review",
        arguments: ["code": "func add(_ a: Int, _ b: Int) -> Int { a + b }"]
    )

    for message in result.messages {
        print("[\(message.role.rawValue)] ", terminator: "")
        switch message.content {
        case .text(let text, _):
            print(text)
        case .image(_, let mimeType, _):
            print("<image: \(mimeType)>")
        case .resource:
            print("<resource>")
        }
    }
}
```

## Content Types

Prompt messages can contain three types of content:

- **Text** — Plain text (``MCPContent/text(_:annotations:)``)
- **Image** — Base64-encoded image with MIME type (``MCPContent/image(data:mimeType:annotations:)``)
- **Resource** — An embedded ``MCPResourceContents`` (``MCPContent/resource(_:annotations:)``)

Each content type can carry optional ``MCPAnnotations`` with audience and
priority hints.

## Prompt Arguments

Arguments are always string-valued per the MCP specification. The
``MCPPromptArgument/required`` flag indicates whether the server expects
the argument to be provided.

```swift
func expandSummarizePrompt() async throws {
    guard let client = try await connectedClient() else { return }
    let summary = try await client.getPrompt(
        name: "summarize",
        arguments: [
            "text": "Long document text here...",
            "style": "bullet_points"
        ]
    )
}
```
