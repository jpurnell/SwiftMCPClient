import Foundation
#if canImport(FoundationNetworking)
// `URLError` lives here on Linux rather than in Foundation.
import FoundationNetworking
#endif
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import WebSocketKit
#if canImport(Network)
import Network
#endif

/// What a transport says when the network fails underneath it.
///
/// The error a networking library throws is described by that library, and its wording is
/// not something this package controls: today `NIOSSL`'s includes a source path from the
/// machine the binary was built on, and `WebSocketKit`'s used to be the server's whole
/// response head. An error message outlives the request — it is logged, shown, pasted into
/// an issue — so the transports do not pass those descriptions on. They say what *kind* of
/// failure it was, decided from the error's type and case, and which origin it was reaching.
///
/// Host and port are kept: they are origin-level, and they are what tells one unreachable
/// server from another. Nothing else about the URL appears — no path, no query, no userinfo —
/// and nothing a server sent.
enum TransportFailure {

    /// A reason for ``MCPError/connectionFailed(reason:)``, or for a log line.
    ///
    /// - Parameters:
    ///   - error: What the networking library threw.
    ///   - url: The URL the transport was configured with. Only its origin is used.
    /// - Returns: `Could not reach <origin>: <kind>`. The kind is one of a fixed set of
    ///   phrases, or the error's type name; it is never the error's own description.
    static func reason(for error: any Error, reaching url: URL) -> String {
        // One of this package's own connection failures is already composed, and is not
        // wrapped in a second "could not reach".
        if case .connectionFailed(let reason) = error as? MCPError { return reason }
        return "Could not reach \(HTTPOrigin.description(of: url)): \(kind(of: error))"
    }

    /// The kind of failure an error is, in words chosen here.
    ///
    /// - Parameter error: What was thrown.
    /// - Returns: A fixed phrase for a failure this recognises; otherwise the error's type
    ///   name, which is an identifier and cannot carry a value from a request or a response.
    static func kind(of error: any Error) -> String {
        if let own = error as? MCPError { return kind(of: own) }
        if error is CancellationError { return "the request was cancelled" }
        if let client = error as? HTTPClientError { return kind(of: client) }
        if let platform = platformKind(of: error) { return platform }
        if let connection = error as? NIOConnectionError { return kind(of: connection) }
        if let io = error as? IOError { return posixKind(io.errnoCode) }
        if let channel = error as? ChannelError { return kind(of: channel) }
        if error is NIOSSLError || error is BoringSSLError || error is NIOSSLExtraError {
            return "the TLS handshake failed — the server's certificate was not accepted, "
                + "or the server is not speaking TLS on this port"
        }
        if error is HTTPParserError { return "the response was not valid HTTP" }
        if let upgrade = error as? WebSocketClient.Error { return kind(of: upgrade) }
        if let loading = error as? URLError { return kind(of: loading) }
        // The type's name and nothing the value says about itself.
        return "an error of type \(String(reflecting: type(of: error)))"
    }

    /// One of this package's own errors, which is already composed.
    private static func kind(of error: MCPError) -> String {
        switch error {
        case .timeout: return "the request timed out"
        case .transportClosed: return "the connection was closed"
        case .invalidResponse: return "the response was not valid"
        case .connectionFailed(let reason): return reason
        case .requestFailed(let code, _, _): return "the request failed with code \(code)"
        case .processSpawnFailed: return "the server process could not be started"
        case .endpointRejected(let endpoint, _): return "the message endpoint on \(endpoint) was refused"
        case .redirectRejected(let destination, _): return "a redirect to \(destination) was refused"
        }
    }

