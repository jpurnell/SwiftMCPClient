import Foundation
#if canImport(FoundationNetworking)
// `URLSession`, `URLRequest` and `HTTPURLResponse` live here on Linux rather than in
// Foundation. Without this the file does not compile there at all.
import FoundationNetworking
#endif
import Logging
import SwiftOAuthCore
import SwiftOAuthClient

/// How every OAuth request this package makes reaches the network.
///
/// One place, because the question it answers has to have one answer: *what happens when an
/// authorization server answers with a redirect?* `URLSession`, left alone, follows it
/// wherever it points — to another host, another port, from `https` to `http` — and on a
/// `307` or `308` re-sends the form body with it. For an OAuth request that body is the
/// authorization code and its PKCE verifier, or the refresh token, or the client secret.
///
/// There are two kinds of request, and a redirect is treated according to what the request
/// carries:
///
/// - ``RedirectPolicy/withinOrigin`` — for **metadata**. A discovery document is public and
///   the request for it carries nothing, but the document is only worth anything if it comes
///   from the server it describes. RFC 8414 §3 and RFC 9728 §3 put it at a well-known path
///   on the issuer's — or the protected resource's — own host, and RFC 8414 §3.3 and
///   RFC 9728 §3.3 forbid using a document that names another issuer or resource; their
///   security considerations (§6.2 and §7.3) are about exactly a document accepted from
///   the wrong party. Neither says what a client does with a redirect. This follows one
///   only to the origin of the URL being fetched, compared by
///   ``HTTPOrigin/resolve(_:relativeTo:heldTo:)`` — the comparison the transports use — so
///   that "fetched from the issuer's host" stays true of what is returned.
/// - ``RedirectPolicy/never`` — for **everything that carries a credential or returns one**:
///   dynamic client registration, the token exchange, a refresh, a revocation. The endpoint
///   is the one the server's own metadata named, and RFC 6749 §3.2 has the client `POST` to
///   it. No specification asks a client to follow a redirect from it — RFC 6749, RFC 7009
///   and RFC 7591 do not mention one — and RFC 9700 §4.12 describes what a `307` does to a
///   `POST` that carries credentials: it re-sends them. None is followed, on any status,
///   not even within the origin.
///
/// A refused redirect sends nothing to its destination and fails the request with
/// ``MCPError/redirectRejected(destination:reason:)``, which names the destination by origin
/// only. A request that cannot be made at all fails with
/// ``MCPError/connectionFailed(reason:)``, composed by ``TransportFailure`` — `URLSession`'s
/// own error carries the whole failing URL, query included.
enum OAuthHTTP {

    /// What a redirect is allowed to do to a request.
    enum RedirectPolicy: Sendable, Equatable {
        /// Followed, but only to the origin of the URL being fetched. For metadata.
        case withinOrigin
        /// Not followed. For any request that carries a credential, or returns one.
        case never
    }

    /// How many same-origin redirects a metadata fetch may follow — the transports' limit.
    static let maximumRedirects = SameOriginRedirects.maximumRedirects

    /// Sends one request under a redirect policy.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - policy: What a redirect may do to it.
    ///   - purpose: What the request is, in a few words, for the error and the log —
    ///     `"token"`, `"client registration"`, `"metadata"`.
    /// - Returns: The response body and the response.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if the server answered
    ///   with a redirect the policy does not follow; ``MCPError/connectionFailed(reason:)``
    ///   if the request could not be made.
    static func data(
        for request: URLRequest,
        policy: RedirectPolicy,
        purpose: String
    ) async throws -> (Data, URLResponse) {
        try await withSession(policy: policy, purpose: purpose, reaching: request.url) { session in
            try await session.data(for: request)
        }
    }

