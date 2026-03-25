import Foundation

/// Reference to what is being completed — a prompt or a resource.
///
/// Used with ``MCPClientConnection/complete(ref:argumentName:argumentValue:)``
/// to request autocompletion suggestions from the server.
public enum MCPCompletionRef: Sendable, Equatable {
    /// A prompt reference, identified by name.
    case prompt(name: String)

    /// A resource reference, identified by URI.
    case resource(uri: String)
}

/// The result of a `completion/complete` request.
///
/// Contains suggested completion values and optional pagination information.
public struct MCPCompletionResult: Codable, Sendable {
    /// The suggested completion values (max 100 per response).
    public let values: [String]

    /// Total number of available matches, if known.
    public let total: Int?

    /// Whether additional results exist beyond this response.
    public let hasMore: Bool?

    /// Creates a new completion result.
    ///
    /// - Parameters:
    ///   - values: Suggested completion values.
    ///   - total: Optional total match count.
    ///   - hasMore: Whether more results are available.
    public init(values: [String], total: Int? = nil, hasMore: Bool? = nil) {
        self.values = values
        self.total = total
        self.hasMore = hasMore
    }
}
