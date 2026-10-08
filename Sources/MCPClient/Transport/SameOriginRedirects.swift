import Foundation
import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

/// Sends a request and follows its redirects, as long as they stay on the configured origin.
///
/// `AsyncHTTPClient` can follow redirects or not; it cannot follow only some. Left to follow,
/// it goes wherever `Location` says — another host, another port, `http` for `https` — taking
/// every header but four and, on a `307` or `308`, the request body. So the transports' client
/// is built with following turned off (``ServerTrust/makeHTTPClient(connectTimeout:)``) and
/// every request goes through here instead.
///
/// The rule is the one the `endpoint` event is held to, and it is made by the same function,
/// ``HTTPOrigin/resolve(_:relativeTo:heldTo:)``: a destination with the configured URL's
/// scheme, host and effective port is followed, and anything else is not. "Not followed"
/// means nothing is sent there at all — the request itself says where the client was and
/// what it was doing, before any header is counted.
///
/// On the origin there is a second rule: a redirect is followed only if it repeats the
/// request as it was sent. `307` and `308` always do; `301`, `302` and `303` do for a `GET`.
/// What they would do to a `POST` — repeat it as a `GET`, without its body — is not a
/// redirect of a JSON-RPC message but the loss of one, so it is refused.
///
/// Every refusal is ``MCPError/redirectRejected(destination:reason:)``, a loop and an
/// over-long chain included. None of them is a failure of the connection, and none will be
/// different on the next attempt, so none is reported as the error a caller retries.
///
/// Shared by ``HTTPSSETransport`` and ``StreamableHTTPTransport``, so there is one answer to
/// "what does a redirect do" rather than one per request site.
struct SameOriginRedirects: Sendable {

    /// How many redirects one request may follow. `AsyncHTTPClient`'s default, kept.
    static let maximumRedirects = 5

    /// The statuses treated as a redirect.
    ///
    /// The five that mean "repeat this elsewhere". `AsyncHTTPClient` also followed a `304` or
    /// a `305` that carried a `Location`; neither is an instruction to re-send, and both are
    /// now handed back like any other answer that is not a success.
    static let redirectStatuses: Set<UInt> = [301, 302, 303, 307, 308]

    /// The URL the transport was created with. Its origin is the only one followed to.
    let configured: URL

    /// The label refusals are logged under — the transport's own.
    let loggerLabel: String