    /// Runs an operation on a `URLSession` held to a redirect policy.
    ///
    /// The session is made for the operation and invalidated after it. That costs a
    /// connection that might have been reused — on requests made a handful of times per
    /// sign-in — and buys a delegate that belongs to exactly one request, so "was *this*
    /// request redirected, and where to" needs no table of tasks to answer.
    ///
    /// - Parameters:
    ///   - policy: What a redirect may do.
    ///   - purpose: What the request is, for the error and the log.
    ///   - url: Where the request is going. Only its origin is ever named.
    ///   - operation: The work, given the session to do it on.
    /// - Returns: What `operation` returned.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if a redirect was refused
    ///   while `operation` ran — whatever `operation` itself made of the `3xx` it was then
    ///   handed; ``MCPError/connectionFailed(reason:)`` for a `URLError`; otherwise whatever
    ///   `operation` threw.
    static func withSession<Value: Sendable>(
        policy: RedirectPolicy,
        purpose: String,
        reaching url: URL?,
        _ operation: (URLSession) async throws -> Value
    ) async throws -> Value {
        let guardian = RedirectGuard(policy: policy)
        let session = URLSession(configuration: .ephemeral, delegate: guardian, delegateQueue: nil)
        // A session holds its delegate until it is invalidated.
        defer { session.finishTasksAndInvalidate() }

        do {
            let value = try await operation(session)
            // The refusal first. Whatever the operation made of the redirect response it
            // was left holding — even a success — the thing that happened is that the
            // server tried to send the request elsewhere.
            if let refusal = guardian.refusal {
                throw refuse(refusal, policy: policy, purpose: purpose)
            }
            return value
        } catch {
            // The same, when the operation failed on that response instead: an OAuth error,
            // a decoding failure, a status it did not expect.
            if let refusal = guardian.refusal {
                throw refuse(refusal, policy: policy, purpose: purpose)
            }
            // `URLError` describes itself with the failing URL, whole. Named by kind and
            // origin instead, as a transport's failure is.
            guard error is URLError else { throw error }
            guard let url else {
                throw MCPError.connectionFailed(
                    reason: "The \(purpose) request failed: \(TransportFailure.kind(of: error))")
            }
            throw MCPError.connectionFailed(reason: TransportFailure.reason(for: error, reaching: url))
        }
    }

    /// Records a refusal and makes the error for it.
    private static func refuse(
        _ refusal: RedirectGuard.Refusal,
        policy: RedirectPolicy,
        purpose: String
    ) -> MCPError {
        let reason: String
        switch (policy, refusal.cause) {
        case (.never, _):
            reason = "HTTP \(refusal.status) redirected a \(purpose) request. A request that carries or "
                + "returns a credential is sent only to the endpoint the authorization server's metadata "
                + "named, on \(refusal.from), and is never redirected. Nothing was sent to \(refusal.destination)"
        case (.withinOrigin, .tooMany):
            reason = "Too many redirects: more than \(maximumRedirects) redirects in a row for a \(purpose) "
                + "request on \(refusal.from)"
        case (.withinOrigin, _):
            reason = "HTTP \(refusal.status) redirect of a \(purpose) request leaves \(refusal.from). "
                + "A metadata document is accepted only from the origin it describes. "
                + "Nothing was sent to \(refusal.destination)"
        }
        let logger = Logger(label: "MCPClient.OAuthHTTP")
        // logging: swift-log has no privacy annotations; origins only — no path, query, userinfo, header or body
        logger.error("Refused a redirect to \(refusal.destination): \(reason)")
        return MCPError.redirectRejected(destination: refusal.destination, reason: reason)
    }
}

