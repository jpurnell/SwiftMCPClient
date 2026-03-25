import Foundation

/// A prompt template exposed by an MCP server.
///
/// Prompts are pre-defined templates that servers offer for common interactions.
/// They may accept arguments that customize the generated messages.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "name": "code_review",
///     "description": "Review code for issues",
///     "arguments": [
///         {"name": "code", "required": true},
///         {"name": "language"}
///     ]
/// }
/// ```
public struct MCPPrompt: Codable, Sendable, Equatable {
    /// The unique name identifying this prompt.
    public let name: String

    /// Optional description of what this prompt does.
    public let description: String?

    /// Optional list of arguments this prompt accepts.
    public let arguments: [MCPPromptArgument]?

    /// Creates a new prompt definition.
    ///
    /// - Parameters:
    ///   - name: The prompt name.
    ///   - description: Optional description.
    ///   - arguments: Optional argument definitions.
    public init(name: String, description: String? = nil, arguments: [MCPPromptArgument]? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

/// An argument accepted by a prompt template.
public struct MCPPromptArgument: Codable, Sendable, Equatable {
    /// The argument name.
    public let name: String

    /// Optional description of the argument.
    public let description: String?

    /// Whether this argument is required.
    public let required: Bool?

    /// Creates a new prompt argument definition.
    ///
    /// - Parameters:
    ///   - name: The argument name.
    ///   - description: Optional description.
    ///   - required: Whether the argument is required.
    public init(name: String, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.description = description
        self.required = required
    }
}

/// A message in a prompt response, with a role and content.
///
/// Prompt messages form a conversation template that clients can present
/// to an LLM. Each message has a role (user or assistant) and a single
/// content block.
public struct MCPPromptMessage: Codable, Sendable, Equatable {
    /// The role of this message's author.
    public let role: MCPRole

    /// The content of this message.
    public let content: MCPPromptContent

    /// Creates a new prompt message.
    ///
    /// - Parameters:
    ///   - role: The message role.
    ///   - content: The message content.
    public init(role: MCPRole, content: MCPPromptContent) {
        self.role = role
        self.content = content
    }
}

/// Content within a prompt message — text, image, or embedded resource.
///
/// Each variant can optionally carry ``MCPAnnotations`` for audience and priority hints.
///
/// ## Variants
///
/// - ``text(_:annotations:)`` — Plain text content
/// - ``image(data:mimeType:annotations:)`` — Base64-encoded image
/// - ``resource(_:annotations:)`` — Embedded resource contents
/// Backward-compatible alias for ``MCPContent``.
///
/// In MCP specification 2024-11-05, prompt message content and tool result
/// content share the same `TextContent | ImageContent | EmbeddedResource`
/// union type. `MCPPromptContent` is retained as a typealias so existing
/// code that references it continues to compile.
public typealias MCPPromptContent = MCPContent

/// The result of a `prompts/get` request.
///
/// Contains the expanded prompt as a sequence of messages, optionally
/// with a description.
public struct MCPPromptResult: Codable, Sendable {
    /// Optional description of the prompt.
    public let description: String?

    /// The prompt messages forming the conversation template.
    public let messages: [MCPPromptMessage]

    /// Creates a new prompt result.
    ///
    /// - Parameters:
    ///   - description: Optional description.
    ///   - messages: The prompt messages.
    public init(description: String? = nil, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}