    /// Sends a request, following same-origin redirects, and returns the final response.
    ///
    /// The response is returned with its body unread, so a redirected stream still streams.
    ///
    /// - Parameters:
    ///   - original: The request, without its `Authorization` header if `authorization` is
    ///     going to supply one.
    ///   - client: The client to send on. It must not follow redirects itself.
    ///   - timeout: How long the whole exchange may take to produce a response head,
    ///     redirects included.
    ///   - authorization: Asked for a current header before **each** request that is sent,
    ///     a redirected one included — the token that was valid for the first hop is not
    ///     assumed to be valid for the second. `nil` leaves the request's headers alone.
    ///   - forcingRefresh: Passed to the provider for the first request only. A redirect is
    ///     not a refusal, and forcing again on every hop would spend a rotation per hop.
    /// - Returns: The first response that is not a redirect this follows.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` — having sent nothing
    ///   further — if a redirect names another origin, would turn a `POST` or a `DELETE`
    ///   into a `GET`, loops, or is the sixth in a row;
    ///   ``MCPError/connectionFailed(reason:)`` if the request could not be made, with a
    ///   reason composed by ``TransportFailure``; or whatever the provider threw.
    func execute(
        _ original: HTTPClientRequest,
        on client: HTTPClient,
        timeout: TimeAmount,
        authorization: AuthorizationProvider?,
        forcingRefresh: Bool = false
    ) async throws -> HTTPClientResponse {
        // One deadline for the chain, as it was when the client followed: a server cannot buy
        // six timeouts with five redirects.
        let deadline = NIODeadline.now() + timeout
        var request = original
        var visited = [Self.identity(of: request)]

        // The first request and then one per redirect followed. The bound is the loop's own:
        // a server cannot keep this going by continuing to answer `3xx`.
        for hop in 0...Self.maximumRedirects {
            // Forced only for the first request. A redirect is not a refusal, and forcing
            // again on every hop would spend a rotation per hop.
            try await Self.authorize(&request, with: authorization, forcingRefresh: forcingRefresh && hop == 0)

            let response: HTTPClientResponse
            do {
                response = try await client.execute(request, deadline: deadline)
            } catch {
                throw MCPError.connectionFailed(
                    reason: TransportFailure.reason(for: error, reaching: configured))
            }

            guard Self.redirectStatuses.contains(response.status.code),
                  let location = response.headers.first(name: "Location"),
                  let current = URL(string: request.url) else {
                return response
            }
            let status = response.status.code
            let own = HTTPOrigin.description(of: configured)

            let destination: URL
            switch HTTPOrigin.resolve(location, relativeTo: current, heldTo: configured) {
            case .sameOrigin(let url):
                destination = url
            case .notAURL:
                // Nowhere to go. Handed back as the non-success it is, which is what the
                // client did with a `Location` it could not use.
                return response
            case .carriesUserinfo(let origin):
                throw refuse(
                    origin,
                    reason: "HTTP \(status) redirect carries credentials in its URL; "
                        + "expected a plain destination on \(own). Nothing was sent to it")
            case .otherOrigin(let origin):
                throw refuse(origin, reason: Self.leavingReason(status: status, from: configured, to: origin))
            }

            // On the origin, but only a redirect that can carry the request is one. A `POST`
            // repeated as a `GET` is the message thrown away, and the caller told it was sent.
            guard let next = Self.redirected(request, to: destination, status: status) else {
                throw refuse(own, reason: Self.droppingReason(status: status, method: request.method, on: own))
            }

            // Neither of these is a failure of the connection, and neither will be different
            // on the next attempt — so neither is reported as the thing a caller retries.
            let identity = Self.identity(of: next)
            guard !visited.contains(identity) else {
                throw refuse(
                    own,
                    reason: "Redirect loop: \(own) redirected the request back to a URL it had "
                        + "already redirected. The server's redirects need correcting; "
                        + "retrying will walk the same loop")
            }
            guard hop < Self.maximumRedirects else {
                throw refuse(
                    own,
                    reason: "Too many redirects: more than \(Self.maximumRedirects) redirects in a row from \(own). "
                        + "Configure the transport with the URL the chain ends at")
            }
            visited.append(identity)

            await discard(response)
            request = next
        }

        // Unreachable: the last pass above either returned or threw. Stated as the same
        // refusal rather than left for the compiler to wonder about.
        throw refuse(
            HTTPOrigin.description(of: configured),
            reason: "Too many redirects: more than \(Self.maximumRedirects) redirects in a row from "
                + HTTPOrigin.description(of: configured))
    }

    /// Why a redirect to another origin was not followed.
    ///
    /// One case is told apart, because it is the common one and the remedy is specific: an
    /// `http` URL answered with a redirect to `https` on the same host. Both reference
    /// clients follow that. This one does not — the request that drew the redirect has
    /// already crossed the network unencrypted, headers and body, and following it would let
    /// every later request do the same before being redirected again. The reason says so,
    /// and says what to configure instead.
    ///
    /// - Parameters:
    ///   - status: The redirect's status code.
    ///   - configured: The URL the transport was created with.
    ///   - origin: The destination's origin, as ``HTTPOrigin/description(of:)`` names it.
    /// - Returns: The reason, naming origins only.
    static func leavingReason(status: UInt, from configured: URL, to origin: String) -> String {
        let own = HTTPOrigin.description(of: configured)
        guard HTTPOrigin.isUpgrade(from: configured, toOrigin: origin) else {
            return "HTTP \(status) redirect leaves the configured origin \(own); nothing was sent to it"
        }
        return "HTTP \(status) redirect upgrades \(own) to https. The transport was configured with a "
            + "plaintext http URL, so the request that drew this redirect has already been sent in the clear, "
            + "with its headers and body. Configure the transport with \(origin) so that nothing is. "
            + "Nothing was sent to it"
    }

