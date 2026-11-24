import Foundation
#if canImport(FoundationNetworking)
// `URLSession`, `URLRequest` and `HTTPURLResponse` live here on Linux rather than in
// Foundation. Without this the file does not compile there at all.
import FoundationNetworking
#endif
import Logging
import SwiftOAuthCore
import SwiftOAuthClient
#if canImport(Security)
import Security
#endif

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
/// Three more things are true of every request made here, whatever it carries:
///
/// - **The response is read up to ``maximumResponseBytes`` and no further.** A metadata
///   document, a registration and a token response are each a few kilobytes. A body past
///   the limit — one with no end included — is not buffered: the transfer is cancelled at
///   the chunk that crosses it and the request fails with
///   ``MCPError/responseTooLarge(limit:reason:)``.
/// - **No cookie is stored or sent, no stored credential is offered, and nothing is
///   cached.** The session is made for the one request with cookie storage, credential
///   storage and the URL cache all switched off, so a `Set-Cookie` on one hop of a
///   same-origin redirect is not replayed on the next, and nothing a previous sign-in left
///   on this machine travels with this one.
/// - **The delegate is the session's**, set when the session is made. On Linux,
///   `URLSession.data(for:delegate:)` accepts a per-task delegate and never consults it for
///   a redirect; a session's own delegate is consulted on both platforms.
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

    /// The most bytes an OAuth response may hold: 1 MiB.
    ///
    /// Chosen against what these documents are. Authorization-server metadata from the
    /// large public providers is 1–4 kB and protected-resource metadata is smaller; a
    /// registration response is under a kilobyte; a token response is two or three tokens,
    /// and a JWT carrying a great many claims is still tens of kilobytes. 1 MiB is some
    /// hundreds of times the largest of those, and small enough to be read into memory
    /// without a second thought. Not configurable: nothing legitimate was found near it.
    static let maximumResponseBytes = 1024 * 1024

    /// Certificate roots a test's loopback TLS server chains to, DER-encoded.
    ///
    /// **A seam for this package's own tests, and nothing else.** `URLSession` verifies a
    /// server against the system's roots and offers no configuration for any other, so a
    /// test cannot stand up an `https` server on loopback and have these requests reach it
    /// — which left "an `https` endpoint redirecting to `http`" untested on the wire. A test
    /// binds this for the duration of one call; the request made inside trusts these roots
    /// *instead of* the system's, with the hostname still verified.
    ///
    /// It is internal and task-local: no initialiser, parameter or configuration value
    /// reaches it, so nothing a caller of this library can write sets it, and outside a
    /// `withValue` scope it is empty — which is every request in a shipped program. It has
    /// effect only where the Security framework is; on Linux `URLSession` exposes no trust
    /// decision to hook, and it is ignored.
    @TaskLocal static var trustedRootsForTesting: [Data] = []

    /// Sends one request under a redirect policy, reading no more than a limit.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - policy: What a redirect may do to it.
    ///   - purpose: What the request is, in a few words, for the error and the log —
    ///     `"token"`, `"client registration"`, `"metadata"`.
    ///   - limit: The most bytes of response body to accept. Defaults to
    ///     ``maximumResponseBytes``.
    /// - Returns: The response body and the response.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if the server answered
    ///   with a redirect the policy does not follow;
    ///   ``MCPError/responseTooLarge(limit:reason:)`` if the body is larger than `limit`;
    ///   ``MCPError/connectionFailed(reason:)`` if the request could not be made.
    static func data(
        for request: URLRequest,
        policy: RedirectPolicy,
        purpose: String,
        limit: Int = maximumResponseBytes
    ) async throws -> (Data, URLResponse) {
        // Read here, in the caller's task: the delegate is called on the session's queue,
        // where a task-local has no value.
        let exchange = Exchange(policy: policy, limit: limit, trustedRoots: trustedRootsForTesting)
        // The session is made for the request and invalidated after it. That costs a
        // connection that might have been reused — on requests made a handful of times per
        // sign-in — and buys a delegate that belongs to exactly one request, so "was *this*
        // request redirected, and how much has it sent back" needs no table of tasks.
        let session = URLSession(configuration: configuration(), delegate: exchange, delegateQueue: nil)
        // A session holds its delegate until it is invalidated.
        defer { session.finishTasksAndInvalidate() }

        // A data task with no completion handler, so the body arrives at the delegate a
        // chunk at a time and can be stopped. `data(for:)` hands it over only when it is
        // complete — which, for a body with no end, is never.
        let task = session.dataTask(with: request)
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    exchange.begin(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            // The refusal first. Whatever came back with the redirect response — even a
            // body that decodes — the thing that happened is that the server tried to send
            // the request elsewhere.
            if let refusal = exchange.refusal {
                throw refuse(refusal, policy: policy, purpose: purpose)
            }
            return result
        } catch {
            if let refusal = exchange.refusal {
                throw refuse(refusal, policy: policy, purpose: purpose)
            }
            // The transfer was cancelled from here, so the `URLError` it ended with is this
            // code's doing and not the network's.
            if exchange.exceededLimit {
                let logger = Logger(label: "MCPClient.OAuthHTTP")
                // logging: swift-log has no privacy annotations; the limit, the purpose and the endpoint's origin — nothing the server sent
                logger.error("Stopped reading a \(purpose) response from \(request.url.map(HTTPOrigin.description(of:)) ?? HTTPOrigin.noOrigin): larger than \(limit) bytes")
                throw MCPResponseLimits.exceeded(limit, reading: "\(purpose) response", from: request.url)
            }
            // `URLError` describes itself with the failing URL, whole. Named by kind and
            // origin instead, as a transport's failure is.
            guard error is URLError else { throw error }
            guard let url = request.url else {
                throw MCPError.connectionFailed(
                    reason: "The \(purpose) request failed: \(TransportFailure.kind(of: error))")
            }
            throw MCPError.connectionFailed(reason: TransportFailure.reason(for: error, reaching: url))
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
        // Read here, in the caller's task: a delegate is called on the session's queue, where a
        // task-local has no value.
        let guardian = RedirectGuard(policy: policy, trustedRoots: trustedRootsForTesting)
        let session = URLSession(configuration: configuration(), delegate: guardian, delegateQueue: nil)
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
            // swift-oauth 1.0.0-beta.2 and later decline the redirect themselves, on a task
            // delegate of their own, so this session's guard is never asked. What comes back
            // is their `OAuthRedirectRefused`; it is the same event and is reported the same way.
            if let refused = error as? OAuthRedirectRefused {
                throw refuse(
                    Exchange.Refusal(
                        status: refused.status, from: refused.endpoint,
                        destination: refused.destination, cause: .policy),
                    policy: policy, purpose: purpose)
            }
            // swift-oauth caps every response it reads at 1 MiB (since 1.0.0-beta.10) and says
            // so with its own error. It is the same event as a metadata or registration
            // response over the limit, and is reported the same way.
            if let tooLarge = error as? OAuthResponseTooLarge {
                // logging: swift-log has no privacy annotations; the purpose, the limit and the endpoint's origin — nothing the server sent
                Logger(label: "MCPClient.OAuthHTTP").error(
                    "Stopped reading a \(purpose) response from \(tooLarge.endpoint): larger than \(tooLarge.limit) bytes")
                throw MCPResponseLimits.exceeded(tooLarge.limit, reading: "\(purpose) response", from: url)
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

    #if canImport(Security)
    /// Answers a server-trust challenge with `roots` as the only anchors, or leaves it to the
    /// system when there are none. Tests only — see ``trustedRootsForTesting``.
    ///
    /// - Parameters:
    ///   - challenge: The challenge.
    ///   - roots: DER certificates to anchor on instead of the system's.
    ///   - completionHandler: Resumed with the decision.
    static func answer(
        _ challenge: URLAuthenticationChallenge,
        trusting roots: [Data],
        _ completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Empty outside this package's tests — see `OAuthHTTP.trustedRootsForTesting` — and
        // then the system decides, exactly as if this method were not here.
        guard !roots.isEmpty,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // These roots *instead of* the system's, and the policy the system attached —
        // which checks the hostname — left as it is.
        let anchors = roots.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard anchors.count == roots.count,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    #endif

    /// The configuration every OAuth request's session is made with.
    ///
    /// Ephemeral, and then stripped of the three stores an ephemeral configuration still
    /// has in memory. An OAuth request is authenticated by what is in it — a code and its
    /// verifier, a refresh token, the client's credentials — and by nothing ambient: a
    /// cookie an earlier response set, or a password in the user's keychain for the same
    /// host, has no business on a token request, and a cached metadata document is a
    /// document that was not fetched.
    ///
    /// - Returns: The configuration.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Records a refusal and makes the error for it.
    private static func refuse(
        _ refusal: Exchange.Refusal,
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

/// One request: decides whether its redirects are followed, collects its response up to a
/// limit, and hands the result to whoever is waiting.
// Justification: the only mutable state is `state`, private and reached only under `lock`.
private final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {

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
        var response: URLResponse?
        var body = Data()
        var exceededLimit = false
        var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    }

    private let policy: OAuthHTTP.RedirectPolicy
    private let limit: Int
    private let trustedRoots: [Data]
    private let lock = NSLock()
    private var state = State()

    init(policy: OAuthHTTP.RedirectPolicy, limit: Int, trustedRoots: [Data]) {
        self.policy = policy
        self.limit = limit
        self.trustedRoots = trustedRoots
    }

    /// The redirect this refused, if it refused one.
    var refusal: Refusal? {
        lock.lock()
        defer { lock.unlock() }
        return state.refusal
    }

    /// Whether the transfer was stopped because the body passed the limit.
    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.exceededLimit
    }

    /// Registers who is waiting for the outcome. Called once, before the task starts.
    func begin(_ continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
        lock.lock()
        defer { lock.unlock() }
        state.continuation = continuation
    }

    // MARK: Redirects

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
        // What an earlier hop sent back is not part of the answer.
        state.body = Data()
        return next
    }

    // MARK: The response

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        // A length declared over the limit is refused before any of it is read.
        let declaredTooLarge = response.expectedContentLength > Int64(limit)
        record(response, exceeding: declaredTooLarge)
        if declaredTooLarge { dataTask.cancel() }
        completionHandler(.allow)
    }

    private func record(_ response: URLResponse, exceeding: Bool) {
        lock.lock()
        defer { lock.unlock() }
        state.response = response
        if exceeding { state.exceededLimit = true }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Stopped at the chunk that crosses the limit; what was held is let go, so a body
        // with no end costs at most the limit and one chunk.
        if append(data) { dataTask.cancel() }
    }

    /// Adds a chunk. Returns `true` if the body is now past the limit.
    private func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !state.exceededLimit else { return true }
        guard state.body.count + data.count <= limit else {
            state.exceededLimit = true
            state.body = Data()
            return true
        }
        state.body.append(data)
        return false
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, outcome) = finish(error, fallback: task.response)
        continuation?.resume(with: outcome)
    }

    /// Takes the continuation — once — and says what to resume it with.
    private func finish(
        _ error: (any Error)?, fallback: URLResponse?
    ) -> (CheckedContinuation<(Data, URLResponse), any Error>?, Result<(Data, URLResponse), any Error>) {
        lock.lock()
        defer { lock.unlock() }
        let continuation = state.continuation
        state.continuation = nil
        if let error { return (continuation, .failure(error)) }
        guard let response = state.response ?? fallback else {
            return (continuation, .failure(URLError(.badServerResponse)))
        }
        return (continuation, .success((state.body, response)))
    }

    // MARK: Trust (tests only)

    #if canImport(Security)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        OAuthHTTP.answer(challenge, trusting: trustedRoots, completionHandler)
    }
    #endif
}

