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

        /// An SSE response that is cut off mid-stream, as a dropped connection would be.
        ///
        /// The payload is delivered and then the connection is closed without the chunked
        /// terminator, so the client sees a failure rather than a clean end. That distinction
        /// is what a resumable transport has to act on.
        let abortsAfter: (event: String, id: String)?

        init(status: HTTPResponseStatus, body: String,
             abortsAfter: (event: String, id: String)? = nil) {
            self.status = status
            self.body = body
            self.abortsAfter = abortsAfter
        }

        static func ok(_ body: String) -> Reply { Reply(status: .ok, body: body) }
        static func unauthorized() -> Reply {
            Reply(status: .unauthorized, body: #"{"error":"invalid_token"}"#)
        }

        /// Streams one event with an id, then drops the connection.
        static func droppedAfter(_ event: String, id: String) -> Reply {
            Reply(status: .ok, body: "", abortsAfter: (event, id))
        }
    }

    /// How the server answers a `GET` — the client-initiated server stream.
    struct ServerStream: Sendable {
        /// The status to answer with. `.methodNotAllowed` says "no such channel here".
        let status: HTTPResponseStatus
        /// SSE payloads to emit before closing the stream.
        let events: [String]
        /// An `id:` for the first event, so resumption can be checked.
        let firstID: String?

        static func serving(_ events: [String], firstID: String? = nil) -> ServerStream {
            ServerStream(status: .ok, events: events, firstID: firstID)
        }

        static let unsupported = ServerStream(
            status: .methodNotAllowed, events: [], firstID: nil)
    }

    /// One request as it arrived.
    struct Received: Sendable {
        let authorization: String?
        let sessionId: String?
        let protocolVersion: String?
        let lastEventID: String?
        /// The `Mcp-Method` header, mirrored from the body by a 2026-07-28 client.
        let method: String?
        /// The `Mcp-Name` header, still encoded as it arrived.
        let name: String?
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
    static func start(
        replies: [Reply],
        serverStream: ServerStream? = nil
    ) async throws -> StubHTTPServer {
        let recorder = Recorder(replies: replies, serverStream: serverStream)
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

    /// Every POST received, in arrival order.
    var received: [Received] { recorder.received }

    /// Every GET received — the server-stream opens, including reconnects.
    var serverStreamOpens: [Received] { recorder.serverStreamOpens }

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
    private var opens: [StubHTTPServer.Received] = []

    /// How to answer a GET, if this server offers a server stream at all.
    let serverStream: StubHTTPServer.ServerStream?

    init(replies: [StubHTTPServer.Reply], serverStream: StubHTTPServer.ServerStream?) {
        self.replies = replies
        self.serverStream = serverStream
    }

    var received: [StubHTTPServer.Received] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var serverStreamOpens: [StubHTTPServer.Received] {
        lock.lock()
        defer { lock.unlock() }
        return opens
    }

    func recordOpen(_ request: StubHTTPServer.Received) {
        lock.lock()
        defer { lock.unlock() }
        opens.append(request)
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
            // A GET is the client opening the server stream, which is its own concern and
            // its own record.
            if head.method == .GET {
                recorder.recordOpen(received(from: head))
                respondToServerStream(context: context)
                self.head = nil
                return
            }
            // `disconnect()` sends a DELETE to end the session, which is teardown rather than
            // anything under test, and recording it would make every count assertion depend
            // on when a test happened to tear down.
            guard head.method == .POST else {
                respond(context: context, reply: .ok("{}"))
                self.head = nil
                return
            }
            recorder.record(received(from: head))
            respond(context: context, reply: recorder.nextReply())
            self.head = nil
        }
    }

    /// The record of one request as it arrived.
    private func received(from head: HTTPRequestHead) -> StubHTTPServer.Received {
        StubHTTPServer.Received(
            authorization: head.headers.first(name: "Authorization"),
            sessionId: head.headers.first(name: "Mcp-Session-Id"),
            protocolVersion: head.headers.first(name: "MCP-Protocol-Version"),
            lastEventID: head.headers.first(name: "Last-Event-ID"),
            method: head.headers.first(name: "Mcp-Method"),
            name: head.headers.first(name: "Mcp-Name"),
            body: body)
    }

    /// Answers a GET: either an SSE stream of scripted events, or a refusal.
    private func respondToServerStream(context: ChannelHandlerContext) {
        guard let stream = recorder.serverStream, stream.status == .ok else {
            // No server stream here. A conformant client treats this as "no such channel"
            // rather than as a failure.
            let status = recorder.serverStream?.status ?? .methodNotAllowed
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            // This handler closes the connection after every response. Without saying so, a
            // client keeping it alive reuses a socket the server is tearing down — which
            // surfaces as a dropped request only once a GET runs concurrently with POSTs.
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                bound.value.close(promise: nil)
            }
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        for (index, event) in stream.events.enumerated() {
            var buffer = context.channel.allocator.buffer(capacity: event.utf8.count + 32)
            if index == 0, let firstID = stream.firstID {
                buffer.writeString("id: \(firstID)\n")
            }
            buffer.writeString("data: \(event)\n\n")
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        // Closed after the scripted events, so a reconnect can be observed.
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            bound.value.close(promise: nil)
        }
    }

    private func respond(context: ChannelHandlerContext, reply: StubHTTPServer.Reply) {
        // A stream the server cuts off: SSE head, one event, then the connection goes away
        // without a terminator. The client must see this as a failure, not a clean end.
        if let abort = reply.abortsAfter {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/event-stream")
            headers.add(name: "Cache-Control", value: "no-cache")
            headers.add(name: "Mcp-Session-Id", value: "stub-session")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)

            var buffer = context.channel.allocator.buffer(capacity: abort.event.utf8.count + 32)
            buffer.writeString("id: \(abort.id)\ndata: \(abort.event)\n\n")
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { _ in
                // No `.end`, so the response is truncated rather than finished.
                bound.value.close(mode: .all, promise: nil)
            }
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(reply.body.utf8.count))
        headers.add(name: "Connection", value: "close")
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
