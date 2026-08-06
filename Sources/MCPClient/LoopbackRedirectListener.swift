import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Why the loopback listener could not deliver a callback.
public enum LoopbackError: Error, Equatable, Sendable {

    /// The listener could not be started.
    case couldNotListen

    /// No callback arrived before the deadline.
    ///
    /// Expected rather than exceptional: a user who opens the authorization page and then
    /// closes the tab produces exactly this, and it must not leave a listener bound forever.
    case timedOut

    /// The request that arrived was not a readable HTTP request.
    case malformedRequest
}

/// Receives an OAuth redirect on the loopback interface.
///
/// RFC 8252 §7.3 is why this exists. A native application has no web server to redirect to,
/// and the alternatives are worse: a custom URI scheme can be claimed by any other
/// application on the machine, and an out-of-band code asks the user to copy and paste a
/// credential. A loopback redirect can only be delivered by a process on this machine.
///
/// ## What it deliberately does
///
/// It binds **127.0.0.1**, never `0.0.0.0`. Binding every interface would let anything that
/// can route here deliver a callback — which is to say, hand this client an authorization
/// code of an attacker's choosing. The `state` check would catch that, but there is no reason
/// to accept the connection at all.
///
/// It takes a **kernel-assigned port**. RFC 8252 §7.3 requires an authorization server to
/// accept any port on the loopback address for exactly this reason: a fixed port can be
/// occupied, by a second copy of this application or by something that wants the callback.
///
/// It serves **one** callback and stops. The listener exists for the width of a single
/// authorization; leaving it bound afterwards leaves something accepting authorization codes
/// long after anyone is expecting one.
///
/// ## Why NIO
///
/// `bind(host:port:)` expresses exactly what is needed — that address, a kernel-assigned port
/// — in one call and with no pointers. `NWListener` cannot: a required local endpoint needs a
/// concrete port, and an ephemeral port means not stating the endpoint at all, so it can
/// offer the address restriction or the assigned port but not both. Reaching for the C
/// sockets API instead would mean composing a `sockaddr_in` by hand, which is the same
/// capability with worse ergonomics and a pointer cast that no static checker can tell apart
/// from one that outlives its buffer.
public actor LoopbackRedirectListener {

    private let path: String
    private var channel: Channel?
    private var callback: EventLoopPromise<URL>?

    /// The process-wide event loop group.
    ///
    /// Shared rather than one group per listener: a per-listener group has to be shut down,
    /// and a shutdown that has to happen on every exit path — including the ones taken when
    /// something has already gone wrong — is a thread leak waiting for the one path that
    /// forgets. The singleton is owned by NIO and must not be shut down at all.
    private var group: EventLoopGroup { MultiThreadedEventLoopGroup.singleton }

    /// Creates a listener.
    ///
    /// - Parameter path: The redirect path to expect.
    public init(path: String = "/callback") {
        self.path = path
    }

    /// Binds a loopback port and reports the redirect URI to register with the provider.
    ///
    /// - Returns: The redirect URI, including the assigned port.
    /// - Throws: ``LoopbackError/couldNotListen``.
    public func start() async throws -> String {
        let promise = group.next().makePromise(of: URL.self)
        let expectedPath = path

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 1)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        CallbackHandler(expectedPath: expectedPath, promise: promise))
                }
            }

        // 127.0.0.1, not 0.0.0.0, and port 0 for a kernel-assigned one. The whole security
        // property and the whole RFC 8252 requirement, in a single call.
        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            promise.fail(error)
            throw LoopbackError.couldNotListen
        }

        guard let port = channel.localAddress?.port else {
            promise.fail(LoopbackError.couldNotListen)
            try? await channel.close().get() // silent: closing a channel that failed to bind
            throw LoopbackError.couldNotListen
        }

        self.channel = channel
        self.callback = promise
        return "http://127.0.0.1:\(port)\(path)"
    }

    /// Waits for the redirect and returns it.
    ///
    /// - Parameter timeout: How long to wait. A user who abandons the page in their browser
    ///   produces a timeout rather than a hang.
    /// - Returns: The full callback URL, query intact.
    /// - Throws: ``LoopbackError``.
    public func awaitCallback(timeout: Duration = .seconds(300)) async throws -> URL {
        guard let callback, let channel else { throw LoopbackError.couldNotListen }

        // The deadline is scheduled on the event loop and fulfils the same promise, so there
        // is exactly one thing to await. Racing a `Task.sleep` against the future in a task
        // group does not work: awaiting a NIO future is not cancellation-aware, so the losing
        // child never finishes and the group never returns.
        let deadline = channel.eventLoop.scheduleTask(in: Self.amount(timeout)) {
            callback.fail(LoopbackError.timedOut)
        }
        defer { deadline.cancel() }

        return try await callback.futureResult.get()
    }

    /// Converts a `Duration` to NIO's `TimeAmount`.
    static func amount(_ duration: Duration) -> TimeAmount {
        let components = duration.components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return .nanoseconds(nanoseconds)
    }

    /// Closes the listener and releases its event loop.
    ///
    /// Idempotent, and worth calling on every exit path: an abandoned authorization must not
    /// leave something bound and accepting codes.
    public func stop() async {
        // Failing the promise first means a caller still inside `awaitCallback` gets an error
        // rather than waiting out its full timeout on a socket that is already gone.
        callback?.fail(LoopbackError.couldNotListen)
        callback = nil

        // silent: a channel already closed is the state this method wants
        try? await channel?.close().get()
        channel = nil
        // The event loop group is NIO's singleton and is deliberately not shut down here.
    }
}