/// Decides, for one request, whether a redirect is followed — and remembers a refusal.
// Justification: RedirectGuard's refusal and hop count live in `state`, private and read or written only under `lock`; its policy and trusted roots are immutable lets.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private struct State {
        var refusal: Exchange.Refusal?
        var followed = 0
    }

    private let policy: OAuthHTTP.RedirectPolicy
    private let trustedRoots: [Data]
    private let lock = NSLock()
    private var state = State()

    init(policy: OAuthHTTP.RedirectPolicy, trustedRoots: [Data]) {
        self.policy = policy
        self.trustedRoots = trustedRoots
    }

    #if canImport(Security)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        OAuthHTTP.answer(challenge, trusting: trustedRoots, completionHandler)
    }
    #endif

    /// The redirect this refused, if it refused one.
    var refusal: Exchange.Refusal? {
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
            state.refusal = Exchange.Refusal(status: status, from: from, destination: destination, cause: .policy)
            return nil
        }
        // Held to the origin of the URL that was asked for — not of the hop before, so a
        // chain cannot walk away from it one step at a time.
        guard case .sameOrigin = HTTPOrigin.resolve(target.absoluteString, relativeTo: fetched, heldTo: fetched) else {
            state.refusal = Exchange.Refusal(status: status, from: from, destination: destination, cause: .policy)
            return nil
        }
        guard state.followed < OAuthHTTP.maximumRedirects else {
            state.refusal = Exchange.Refusal(status: status, from: from, destination: destination, cause: .tooMany)
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

    /// Asks a revocation endpoint to revoke a token, following no redirect.
    ///
    /// Forwarded to `URLSessionTokenTransport`, which reads only the status (RFC 7009 §2.2).
    /// The protocol's default would decode a token response from a body that has none.
    ///
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if the endpoint answered
    ///   with a redirect; ``MCPError/connectionFailed(reason:)`` if it could not be reached;
    ///   `OAuthError` for anything the provider rejected.
    public func revoke(
        endpoint: URL,
        parameters: [String: String],
        credentials: ClientCredentials,
        method: ClientAuthenticationMethod
    ) async throws {
        try await OAuthHTTP.withSession(policy: .never, purpose: "token", reaching: endpoint) { session in
            try await URLSessionTokenTransport(session: session).revoke(
                endpoint: endpoint, parameters: parameters, credentials: credentials, method: method)
        }
    }
}
