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
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if a redirect names
    ///   another origin, having sent nothing there; ``MCPError/connectionFailed(reason:)`` if
    ///   the request could not be made, the redirects loop, or there are more than
    ///   ``maximumRedirects``; or whatever the provider threw.
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
                throw MCPError.connectionFailed(reason: error.localizedDescription)
            }

            guard Self.redirectStatuses.contains(response.status.code),
                  let location = response.headers.first(name: "Location"),
                  let current = URL(string: request.url) else {
                return response
            }

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
                    reason: "HTTP \(response.status.code) redirect carries credentials in its URL; "
                        + "expected a plain destination on \(HTTPOrigin.description(of: configured)). "
                        + "Nothing was sent to it")
            case .otherOrigin(let origin):
                throw refuse(
                    origin,
                    reason: "HTTP \(response.status.code) redirect leaves the configured origin "
                        + "\(HTTPOrigin.description(of: configured)); nothing was sent to it")
            }

            let next = Self.redirected(request, to: destination, status: response.status.code)
            let identity = Self.identity(of: next)
            guard !visited.contains(identity) else {
                throw MCPError.connectionFailed(
                    reason: "Redirect loop on \(HTTPOrigin.description(of: configured))")
            }
            visited.append(identity)

            await Self.discard(response, loggerLabel: loggerLabel)
            request = next
        }

        // Every pass above either returned, threw, or was redirected once more.
        throw MCPError.connectionFailed(
            reason: "More than \(Self.maximumRedirects) redirects from "
                + HTTPOrigin.description(of: configured))
    }

    /// Records a refusal and makes the error for it.
    ///
    /// Logged here rather than by each caller, because two of the callers are background
    /// streams with nobody awaiting them: without this line a refused redirect of the server
    /// stream would end it in silence.
    private func refuse(_ origin: String, reason: String) -> MCPError {
        let logger = Logger(label: loggerLabel)
        // logging: swift-log has no privacy annotations; an origin only — no path, query, userinfo or header
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

    /// The request a redirect asks for.
    ///
    /// The method rules are `AsyncHTTPClient`'s defaults, which are the Fetch standard's:
    /// `303` turns anything but a `HEAD` into a `GET`; `301` and `302` turn a `POST` into one;
    /// `307`, `308` and every other combination repeat the request as it was. A request that
    /// becomes a `GET` loses its body and the two headers that described it. Nothing else is
    /// removed — the destination is the same origin, so there is nobody new to keep it from.
    ///
    /// - Parameters:
    ///   - request: The request that was redirected.
    ///   - destination: Where to, already checked.
    ///   - status: The redirect's status code.
    /// - Returns: The request to send next.
    static func redirected(
        _ request: HTTPClientRequest,
        to destination: URL,
        status: UInt
    ) -> HTTPClientRequest {
        let becomesGET: Bool
        switch status {
        case 303: becomesGET = request.method != .HEAD
        case 301, 302: becomesGET = request.method == .POST
        default: becomesGET = false
        }

        var next = request
        next.url = destination.absoluteString
        if becomesGET {
            next.method = .GET
            next.body = nil
            next.headers.remove(name: "Content-Length")
            next.headers.remove(name: "Content-Type")
        }
        return next
    }

    /// What makes two requests in a chain the same request: the method and the URL.
    ///
    /// The method is part of it because `POST /x` answered `303` to `/x` is not a loop — it is
    /// the ordinary way of saying "now fetch the result".
    private static func identity(of request: HTTPClientRequest) -> String {
        "\(request.method.rawValue) \(request.url)"
    }

    /// Reads off a redirect's body so its connection can be reused.
    ///
    /// A failure here costs a connection and nothing else, so it is noted and not thrown.
    private static func discard(_ response: HTTPClientResponse, loggerLabel: String) async {
        do {
            _ = try await response.body.collect(upTo: 4 * 1024)
        } catch {
            let logger = Logger(label: loggerLabel)
            // logging: why a redirect's connection was not reused; the error names no URL
            logger.debug("a redirect response's body was not drained: \(error.localizedDescription)")
        }
    }
}
