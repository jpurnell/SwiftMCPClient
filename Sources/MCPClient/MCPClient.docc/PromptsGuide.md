# Working with Prompts

Use server-provided prompt templates to generate conversation messages.

## Overview

MCP prompts are pre-defined templates that servers offer for common
interactions. They accept arguments and expand into a sequence of messages
ready to feed into an LLM conversation.

## List Available Prompts

Call ``MCPClientConnection/listPrompts()`` to discover what the server offers:

```swift
let prompts = try await client.listPrompts()
for prompt in prompts {
    print("\(prompt.name): \(prompt.description ?? "No description")")
    for arg in prompt.arguments ?? [] {
        let req = arg.required == true ? " (required)" : ""
        print("  - \(arg.name)\(req)")
    }
}
```

## Get a Prompt

Expand a prompt template by name, passing string-valued arguments:

```swift
let result = try await client.getPrompt(
    name: "code_review",
    arguments: ["code": "func add(_ a: Int, _ b: Int) -> Int { a + b }"]
)

for message in result.messages {
    print("[\(message.role.rawValue)] ", terminator: "")
    switch message.content {
    case .text(let text, _):
        print(text)
    case .image(let data, let mimeType, _):
        print("<image: \(mimeType)>")
    case .resource(let contents, _):
        print("<resource>")
    }
}
```

## Content Types

Prompt messages can contain three types of content:

- **Text** — Plain text (``MCPPromptContent/text(_:annotations:)``)
- **Image** — Base64-encoded image with MIME type (``MCPPromptContent/image(data:mimeType:annotations:)``)
- **Resource** — An embedded ``MCPResourceContents`` (``MCPPromptContent/resource(_:annotations:)``)

Each content type can carry optional ``MCPAnnotations`` with audience and
priority hints.

## Prompt Arguments

Arguments are always string-valued per the MCP specification. The
``MCPPromptArgument/required`` flag indicates whether the server expects
the argument to be provided.

```swift
let result = try await client.getPrompt(
    name: "summarize",
    arguments: [
        "text": "Long document text here...",
        "style": "bullet_points"
    ]
)
```
