import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// A legacy HTTP+SSE server: a `GET` that streams, and a `POST` endpoint it names.
///
/// Enough of the shape to exercise the transport's two request paths — the stream it opens on
/// `connect()`, and the messages it posts afterwards — and to record what each one carried.
/// Recording is the point: the defect being fixed is a header the transport *believes* it is
/// sending, which is exactly what an internal check would confirm and a server would not.
actor SSEStubServer {

    private var channel: Channel?
    private let recorder: SSERecorder

    private init(recorder: SSERecorder) {
        self.recorder = recorder
    }

    /// Starts the server.
    ///
    /// - Parameter replies: How to answer each POST, in order. The last repeats.
    static func start(replies: [StubHTTPServer.Reply]) async throws -> SSEStubServer {
        let recorder = SSERecorder(replies: replies)
        let server = SSEStubServer(recorder: recorder)

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SSEStubHandler(recorder: recorder))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        await server.adopt(channel)
        return server
    }

    private func adopt(_ channel: Channel) {
        self.channel = channel
    }

    /// The SSE endpoint to point a transport at.
    var url: URL {
        get throws {
            guard let port = channel?.localAddress?.port else { throw StubServerError.notListening }
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = port
            components.path = "/sse"
            guard let url = components.url else { throw StubServerError.notListening }
            return url
        }
    }

    /// Every POST received.
    var received: [StubHTTPServer.Received] { recorder.posts }

    /// Every `GET` that opened the stream, including reconnects.
    var streamOpens: [StubHTTPServer.Received] { recorder.opens }

    /// Stops listening.
    func stop() async {
        // silent: a channel already closed is the state this method wants
        try? await channel?.close().get()
        channel = nil
    }
}

/// The script and the record.
// Justification: every stored property is private and reached only under `lock`.
private final class SSERecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var replies: [StubHTTPServer.Reply]
    private var postStorage: [StubHTTPServer.Received] = []
    private var openStorage: [StubHTTPServer.Received] = []

    init(replies: [StubHTTPServer.Reply]) {
        self.replies = replies
    }

    var posts: [StubHTTPServer.Received] {
        lock.lock(); defer { lock.unlock() }
        return postStorage
    }

    var opens: [StubHTTPServer.Received] {
        lock.lock(); defer { lock.unlock() }
        return openStorage
    }

    func recordPost(_ request: StubHTTPServer.Received) {
        lock.lock(); defer { lock.unlock() }
        postStorage.append(request)
    }

    func recordOpen(_ request: StubHTTPServer.Received) {
        lock.lock(); defer { lock.unlock() }
        openStorage.append(request)
    }

    func nextReply() -> StubHTTPServer.Reply {
        lock.lock(); defer { lock.unlock() }
        guard let first = replies.first else { return .ok("{}") }
        if replies.count > 1 { replies.removeFirst() }
        return first
    }
}

/// Streams on `GET`, answers scripted replies on `POST`.
// Justification: EventLoop-confined by NIO; its one stored property is an immutable `let`.
private final class SSEStubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorder: SSERecorder
    private var head: HTTPRequestHead?
    private var body = ""

    init(recorder: SSERecorder) {
        self.recorder = recorder
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
            let record = StubHTTPServer.Received(
                authorization: head.headers.first(name: "Authorization"),
                sessionId: head.headers.first(name: "Mcp-Session-Id"),
                protocolVersion: head.headers.first(name: "MCP-Protocol-Version"),
                lastEventID: head.headers.first(name: "Last-Event-ID"),
                method: head.headers.first(name: "Mcp-Method"),
                name: head.headers.first(name: "Mcp-Name"),
                body: body)

            if head.method == .GET {
                recorder.recordOpen(record)
                openStream(context: context)
            } else {
                recorder.recordPost(record)
                respond(context: context, reply: recorder.nextReply())
            }
        }
    }

    /// Answers the `GET` with an SSE stream that names the POST endpoint and stays open.
    private func openStream(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        // The transport learns where to POST from this event, and waits for it before
        // `connect()` returns.
        var buffer = context.channel.allocator.buffer(capacity: 64)
        buffer.writeString("event: endpoint\ndata: /messages\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        // Left open: this is the long-lived stream, and closing it would start a reconnect.
    }

    private func respond(context: ChannelHandlerContext, reply: StubHTTPServer.Reply) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(reply.body.utf8.count))
        // This handler closes after responding; saying so keeps a client from reusing a
        // socket that is about to go away.
        headers.add(name: "Connection", value: "close")

        let responseHead = HTTPResponseHead(version: .http1_1, status: reply.status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: reply.body.utf8.count)
        buffer.writeString(reply.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            bound.value.close(promise: nil)
        }
    }
}
