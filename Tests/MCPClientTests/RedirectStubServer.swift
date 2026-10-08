import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// A loopback server that can answer any request with a redirect, and records every request
/// whole.
///
/// The redirect tests ask one question of the *second* of two servers: what arrived? The
/// other stubs record the handful of headers their own tests care about, which is not enough
/// to answer it — the header that should not have travelled is, by construction, one nobody
/// thought to record. This one keeps the method, the request target, every header and the
/// body.
///
/// It speaks enough of both HTTP transports to complete a session when it is not redirecting:
/// a `GET` is answered with an event stream that stays open, a `POST` with a JSON-RPC result
/// (or a stream that is cut off, for resumption), a `DELETE` with `200`.
actor RedirectStubServer {

    /// Which transport's server this is, which decides what its `GET` stream says.
    enum Kind: Sendable {
        /// Legacy HTTP+SSE: the stream opens with an `endpoint` event.
        case legacySSE
        /// Streamable HTTP: the stream carries server-initiated messages, with event ids.
        case streamable
    }

    /// One request to redirect instead of answering.
    struct Redirect: Sendable {
        /// The method to match, or `nil` for any.
        let method: HTTPMethod?
        /// The path to match, without its query, or `nil` for any.
        let path: String?
        /// The redirect status to answer with.
        let status: HTTPResponseStatus
        /// The `Location`, as it goes on the wire. `{self}` is replaced with this server's own
        /// origin, which a test cannot know before the kernel has assigned the port, and
        /// `{configured}` with whatever ``RedirectStubServer/pointBack(to:)`` was given.
        let location: String
        /// How many matching requests to answer normally first.
        let skipping: Int

        init(
            method: HTTPMethod? = nil,
            path: String? = nil,
            status: HTTPResponseStatus,
            location: String,
            skipping: Int = 0
        ) {
            self.method = method
            self.path = path
            self.status = status
            self.location = location
            self.skipping = skipping
        }
    }

    /// How a `POST` that is not redirected is answered.
    enum PostReply: Sendable {
        /// `200` with a JSON-RPC result.
        case json
        /// An event stream that delivers one event carrying this id and is then cut off, so
        /// the client has something to resume from.
        case droppedStream(eventID: String)
        /// A bare status with an empty JSON body.
        case status(HTTPResponseStatus)
    }

    /// One request, as it arrived.
    struct Request: Sendable {
        let method: String
        /// The request target: path and query.
        let target: String
        /// Every header, by lowercased name.
        let headers: [String: String]
        let body: String

        /// The path of the request target, without its query.
        var path: String {
            String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }

        /// A header's value, whatever case it was sent in.
        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    private var channel: Channel?
    private let script: RedirectScript
    private let servesTLS: Bool
    private let kind: Kind

    private init(script: RedirectScript, servesTLS: Bool, kind: Kind) {
        self.script = script
        self.servesTLS = servesTLS
        self.kind = kind
    }

    /// Starts a server.
    ///
    /// - Parameters:
    ///   - kind: Which transport's server to imitate.
    ///   - redirects: The requests to redirect. The first rule that matches a request, and
    ///     has used up its `skipping`, answers it.
    ///   - postReply: How a `POST` that is not redirected is answered.
    ///   - endpoint: The `data` of a legacy stream's `endpoint` event.
    ///   - session: The `Mcp-Session-Id` a Streamable HTTP response assigns.
    ///   - tls: The identity to present. Supplying one makes this an HTTPS server.
    /// - Returns: The running server.
    static func start(
        kind: Kind,
        redirects: [Redirect] = [],
        postReply: PostReply = .json,
        endpoint: String = "/messages",
        session: String = "stub-session",
        tls: NIOSSLContext? = nil
    ) async throws -> RedirectStubServer {
        let script = RedirectScript(
            kind: kind, redirects: redirects, postReply: postReply,
            endpoint: endpoint, session: session, scheme: tls == nil ? "http" : "https")
        let server = RedirectStubServer(script: script, servesTLS: tls != nil, kind: kind)

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(RedirectStubHandler(script: script))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        await server.adopt(channel)
        return server
    }

    private func adopt(_ channel: Channel) {
        self.channel = channel
    }

    /// The port the server is listening on.
    var port: Int {
        get throws {
            guard let port = channel?.localAddress?.port else { throw StubServerError.notListening }
            return port
        }
    }

    /// The URL to point a transport at: `/sse` for a legacy server, `/mcp` otherwise.
    var url: URL {
        get throws {
            try url(path: kind == .legacySSE ? "/sse" : "/mcp")
        }
    }

    /// A URL on this server.
    ///
    /// - Parameters:
    ///   - path: The path.
    ///   - query: An already percent-encoded query, if any.
    func url(path: String, query: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = servesTLS ? "https" : "http"
        components.host = "127.0.0.1"
        components.port = try port
        components.path = path
        components.percentEncodedQuery = query
        guard let url = components.url else { throw StubServerError.notListening }
        return url
    }

    /// Every request received, in arrival order.
    var requests: [Request] { script.requests }

    /// Says what `{configured}` stands for in this server's `Location` values.
    ///
    /// Two servers that redirect to each other cannot both be started knowing the other's
    /// port. The one started first is told afterwards.
    ///
    /// - Parameter origin: The other server's origin, as `scheme://host:port`.
    func pointBack(to origin: String) {
        script.pointBack(to: origin)
    }

    /// Stops listening.
    func stop() {
        guard let channel else { return }
        self.channel = nil
        // Not awaited: a listener that is already closed is the state this wants, and nothing
        // a test asserts depends on the port having been released.
        channel.close(promise: nil)
    }
}

/// The script and the record, shared between the event loop and the test.
// Justification: every mutable stored property is private and reached only under `lock`.
private final class RedirectScript: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [RedirectStubServer.Request] = []
    private var matches: [Int]
    private var configuredOrigin = ""

    let kind: RedirectStubServer.Kind
    let redirects: [RedirectStubServer.Redirect]
    let postReply: RedirectStubServer.PostReply
    let endpoint: String
    let session: String
    let scheme: String

    init(
        kind: RedirectStubServer.Kind,
        redirects: [RedirectStubServer.Redirect],
        postReply: RedirectStubServer.PostReply,
        endpoint: String,
        session: String,
        scheme: String
    ) {
        self.kind = kind
        self.redirects = redirects
        self.postReply = postReply
        self.endpoint = endpoint
        self.session = session
        self.scheme = scheme
        self.matches = Array(repeating: 0, count: redirects.count)
    }

    var requests: [RedirectStubServer.Request] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func pointBack(to origin: String) {
        lock.lock()
        defer { lock.unlock() }
        configuredOrigin = origin
    }

    /// What `{configured}` stands for.
    var pointsBackTo: String {
        lock.lock()
        defer { lock.unlock() }
        return configuredOrigin
    }

    /// Records a request and says whether it is to be redirected.
    func record(
        _ request: RedirectStubServer.Request,
        method: HTTPMethod
    ) -> RedirectStubServer.Redirect? {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
        for (index, rule) in redirects.enumerated() {
            if let wanted = rule.method, wanted != method { continue }
            if let wanted = rule.path, wanted != request.path { continue }
            matches[index] += 1
            if matches[index] > rule.skipping { return rule }
            // A rule still skipping has claimed the request: it is answered normally.
            return nil
        }
        return nil
    }
}

