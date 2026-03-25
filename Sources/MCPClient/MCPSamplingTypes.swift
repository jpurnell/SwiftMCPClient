import Foundation

/// A sampling request from the server, asking the client to create an LLM message.
///
/// When a server needs LLM assistance, it sends a `sampling/createMessage` request.
/// The client invokes its configured LLM and returns the result. This enables
/// human-in-the-loop workflows where the client can review/modify requests
/// before completing them.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "messages": [{"role": "user", "content": {"type": "text", "text": "Hello"}}],
///     "maxTokens": 1000,
///     "systemPrompt": "You are a helpful assistant."
/// }
/// ```
public struct MCPSamplingRequest: Codable, Sendable {
    /// The conversation messages to send to the LLM.
    public let messages: [MCPSamplingMessage]

    /// Optional model preferences (hints, cost/speed/intelligence priorities).
    public let modelPreferences: MCPModelPreferences?

    /// Optional system prompt to use.
    public let systemPrompt: String?

    /// What context to include: `"none"`, `"thisServer"`, or `"allServers"`.
    public let includeContext: String?

    /// Optional sampling temperature.
    public let temperature: Double?

    /// Maximum number of tokens to generate.
    public let maxTokens: Int

    /// Optional stop sequences.
    public let stopSequences: [String]?

    /// Optional metadata.
    public let metadata: AnyCodableValue?

    /// Creates a new sampling request.
    public init(
        messages: [MCPSamplingMessage],
        modelPreferences: MCPModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        stopSequences: [String]? = nil,
        metadata: AnyCodableValue? = nil
    ) {
        self.messages = messages
        self.modelPreferences = modelPreferences
        self.systemPrompt = systemPrompt
        self.includeContext = includeContext
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.metadata = metadata
    }
}

/// A message within a sampling request.
public struct MCPSamplingMessage: Codable, Sendable, Equatable {
    /// The role of the message sender.
    public let role: MCPRole

    /// The message content.
    public let content: MCPContent

    /// Creates a new sampling message.
    public init(role: MCPRole, content: MCPContent) {
        self.role = role
        self.content = content
    }
}

/// Model preferences for a sampling request.
///
/// Allows the server to express preferences about which model the client
/// should use, balancing cost, speed, and intelligence.
public struct MCPModelPreferences: Codable, Sendable, Equatable {
    /// Optional hints for model selection (e.g., model name substrings).
    public let hints: [MCPModelHint]?

    /// Priority for minimizing cost (0.0–1.0).
    public let costPriority: Double?

    /// Priority for maximizing speed (0.0–1.0).
    public let speedPriority: Double?

    /// Priority for maximizing intelligence (0.0–1.0).
    public let intelligencePriority: Double?

    /// Creates new model preferences.
    public init(
        hints: [MCPModelHint]? = nil,
        costPriority: Double? = nil,
        speedPriority: Double? = nil,
        intelligencePriority: Double? = nil
    ) {
        self.hints = hints
        self.costPriority = costPriority
        self.speedPriority = speedPriority
        self.intelligencePriority = intelligencePriority
    }
}

/// A hint for model selection within a sampling request.
public struct MCPModelHint: Codable, Sendable, Equatable {
    /// A model name or substring to match against.
    public let name: String?

    /// Creates a new model hint.
    public init(name: String? = nil) {
        self.name = name
    }
}

/// The result of a sampling request, returned by the client to the server.
public struct MCPSamplingResult: Codable, Sendable {
    /// The role of the generated message (typically `assistant`).
    public let role: MCPRole

    /// The generated content.
    public let content: MCPContent

    /// The model that was used.
    public let model: String

    /// Why generation stopped: `"endTurn"`, `"stopSequence"`, or `"maxTokens"`.
    public let stopReason: String?

    /// Creates a new sampling result.
    public init(role: MCPRole, content: MCPContent, model: String, stopReason: String? = nil) {
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
    }
}

/// The handler type for fulfilling sampling requests.
///
/// When the server sends a `sampling/createMessage` request, this handler is
/// invoked. The handler should call an LLM and return the result. For
/// human-in-the-loop workflows, the handler can present the request to the
/// user for review before proceeding.
public typealias SamplingHandler = @Sendable (MCPSamplingRequest) async throws -> MCPSamplingResult
