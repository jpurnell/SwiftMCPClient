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

    /// The server answered a request with a redirect this client will not follow.
    ///
    /// ``StreamableHTTPTransport`` and ``HTTPSSETransport`` follow a redirect only when it
    /// stays on the origin they were configured with *and* repeats the request as it was
    /// sent. This is thrown, with nothing further sent, when a redirect:
    ///
    /// - **names another origin** — another host, another port, `http` where `https` was
    ///   configured, or `https` where `http` was. For the last of those the reason says that
    ///   the request has already been sent in the clear, and to configure the `https` URL;
    /// - **cannot carry the request** — a `301`, `302` or `303` answering a `POST`, or a
    ///   `303` answering the session's `DELETE`. Following one repeats the request as a `GET`
    ///   with no body, which drops the JSON-RPC message; `307` and `308` are the statuses
    ///   that redirect a `POST` as it was sent, and the reason says so;
    /// - **loops**, or is the **sixth in a row**.
    ///
    /// It is also thrown by the OAuth requests ``MCPOAuthSession`` and ``MCPOAuthSetup``
    /// make: a metadata fetch redirected off the origin it was fetched from, or a client
    /// registration or token request redirected at all.
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
    ///   - destination: The origin the redirect named, as `scheme://host[:port]` — the
    ///     configured origin itself when the redirect stayed on it. Userinfo, path and query
    ///     are deliberately left out, so this is safe to log.
    ///   - reason: Why it was refused, naming the status and the origin that was configured.
    case redirectRejected(destination: String, reason: String)

    /// A server sent one piece of a response larger than this client will read.
    ///
    /// A response body, a Server-Sent Event and an OAuth document are each read into memory
    /// before they are decoded, so each has a limit: without one, how much memory a
    /// connection costs is the server's to choose. When a limit is passed the read stops —
    /// the rest is not buffered — and this is thrown. It is not transient: the same request
    /// draws the same response.
    ///
    /// For a transport the limits are ``MCPResponseLimits``, 10 MiB each unless configured;
    /// raise them for a server known to send more. For an OAuth metadata or registration
    /// response the limit is 1 MiB and is not configurable. A token response is read by
    /// `swift-oauth`, which has no limit.
    ///
    /// - Parameters:
    ///   - limit: The limit that was passed, in bytes.
    ///   - reason: What was being read and from which origin. Nothing the server sent is
    ///     quoted.
    case responseTooLarge(limit: Int, reason: String)
}
