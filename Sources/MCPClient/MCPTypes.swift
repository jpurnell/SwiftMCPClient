import Foundation

/// An MCP tool definition returned by the `tools/list` method.
///
/// Each tool has a unique name, an optional human-readable description,
/// and an optional JSON Schema describing its expected input parameters.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "name": "score_technical_seo",
///     "description": "Calculate technical SEO composite score.",
///     "inputSchema": {
///         "type": "object",
///         "properties": {
///             "ssr_score": {"type": "number", "description": "SSR capability score (0-100)"}
///         },
///         "required": ["ssr_score"]
///     }
/// }
/// ```
public struct MCPTool: Codable, Sendable, Equatable {
    /// The unique identifier for this tool.
    public let name: String

    /// A human-readable description of what this tool does.
    public let description: String?

    /// A JSON Schema object describing the tool's expected input parameters.
    public let inputSchema: AnyCodableValue?

    /// Creates a new tool definition.
    ///
    /// - Parameters:
    ///   - name: The unique tool identifier.
    ///   - description: Optional human-readable description.
    ///   - inputSchema: Optional JSON Schema for input parameters.
    public init(name: String, description: String? = nil, inputSchema: AnyCodableValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// The result of calling an MCP tool via the `tools/call` method.
///
/// Results contain one or more content blocks (typically text) and an optional
/// flag indicating whether the tool execution itself encountered an error.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "content": [
///         {"type": "text", "text": "Technical SEO Score: 74.8 / 100"}
///     ],
///     "isError": false
/// }
/// ```
public struct MCPToolResult: Codable, Sendable, Equatable {
    /// The content blocks returned by the tool.
    public let content: [MCPContent]

    /// Whether the tool execution resulted in an error. `nil` indicates success.
    public let isError: Bool?

    /// Creates a new tool result.
    ///
    /// - Parameters:
    ///   - content: The content blocks returned by the tool.
    ///   - isError: Whether the tool reported an error. Defaults to `nil` (success).
    public init(content: [MCPContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
}

/// A content block within an MCP message or tool result.
///
/// Content blocks carry the actual output from a tool invocation or the body
/// of a prompt message. The MCP protocol defines three content types:
/// text, image (base64-encoded), and embedded resource.
///
/// `MCPContent` uses a discriminated union (Swift enum) that matches the
/// MCP specification's `TextContent | ImageContent | EmbeddedResource` type.
/// Each case carries optional ``MCPAnnotations`` for audience targeting and
/// priority hints.
///
/// ## Usage
///
/// ```swift
/// let result = try await client.callTool(name: "analyze", arguments: [:])
/// for block in result.content {
///     switch block {
///     case .text(let str, _):
///         print(str)
///     case .image(let data, let mimeType, _):
///         print("Image: \(mimeType)")
///     case .resource(let contents, _):
///         print("Resource: \(contents)")
///     }
/// }
/// ```
public enum MCPContent: Sendable, Equatable {
    /// Text content.
    case text(String, annotations: MCPAnnotations? = nil)

    /// Base64-encoded image with MIME type.
    case image(data: String, mimeType: String, annotations: MCPAnnotations? = nil)

    /// Embedded resource contents.
    case resource(MCPResourceContents, annotations: MCPAnnotations? = nil)
}

extension MCPContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, resource, annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let annotations = try container.decodeIfPresent(MCPAnnotations.self, forKey: .annotations)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text, annotations: annotations)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType, annotations: annotations)
        case "resource":
            let resource = try container.decode(MCPResourceContents.self, forKey: .resource)
            self = .resource(resource, annotations: annotations)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown MCPContent type: \(type)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let annotations):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case .image(let data, let mimeType, let annotations):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case .resource(let resource, let annotations):
            try container.encode("resource", forKey: .type)
            try container.encode(resource, forKey: .resource)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        }
    }
}

/// Client capabilities declared during MCP initialization.
///
/// Declares which client-side features are available, such as roots
/// and sampling. Pass to ``MCPClientConnection/initialize(clientName:clientVersion:capabilities:protocolVersion:)``
/// to inform the server of client capabilities.
public struct ClientCapabilities: Codable, Sendable, Equatable {
    /// The client's roots capability, if it supports `roots/list` requests.
    public var roots: RootsCapability?

    /// The client's sampling capability, if it can fulfill `sampling/createMessage`.
    public var sampling: SamplingCapability?

    /// Creates a new client capabilities declaration.
    public init(roots: RootsCapability? = nil, sampling: SamplingCapability? = nil) {
        self.roots = roots
        self.sampling = sampling
    }
}