    private static func kind(of error: HTTPClientError) -> String {
        // Compared against the cases this meets, and named in words chosen here. Its own
        // description is a fixed string per case today; that is its to change.
        if error == .connectTimeout { return "the connection attempt timed out" }
        if error == .deadlineExceeded || error == .readTimeout {
            return "no response before the deadline"
        }
        if error == .remoteConnectionClosed { return "the server closed the connection" }
        if error == .tlsHandshakeTimeout { return "the TLS handshake timed out" }
        if error == .cancelled || error == .requestStreamCancelled { return "the request was cancelled" }
        if error == .alreadyShutdown { return "the transport has been disconnected" }
        if error == .getConnectionFromPoolTimeout { return "no connection became available in time" }
        if error == .uncleanShutdown { return "the connection was closed uncleanly" }
        return "the HTTP client could not complete the request"
    }

    private static func kind(of error: NIOConnectionError) -> String {
        // A connection that was attempted says more than a lookup that half failed: the name
        // resolved, and the address did not answer.
        if let first = error.connectionErrors.first {
            return kind(of: first.error)
        }
        guard error.dnsAError != nil || error.dnsAAAAError != nil else {
            return "the connection could not be made"
        }
        return "the host name could not be resolved"
    }

    private static func kind(of error: ChannelError) -> String {
        switch error {
        case .connectTimeout: return "the connection attempt timed out"
        case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed, .eof:
            return "the server closed the connection"
        default: return "the connection failed"
        }
    }

    private static func kind(of error: WebSocketClient.Error) -> String {
        switch error {
        case .invalidResponseStatus(let head):
            // The status and nothing else of the head: the rest is the server's to fill.
            return "the server answered the WebSocket upgrade with HTTP \(head.status.code)"
        case .invalidURL: return "the WebSocket URL is not usable"
        case .alreadyShutdown: return "the transport has been disconnected"
        }
    }

    /// A `URLSession` failure, by its code. Its own description — and its `userInfo` — carry
    /// the failing URL whole, so nothing of it is used but the code.
    private static func kind(of error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost: return "connection refused"
        case .timedOut: return "no response before the deadline"
        case .cannotFindHost, .dnsLookupFailed: return "the host name could not be resolved"
        case .networkConnectionLost: return "the server closed the connection"
        case .notConnectedToInternet: return "there is no network connection"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "the TLS handshake failed — the server's certificate was not accepted, "
                + "or the server is not speaking TLS on this port"
        case .appTransportSecurityRequiresSecureConnection:
            return "the platform refused a plaintext connection"
        case .httpTooManyRedirects: return "too many redirects"
        case .badServerResponse, .cannotParseResponse: return "the response was not valid HTTP"
        case .cancelled: return "the request was cancelled"
        default: return "the request failed (URL loading error \(error.code.rawValue))"
        }
    }

    /// A POSIX error number, by name. The number is a fact about the failure, not about the
    /// request.
    static func posixKind(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "connection refused"
        case ECONNRESET, EPIPE, ENOTCONN: return "the server closed the connection"
        case ETIMEDOUT: return "the connection attempt timed out"
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return "the host is unreachable"
        case EADDRNOTAVAIL: return "the address is not available"
        default: return "the connection failed (POSIX error \(code))"
        }
    }

    #if canImport(Network)
    /// The errors `AsyncHTTPClient` reports when it runs on Network.framework.
    private static func platformKind(of error: any Error) -> String? {
        if let posix = error as? HTTPClient.NWPOSIXError {
            return posixKind(posix.errorCode.rawValue)
        }
        if let tls = error as? HTTPClient.NWTLSError {
            return tlsKind(tls.status)
        }
        guard let network = error as? NWError else { return nil }
        switch network {
        case .posix(let code): return posixKind(code.rawValue)
        case .dns: return "the host name could not be resolved"
        case .tls(let status): return tlsKind(status)
        default: return "the connection failed"
        }
    }

    /// A Secure Transport status, by number: the number says which check failed and is the
    /// thing to search for.
    private static func tlsKind(_ status: OSStatus) -> String {
        "the TLS handshake failed (Security status \(status)) — the server's certificate was "
            + "not accepted, or the server is not speaking TLS on this port"
    }
    #else
    private static func platformKind(of error: any Error) -> String? { nil }
    #endif
}
