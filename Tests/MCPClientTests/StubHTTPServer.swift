import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// An HTTP server on loopback that answers from a script and records what it was asked.
///
/// The behaviour under test here is wire behaviour — which `Authorization` header a request
/// actually carried, and what the client did after the server refused one. Neither is visible
/// from inside the transport: a test that inspected `currentHeaders` would assert what the
/// transport *believes* it will send, which is exactly the belief that was wrong for as long
/// as `updateAuthorization(_:)` had no caller.
///
/// Binds **127.0.0.1** on a kernel-assigned port, for the same reasons
/// `LoopbackRedirectListener` does: nothing off this machine can reach it, and a fixed port
/// would collide with a parallel test.
actor StubHTTPServer {

    /// What the server should answer with, in order. The last reply repeats once the script
    /// is exhausted, so a test scripts only the responses whose order it cares about.
    struct Reply: Sendable {
        let status: HTTPResponseStatus
        let body: String

        static func ok(_ body: String) -> Reply { Reply(status: .ok, body: body) }
        static func unauthorized() -> Reply {
            Reply(status: .unauthorized, body: #"{"error":"invalid_token"}"#)
        }
    }

    /// One request as it arrived.
    struct Received: Sendable {
        let authorization: String?
        let sessionId: String?
        let body: String
    }

    private var channel: Channel?
    private let recorder: Recorder

    private init(recorder: Recorder) {
        self.recorder = recorder
    }

    /// Starts a server answering with `replies`.
    ///
    /// - Parameter replies: The scripted responses, in order.
    /// - Returns: The running server.
    static func start(replies: [Reply]) async throws -> StubHTTPServer {
        let recorder = Recorder(replies: replies)
        let server = StubHTTPServer(recorder: recorder)

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StubHandler(recorder: recorder))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        await server.adopt(channel)
        return server
    }

    private func adopt(_ channel: Channel) {
        self.channel = channel
    }

    /// Where to point a transport.
    var url: URL {
        get throws {
            guard let port = channel?.localAddress?.port else {
                throw StubServerError.notListening
            }
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = port
            components.path = "/mcp"
            guard let url = components.url else { throw StubServerError.notListening }
            return url
        }
    }

    /// Every request received, in arrival order.
    var received: [Received] { recorder.received }

    /// Stops listening.
    func stop() async {
        // silent: a channel already closed is the state this method wants
        try? await channel?.close().get()
        channel = nil
    }
}

/// Why the stub server could not be used.
enum StubServerError: Error {
    case notListening
}

/// The script and the record, shared between the event loop and the test.
///
/// NIO runs a channel's handlers on its event loop while the test reads from a task, so this
/// is genuinely concurrent and takes a lock rather than relying on confinement.
// Justification: every stored property is private and reached only under `lock`.
private final class Recorder: @unchecked Sendable {

    private let lock = NSLock()
    private var replies: [StubHTTPServer.Reply]
    private var storage: [StubHTTPServer.Received] = []

    init(replies: [StubHTTPServer.Reply]) {
        self.replies = replies
    }

    var received: [StubHTTPServer.Received] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ request: StubHTTPServer.Received) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    /// The next scripted reply, repeating the last one once the script runs out.
    func nextReply() -> StubHTTPServer.Reply {
        lock.lock()
        defer { lock.unlock() }
        guard let first = replies.first else { return .ok("{}") }
        if replies.count > 1 { replies.removeFirst() }
        return first
    }
}

/// Records each request and answers from the script.
// Justification: EventLoop-confined by NIO; its one stored property is an immutable `let`.
private final class StubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorder: Recorder
    private var head: HTTPRequestHead?
    private var body = ""

    init(recorder: Recorder) {
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
            // Only the POSTs. `disconnect()` sends a DELETE to end the session, which is
            // teardown rather than anything under test here, and recording it would make
            // every count assertion depend on when a test happened to tear down.
            guard head.method == .POST else {
                respond(context: context, reply: .ok("{}"))
                self.head = nil
                return
            }
            recorder.record(StubHTTPServer.Received(
                authorization: head.headers.first(name: "Authorization"),
                sessionId: head.headers.first(name: "Mcp-Session-Id"),
                body: body))
            respond(context: context, reply: recorder.nextReply())
            self.head = nil
        }
    }

    private func respond(context: ChannelHandlerContext, reply: StubHTTPServer.Reply) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(reply.body.utf8.count))
        // A session id the client is expected to carry on every later request, so a test can
        // check that replacing a token did not cost the session the server is tracking.
        headers.add(name: "Mcp-Session-Id", value: "stub-session")

        let responseHead = HTTPResponseHead(version: .http1_1, status: reply.status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: reply.body.utf8.count)
        buffer.writeString(reply.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
