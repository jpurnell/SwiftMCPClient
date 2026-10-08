import Foundation

/// Errors that can occur during MCP client operations.
///
/// `MCPError` covers the error conditions specific to MCP protocol communication.
/// Transport-level errors (network failures, process crashes) are surfaced through
/// the ``MCPTransport`` protocol and may be wrapped in ``connectionFailed(reason:)``.
///
/// ## MCP Schema
///
/// JSON-RPC 2.0 error codes map to ``requestFailed(code:message:data:)``:
/// - `-32700`: Parse error
/// - `-32600`: Invalid request
/// - `-32601`: Method not found
/// - `-32602`: Invalid params
/// - `-32603`: Internal error
public enum MCPError: Error, Sendable, Equatable {
    /// Transport failed to connect to the MCP server.
    ///
    /// - Parameter reason: A human-readable description of the connection failure.
    case connectionFailed(reason: String)

    /// The MCP server returned a JSON-RPC error response.
    ///
    /// - Parameters:
    ///   - code: The JSON-RPC error code.
    ///   - message: The error message from the server.
    ///   - data: Optional additional error context from the server.
    case requestFailed(code: Int, message: String, data: AnyCodableValue?)

    /// The request exceeded the configured timeout.
    case timeout

    /// The response could not be decoded as valid JSON-RPC.
    case invalidResponse

    /// The subprocess could not be spawned (StdioTransport).
    ///
    /// - Parameter reason: A human-readable description of the spawn failure.
    case processSpawnFailed(reason: String)

    /// The transport connection was closed unexpectedly (e.g., subprocess exited).
    case transportClosed

    /// The server named a message endpoint this client will not send to.
    ///
    /// In the legacy HTTP+SSE transport the server's `endpoint` event says where every
    /// JSON-RPC message is POSTed, credentials included. ``HTTPSSETransport`` accepts only an
    /// endpoint on the origin of the stream it was configured with — the same scheme, host and
    /// port — and throws this, having sent nothing, for anything else.
    ///
    /// Unlike ``connectionFailed(reason:)`` this is not transient and is not retried: the
    /// server, or something writing into its stream, asked for the session to be sent
    /// elsewhere. Treat it as a reason to distrust the server rather than to try again.
    ///
    /// - Parameters:
    ///   - endpoint: The origin the server named, as `scheme://host[:port]`. Userinfo, path
    ///     and query are deliberately left out, so this is safe to log.
    ///   - reason: Why it was refused, naming the origin that was expected.
    case endpointRejected(endpoint: String, reason: String)

    /// The server redirected a request to an origin this client will not follow it to.
    ///
    /// ``StreamableHTTPTransport`` and ``HTTPSSETransport`` follow a redirect only when its
    /// destination has the scheme, host and port of the URL they were configured with.
    /// Anything else — another host, another port, `http` where `https` was configured — is
    /// not followed: nothing is sent to the destination, not even a request without
    /// credentials, and the operation that met the redirect throws this.
    ///
    /// Distinct from ``endpointRejected(endpoint:reason:)`` because the remedy usually is. A
    /// redirect is most often a server that has moved, or one reached by `http` that wants
    /// `https`: if the destination is the server you meant, configure the transport with that
    /// URL. If it is not, the server — or something answering for it — tried to send the
    /// session elsewhere.
    ///
    /// Like ``endpointRejected(endpoint:reason:)`` it is not transient and is not retried.
    ///
    /// - Parameters:
    ///   - destination: The origin the redirect named, as `scheme://host[:port]`. Userinfo,
    ///     path and query are deliberately left out, so this is safe to log.
    ///   - reason: Why it was refused, naming the status and the origin that was configured.
    case redirectRejected(destination: String, reason: String)
}