/// Records each request, then redirects it or answers it.
// Justification: EventLoop-confined by NIO; its mutable state is touched only on that loop.
private final class RedirectStubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let script: RedirectScript
    private var head: HTTPRequestHead?
    private var body = ""

    init(script: RedirectScript) {
        self.script = script
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = ""
        case .body(var buffer):
            body += buffer.readString(length: buffer.readableBytes) ?? ""
        case .end:
            guard let head else { return }
            self.head = nil

            let request = RedirectStubServer.Request(
                method: head.method.rawValue,
                target: head.uri,
                headers: Dictionary(
                    head.headers.map { ($0.name.lowercased(), $0.value) },
                    uniquingKeysWith: { first, _ in first }),
                body: body)

            if let rule = script.record(request, method: head.method) {
                redirect(context: context, rule: rule)
                return
            }
            switch head.method {
            case .GET where head.headers.first(name: "Accept")?.contains("text/event-stream") == true:
                openStream(context: context)
            case .GET:
                // A `GET` that did not ask for a stream is a `POST` some redirect turned into
                // one. Answered and closed, so the request that became it can finish.
                finish(context: context, status: .ok, contentType: "application/json", body: "{}")
            case .POST:
                answerPost(context: context)
            default:
                finish(context: context, status: .ok, contentType: "application/json", body: "{}")
            }
        }
    }

    /// This server's own origin, for `{self}` in a `Location`.
    private func ownOrigin(_ context: ChannelHandlerContext) -> String {
        "\(script.scheme)://127.0.0.1:\(context.channel.localAddress?.port ?? 0)"
    }

    private func redirect(context: ChannelHandlerContext, rule: RedirectStubServer.Redirect) {
        var headers = HTTPHeaders()
        headers.add(
            name: "Location",
            value: rule.location
                .replacingOccurrences(of: "{self}", with: ownOrigin(context))
                .replacingOccurrences(of: "{configured}", with: script.pointsBackTo))
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: rule.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        endAndClose(context)
    }

    /// Answers a `GET` with an event stream that stays open.
    private func openStream(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: 128)
        switch script.kind {
        case .legacySSE:
            buffer.writeString("event: endpoint\ndata: \(script.endpoint)\n\n")
        case .streamable:
            buffer.writeString("id: stream-1\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/stub\"}\n\n")
        }
        // Left open: a stream that closed would start a reconnect, which is a second request
        // the tests would then have to tell apart from the one they are counting.
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func answerPost(context: ChannelHandlerContext) {
        switch script.postReply {
        case .json:
            finish(
                context: context, status: .ok, contentType: "application/json",
                body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        case .status(let status):
            finish(context: context, status: status, contentType: "application/json", body: "{}")
        case .droppedStream(let eventID):
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/event-stream")
            headers.add(name: "Cache-Control", value: "no-cache")
            headers.add(name: "Mcp-Session-Id", value: script.session)
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)

            var buffer = context.channel.allocator.buffer(capacity: 96)
            buffer.writeString("id: \(eventID)\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/stub\"}\n\n")
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { _ in
                // No `.end`: the response is truncated rather than finished, which is what a
                // client has to see to treat it as a drop.
                bound.value.close(mode: .all, promise: nil)
            }
        }
    }

    private func finish(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        body: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        headers.add(name: "Connection", value: "close")
        if script.kind == .streamable {
            headers.add(name: "Mcp-Session-Id", value: script.session)
        }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        endAndClose(context)
    }

    private func endAndClose(_ context: ChannelHandlerContext) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            bound.value.close(promise: nil)
        }
    }
}