/// Decides, for one request, whether a redirect is followed — and remembers a refusal.
// Justification: the only mutable state is `state`, private and reached only under `lock`.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// A redirect that was not followed.
    struct Refusal: Sendable {
        /// Why it was not followed.
        enum Cause: Sendable { case policy, tooMany }

        let status: Int
        /// The origin the request was being made to.
        let from: String
        /// The origin the redirect named. An origin only: its path and query are the
        /// server's to choose, and are not repeated.
        let destination: String
        let cause: Cause
    }

    private struct State {
        var refusal: Refusal?
        var followed = 0
    }

    private let policy: OAuthHTTP.RedirectPolicy
    private let lock = NSLock()
    private var state = State()

    init(policy: OAuthHTTP.RedirectPolicy) {
        self.policy = policy
    }

    /// The redirect this refused, if it refused one.
    var refusal: Refusal? {
        lock.lock()
        defer { lock.unlock() }
        return state.refusal
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // `nil` is "do not follow": the task completes with the redirect response itself,
        // and no request is made to the destination.
        completionHandler(decide(task: task, status: response.statusCode, next: request))
    }

    /// The request to make next, or `nil` to stop here.
    private func decide(task: URLSessionTask, status: Int, next: URLRequest) -> URLRequest? {
        let fetched = task.originalRequest?.url
        let from = fetched.map(HTTPOrigin.description(of:)) ?? HTTPOrigin.noOrigin
        let destination = next.url.map(HTTPOrigin.description(of:)) ?? HTTPOrigin.noOrigin

        lock.lock()
        defer { lock.unlock() }

        guard policy == .withinOrigin, let fetched, let target = next.url else {
            state.refusal = Refusal(status: status, from: from, destination: destination, cause: .policy)
            return nil
        }
        // Held to the origin of the URL that was asked for — not of the hop before, so a
        // chain cannot walk away from it one step at a time.
        guard case .sameOrigin = HTTPOrigin.resolve(target.absoluteString, relativeTo: fetched, heldTo: fetched) else {
            state.refusal = Refusal(status: status, from: from, destination: destination, cause: .policy)
            return nil
        }
        guard state.followed < OAuthHTTP.maximumRedirects else {
            state.refusal = Refusal(status: status, from: from, destination: destination, cause: .tooMany)
            return nil
        }
        state.followed += 1
        return next
    }
}

/// The token transport ``MCPOAuthSession`` uses unless it is given another.
///
/// It is `swift-oauth`'s `URLSessionTokenTransport`, on a session that follows no redirect.
/// A token request carries the authorization code and its PKCE verifier, or the refresh
/// token, and the client secret when there is one; a `307` or `308` from the token endpoint
/// re-sends all of that to wherever its `Location` points. Here a redirected token request —
/// an exchange, a refresh or a revocation — is not followed on any status, to any
/// destination: nothing is sent, and the request fails with
/// ``MCPError/redirectRejected(destination:reason:)`` naming the destination's origin.
///
/// A network failure is reported as ``MCPError/connectionFailed(reason:)`` naming the
/// endpoint's origin, rather than as `URLSession`'s own error, which carries the whole URL.
///
/// Supplying a different `TokenTransport` to ``MCPOAuthSession`` replaces this, and with it
/// this guarantee: a transport of your own decides for itself what a redirect does.
public struct MCPOAuthTokenTransport: TokenTransport {

    /// Creates the transport.
    public init() {}

    /// Posts form parameters to a token endpoint, following no redirect.
    ///
    /// - Parameters:
    ///   - endpoint: Where to send it.
    ///   - parameters: The form body, unencoded.
    ///   - credentials: Used for client authentication.
    ///   - method: How the credentials should be presented.
    /// - Returns: The provider's token response.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if the endpoint answered
    ///   with a redirect; ``MCPError/connectionFailed(reason:)`` if it could not be reached;
    ///   `OAuthError` for anything the provider rejected.
    public func exchange(
        endpoint: URL,
        parameters: [String: String],
        credentials: ClientCredentials,
        method: ClientAuthenticationMethod
    ) async throws -> TokenResponse {
        try await OAuthHTTP.withSession(policy: .never, purpose: "token", reaching: endpoint) { session in
            try await URLSessionTokenTransport(session: session).exchange(
                endpoint: endpoint, parameters: parameters, credentials: credentials, method: method)
        }
    }
}