/// Capability declaration for MCP roots support.
public struct RootsCapability: Codable, Sendable, Equatable {
    /// Whether the client can notify the server when roots change.
    public var listChanged: Bool?

    /// Creates a new roots capability.
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// Capability declaration for MCP sampling support.
public struct SamplingCapability: Codable, Sendable, Equatable {
    /// Creates a new sampling capability.
    public init() {}
}

/// Capability declaration for MCP logging support.
public struct LoggingCapability: Codable, Sendable, Equatable {
    /// Creates a new logging capability.
    public init() {}
}

/// Server capabilities returned during MCP initialization.
///
/// Capabilities declare which MCP features the server supports: tools,
/// resources, prompts, and more. Each capability is optional — its presence
/// indicates the server supports that feature.
public struct ServerCapabilities: Codable, Sendable, Equatable {
    /// The server's tools capability, if it supports tool invocation.
    public let tools: ToolsCapability?

    /// The server's resources capability, if it exposes resources.
    public let resources: ResourcesCapability?

    /// The server's prompts capability, if it offers prompt templates.
    public let prompts: PromptsCapability?

    /// The server's logging capability, if it supports log level control.
    public let logging: LoggingCapability?

    /// Creates a new capabilities declaration.
    ///
    /// - Parameters:
    ///   - tools: Optional tools capability.
    ///   - resources: Optional resources capability.
    ///   - prompts: Optional prompts capability.
    ///   - logging: Optional logging capability.
    public init(
        tools: ToolsCapability? = nil,
        resources: ResourcesCapability? = nil,
        prompts: PromptsCapability? = nil,
        logging: LoggingCapability? = nil
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
    }
}

/// Capability declaration for MCP tools support.
///
/// Indicates whether the server supports dynamic tool list updates.
public struct ToolsCapability: Codable, Sendable, Equatable {
    /// Whether the server can notify clients when the tool list changes.
    public let listChanged: Bool?

    /// Creates a new tools capability.
    ///
    /// - Parameter listChanged: Whether dynamic tool list updates are supported.
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// Capability declaration for MCP resources support.
///
/// Indicates whether the server supports resource subscriptions and
/// dynamic resource list updates.
public struct ResourcesCapability: Codable, Sendable, Equatable {
    /// Whether the server supports per-resource subscriptions.
    public let subscribe: Bool?

    /// Whether the server can notify clients when the resource list changes.
    public let listChanged: Bool?

    /// Creates a new resources capability.
    ///
    /// - Parameters:
    ///   - subscribe: Whether subscriptions are supported.
    ///   - listChanged: Whether dynamic resource list updates are supported.
    public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }
}

/// Capability declaration for MCP prompts support.
///
/// Indicates whether the server supports dynamic prompt list updates.
public struct PromptsCapability: Codable, Sendable, Equatable {
    /// Whether the server can notify clients when the prompt list changes.
    public let listChanged: Bool?

    /// Creates a new prompts capability.
    ///
    /// - Parameter listChanged: Whether dynamic prompt list updates are supported.
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// Server information returned during MCP initialization.
///
/// Identifies the MCP server by name and version.
public struct ServerInfo: Codable, Sendable, Equatable {
    /// The server's human-readable name (e.g., `"geoseo-mcp"`).
    public let name: String

    /// The server's version string (e.g., `"1.0.0"`).
    public let version: String

    /// Creates new server info.
    ///
    /// - Parameters:
    ///   - name: The server name.
    ///   - version: The server version.
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// The full result of an MCP `initialize` response.
///
/// Contains the protocol version negotiated between client and server,
/// the server's capabilities, and identifying information about the server.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "protocolVersion": "2024-11-05",
///     "capabilities": {"tools": {"listChanged": true}},
///     "serverInfo": {"name": "geoseo-mcp", "version": "1.0.0"}
/// }
/// ```
public struct InitializeResult: Codable, Sendable, Equatable {
    /// The MCP protocol version negotiated during initialization.
    public let protocolVersion: String

    /// The server's declared capabilities.
    public let capabilities: ServerCapabilities

    /// Identifying information about the server.
    public let serverInfo: ServerInfo

    /// Creates a new initialization result.
    ///
    /// - Parameters:
    ///   - protocolVersion: The negotiated protocol version.
    ///   - capabilities: The server's capabilities.
    ///   - serverInfo: The server's identifying information.
    public init(protocolVersion: String, capabilities: ServerCapabilities, serverInfo: ServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}
