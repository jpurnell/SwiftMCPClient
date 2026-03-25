import Foundation

/// A filesystem root that the client exposes to the server.
///
/// Roots tell the MCP server which directories or files the client has access
/// to. The server may request roots via `roots/list`, and the client notifies
/// the server of changes via `notifications/roots/list_changed`.
///
/// ## MCP Schema
///
/// ```json
/// {"uri": "file:///home/user/project", "name": "My Project"}
/// ```
public struct MCPRoot: Codable, Sendable, Equatable {
    /// The root URI (must be a `file://` URI per the MCP spec).
    public let uri: String

    /// Optional human-readable display name.
    public let name: String?

    /// Creates a new root definition.
    ///
    /// - Parameters:
    ///   - uri: The root URI.
    ///   - name: Optional display name.
    public init(uri: String, name: String? = nil) {
        self.uri = uri
        self.name = name
    }
}
