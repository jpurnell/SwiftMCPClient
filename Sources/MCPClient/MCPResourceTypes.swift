import Foundation

/// Annotations providing hints about intended audience and priority.
///
/// Used on resources, resource templates, and prompt content to guide
/// how clients should present or prioritize content.
///
/// ## MCP Schema
///
/// ```json
/// {"audience": ["user"], "priority": 0.8}
/// ```
public struct MCPAnnotations: Codable, Sendable, Equatable {
    /// Intended audience roles for this content.
    public let audience: [MCPRole]?

    /// Priority hint between 0.0 (lowest) and 1.0 (highest).
    public let priority: Double?

    /// Creates annotations.
    ///
    /// - Parameters:
    ///   - audience: Optional audience roles.
    ///   - priority: Optional priority value (0.0–1.0).
    public init(audience: [MCPRole]? = nil, priority: Double? = nil) {
        self.audience = audience
        self.priority = priority
    }
}

/// Role identifier used in MCP annotations and prompt messages.
public enum MCPRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
}

/// A resource exposed by an MCP server.
///
/// Resources represent data that an MCP server makes available to clients,
/// such as files, database records, or live system data. Each resource has
/// a unique URI and a human-readable name.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "uri": "file:///logs/app.log",
///     "name": "Application Logs",
///     "description": "Recent application log output",
///     "mimeType": "text/plain",
///     "size": 4096
/// }
/// ```
public struct MCPResource: Codable, Sendable, Equatable {
    /// Unique URI identifying this resource.
    public let uri: String

    /// Human-readable name for this resource.
    public let name: String

    /// Optional description of the resource.
    public let description: String?

    /// Optional MIME type of the resource content.
    public let mimeType: String?

    /// Optional size in bytes of the raw content (before any encoding).
    public let size: Int?

    /// Optional annotations with audience and priority hints.
    public let annotations: MCPAnnotations?

    /// Creates a new resource definition.
    ///
    /// - Parameters:
    ///   - uri: Unique URI identifying this resource.
    ///   - name: Human-readable name.
    ///   - description: Optional description.
    ///   - mimeType: Optional MIME type.
    ///   - size: Optional size in bytes.
    ///   - annotations: Optional audience/priority annotations.
    public init(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: MCPAnnotations? = nil
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
    }
}

/// A parameterized resource template using RFC 6570 URI templates.
///
/// Resource templates allow servers to expose parameterized resources.
/// Clients expand the URI template with concrete values before calling
/// ``MCPClientConnection/readResource(uri:)``.
///
/// ## MCP Schema
///
/// ```json
/// {
///     "uriTemplate": "file:///users/{userId}/profile",
///     "name": "User Profile",
///     "description": "Profile for a specific user"
/// }
/// ```
public struct MCPResourceTemplate: Codable, Sendable, Equatable {
    /// RFC 6570 URI template with parameter placeholders.
    public let uriTemplate: String

    /// Human-readable name for this template.
    public let name: String

    /// Optional description of the resource template.
    public let description: String?

    /// Optional MIME type of the produced resource.
    public let mimeType: String?

    /// Optional annotations with audience and priority hints.
    public let annotations: MCPAnnotations?

    /// Creates a new resource template.
    ///
    /// - Parameters:
    ///   - uriTemplate: RFC 6570 URI template.
    ///   - name: Human-readable name.
    ///   - description: Optional description.
    ///   - mimeType: Optional MIME type.
    ///   - annotations: Optional audience/priority annotations.
    public init(
        uriTemplate: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        annotations: MCPAnnotations? = nil
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

/// Contents of a resource — either text or base64-encoded binary data.
///
/// Returned by ``MCPClientConnection/readResource(uri:)`` as an array,
/// since a single URI may resolve to multiple sub-resources.
///
/// ## Variants
///
/// - ``text(uri:mimeType:text:)`` — UTF-8 text content
/// - ``blob(uri:mimeType:blob:)`` — Base64-encoded binary content
public enum MCPResourceContents: Sendable, Equatable {
    /// Text resource content.
    ///
    /// - Parameters:
    ///   - uri: The resource URI.
    ///   - mimeType: Optional MIME type.
    ///   - text: The text content.
    case text(uri: String, mimeType: String?, text: String)

    /// Binary resource content encoded as base64.
    ///
    /// - Parameters:
    ///   - uri: The resource URI.
    ///   - mimeType: Optional MIME type.
    ///   - blob: Base64-encoded binary data.
    case blob(uri: String, mimeType: String?, blob: String)
}

extension MCPResourceContents: Codable {
    private enum CodingKeys: String, CodingKey {
        case uri, mimeType, text, blob
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)

        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(uri: uri, mimeType: mimeType, text: text)
        } else if let blob = try container.decodeIfPresent(String.self, forKey: .blob) {
            self = .blob(uri: uri, mimeType: mimeType, blob: blob)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "MCPResourceContents must have either 'text' or 'blob' field"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let uri, let mimeType, let text):
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encode(text, forKey: .text)
        case .blob(let uri, let mimeType, let blob):
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encode(blob, forKey: .blob)
        }
    }
}