    /// Why a same-origin redirect that would change the method was not followed.
    ///
    /// - Parameters:
    ///   - status: The redirect's status code.
    ///   - method: The method of the request that was redirected.
    ///   - origin: The configured origin.
    /// - Returns: The reason, which names the statuses that would have worked.
    static func droppingReason(status: UInt, method: HTTPMethod, on origin: String) -> String {
        "HTTP \(status) from \(origin) answered a \(method.rawValue) with a redirect that cannot carry it: "
            + "following a \(status) repeats the request as a GET, without its body, so the JSON-RPC message "
            + "would be dropped. 307 and 308 are the statuses that redirect a \(method.rawValue) as it was sent. "
            + "Nothing further was sent"
    }

    /// Records a refusal and makes the error for it.
    ///
    /// Logged here rather than by each caller, because two of the callers are background
    /// streams with nobody awaiting them: without this line a refused redirect of the server
    /// stream would end it in silence.
    private func refuse(_ origin: String, reason: String) -> MCPError {
        let logger = Logger(label: loggerLabel)
        // logging: swift-log has no privacy annotations; origins only — no path, query, userinfo or header
        logger.error("Refused a redirect to \(origin): \(reason)")
        return MCPError.redirectRejected(destination: origin, reason: reason)
    }

    /// Puts a current token on a request, if there is a provider to ask.
    ///
    /// Applied over whatever the request already carries, so a live session wins over a token
    /// pasted into configuration — both present means the pasted one is the leftover.
    ///
    /// - Throws: Whatever the provider threw. A provider that fails **fails the request**:
    ///   continuing unauthenticated reaches the server as a `401`, which reads as a credential
    ///   problem at the far end rather than a local one.
    static func authorize(
        _ request: inout HTTPClientRequest,
        with provider: AuthorizationProvider?,
        forcingRefresh: Bool
    ) async throws {
        guard let provider else { return }
        if let header = try await provider(forcingRefresh) {
            request.headers.replaceOrAdd(name: "Authorization", value: header)
        } else {
            // `nil` means not signed in, which is a request with no header — not one carrying
            // `Bearer` and nothing after it.
            request.headers.remove(name: "Authorization")
        }
    }

    /// The request a redirect asks for, if the redirect can carry the request at all.
    ///
    /// `307` and `308` repeat a request as it was sent, and so does any redirect of a `GET`
    /// or a `HEAD`. The Fetch standard — and `AsyncHTTPClient`, which followed it while it
    /// was doing this — has `303` turn anything else into a `GET`, and `301` and `302` turn a
    /// `POST` into one, dropping the body. For the requests these transports make that is
    /// never what was meant: the `POST` *is* the JSON-RPC message and the `DELETE` is the end
    /// of the session, and a `GET` in their place opens a stream. So those redirects are not
    /// rewritten; they are refused, which is what both reference clients do.
    ///
    /// Nothing is removed from a request that is repeated — the destination is the same
    /// origin, so there is nobody new to keep it from.
    ///
    /// - Parameters:
    ///   - request: The request that was redirected.
    ///   - destination: Where to, already checked to be on the configured origin.
    ///   - status: The redirect's status code.
    /// - Returns: The request to send next, or `nil` if following would change its method.
    static func redirected(
        _ request: HTTPClientRequest,
        to destination: URL,
        status: UInt
    ) -> HTTPClientRequest? {
        let becomesGET: Bool
        switch status {
        case 303: becomesGET = request.method != .HEAD && request.method != .GET
        case 301, 302: becomesGET = request.method == .POST
        default: becomesGET = false
        }
        guard !becomesGET else { return nil }

        var next = request
        next.url = destination.absoluteString
        return next
    }

    /// What makes two requests in a chain the same request: the method and the URL.
    private static func identity(of request: HTTPClientRequest) -> String {
        "\(request.method.rawValue) \(request.url)"
    }

    /// Reads off a redirect's body so its connection can be reused.
    ///
    /// A failure here costs a connection and nothing else, so it is noted and not thrown.
    private func discard(_ response: HTTPClientResponse) async {
        do {
            _ = try await response.body.collect(upTo: 4 * 1024)
        } catch {
            let logger = Logger(label: loggerLabel)
            // logging: why a redirect's connection was not reused — the failure's kind and the configured origin
            logger.debug("a redirect response's body was not drained: \(TransportFailure.reason(for: error, reaching: configured))")
        }
    }
}