/// Answers HTTP requests until one is the callback.
///
/// Not `Sendable`, and it does not need to be: NIO runs every handler for a channel on that
/// channel's event loop, one at a time.
private final class CallbackHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let expectedPath: String
    private let promise: EventLoopPromise<URL>

    init(expectedPath: String, promise: EventLoopPromise<URL>) {
        self.expectedPath = expectedPath
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(let head) = unwrapInboundIn(data) else { return }

        // Only GET. An authorization redirect is a GET, and anything else would carry a body
        // this handler never reads.
        guard head.method == .GET else {
            respond(context: context, body: LoopbackRedirectListener.failurePage)
            return
        }

        guard let url = LoopbackRedirectListener.callbackURL(
            from: head.uri, port: context.localAddress?.port) else {
            respond(context: context, body: LoopbackRedirectListener.failurePage)
            return
        }

        guard url.path == expectedPath else {
            // Browsers request `/favicon.ico` unprompted. Answering it must not end the wait,
            // or the real callback arrives to a closed channel.
            respond(context: context, body: LoopbackRedirectListener.failurePage)
            return
        }

        respond(context: context, body: LoopbackRedirectListener.successPage)
        // Succeeding twice is a no-op on a promise, so a duplicated request is harmless.
        promise.succeed(url)
    }

    private func respond(context: ChannelHandlerContext, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

extension LoopbackRedirectListener {

    /// Builds the callback URL from an HTTP request target.
    ///
    /// Composed rather than parsed whole: the scheme, host and port are this listener's own,
    /// and only the path and query come from the request. The target arrives already
    /// percent-encoded, so it goes into the `percentEncoded*` properties — assigning it to
    /// `path`/`query` would encode it a second time, and a provider saying `User%20refused`
    /// would reach the caller as `User%2520refused`.
    ///
    /// - Parameters:
    ///   - target: The request target, e.g. `/callback?code=…`.
    ///   - port: The port this listener is bound to.
    /// - Returns: The URL, or `nil` if the target cannot form one.
    static func callbackURL(from target: String, port: Int?) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        let split = target.split(separator: "?", maxSplits: 1)
        components.percentEncodedPath = String(split.first ?? "")
        components.percentEncodedQuery = split.count > 1 ? String(split[1]) : nil
        return components.url
    }

    /// Shown in the browser once the code has been received.
    ///
    /// Deliberately restates nothing about the callback. This page is rendered by whatever
    /// browser the user has, and the URL that produced it — authorization code and all — is
    /// already in that browser's history without any help from here.
    static let successPage = """
    <!doctype html><meta charset="utf-8"><title>Signed in</title>
    <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center">
    <h1>Signed in</h1><p>You can close this tab and return to MCP Explorer.</p>
    """

    /// Shown when the request was not the callback.
    static let failurePage = """
    <!doctype html><meta charset="utf-8"><title>Waiting</title>
    <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center">
    <h1>Nothing to see here</h1><p>This page is waiting for a sign-in redirect.</p>
    """
}
