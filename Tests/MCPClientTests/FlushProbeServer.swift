import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// A server that flushes half an SSE response, waits to be told the client saw it, then
/// flushes the rest.
///
/// It answers one question: does `AsyncHTTPClient` hand a response body to its consumer **as
/// the server flushes it**, or does it accumulate and deliver at the end? Everything in the
/// Streamable HTTP compliance plan's first gap — streaming POST bodies so progress
/// notifications arrive while the work is happening — rests on the first answer being true. If
/// it is false, incremental decoding produces exactly the batched delivery it was built to
/// replace, with more machinery.
///
/// ## Why it waits for a signal rather than a delay
///
/// The obvious probe sleeps between flushes and checks arrival times. That asserts on
/// wall-clock elapsed time, which passes on an idle machine and fails on a loaded one — the
/// flakiness this project's auditors reject on sight.
///
/// Instead the ordering is made explicit: the server flushes the first event and then blocks
/// until the client tells it, over a *separate* request, that the event arrived. If chunks are
/// delivered incrementally the signal arrives first and the server records that. If the client
/// library buffers, the client cannot possibly have seen anything yet, the wait times out, and
/// the record says so. Either way the answer is an ordering, not a duration.
actor FlushProbeServer {

    private var channel: Channel?
    private let recorder: ProbeRecorder

    private init(recorder: ProbeRecorder) {
        self.recorder = recorder
    }

    /// Starts the probe server on loopback.
    static func start() async throws -> FlushProbeServer {
        let recorder = ProbeRecorder()
        let server = FlushProbeServer(recorder: recorder)

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProbeHandler(recorder: recorder))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        await server.adopt(channel)
        return server
    }

    private func adopt(_ channel: Channel) {
        self.channel = channel
    }

    /// The URL that produces a two-part SSE response.
    var probeURL: URL {
        get throws { try url(path: "/probe") }
    }

    /// The URL the client requests to say the first event arrived.
    var signalURL: URL {
        get throws { try url(path: "/signal") }
    }

    private func url(path: String) throws -> URL {
        guard let port = channel?.localAddress?.port else { throw StubServerError.notListening }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        guard let url = components.url else { throw StubServerError.notListening }
        return url
    }

    /// Whether the client's signal arrived before the second event was flushed.
    ///
    /// `true` means the client saw the first event while the response was still open, which is
    /// incremental delivery. `false` means the wait timed out — nothing could have been seen
    /// yet, so the library was holding the body.
    var signalPrecededSecondFlush: Bool { recorder.signalPrecededSecondFlush }

    /// Stops listening.
    func stop() async {
        // silent: a channel already closed is the state this method wants
        try? await channel?.close().get()
        channel = nil
    }
}

/// What the probe observed, shared between two channels' event loops and the test.
// Justification: every stored property is private and reached only under `lock`.
private final class ProbeRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var signalled = false
    private var secondFlushed = false
    private var order: Bool?
    private var release: (@Sendable () -> Void)?

    /// Records the client's signal, and releases a waiting probe response.
    func signal() {
        lock.lock()
        signalled = true
        let waiting = release
        release = nil
        lock.unlock()
        waiting?()
    }

    /// Registers what to run once the client signals, or when the wait gives up.
    func whenSignalled(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        if signalled {
            lock.unlock()
            body()
            return
        }
        release = body
        lock.unlock()
    }

    /// Called as the second event goes out, recording whether the signal beat it.
    func markSecondFlush() {
        lock.lock()
        defer { lock.unlock() }
        guard !secondFlushed else { return }
        secondFlushed = true
        order = signalled
    }

    /// Gives up waiting, so a buffering client library produces a result rather than a hang.
    func abandonWait() {
        lock.lock()
        let waiting = release
        release = nil
        lock.unlock()
        waiting?()
    }

    var signalPrecededSecondFlush: Bool {
        lock.lock()
        defer { lock.unlock() }
        return order ?? false
    }
}

/// Serves the probe response and the signal endpoint.
// Justification: EventLoop-confined by NIO; its one stored property is an immutable `let`.
private final class ProbeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// How long to wait for the client's signal before concluding it is not coming.
    ///
    /// Not an assertion — a safety valve, so a buffering client library ends the test with a
    /// finding instead of a hang.
    private static let patience = TimeAmount.seconds(3)

    private let recorder: ProbeRecorder
    private var path: String?

    init(recorder: ProbeRecorder) {
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri
        case .body:
            break
        case .end:
            guard let path else { return }
            self.path = nil
            if path.hasPrefix("/signal") {
                recorder.signal()
                respondEmpty(context: context)
            } else {
                beginProbeResponse(context: context)
            }
        }
    }

    /// Writes the first event, then holds the response open until the client says it arrived.
    private func beginProbeResponse(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        // No `Content-Length`, so NIO frames this chunked and the response can stay open.
        headers.add(name: "Cache-Control", value: "no-cache")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        write(event: "first", context: context)
        context.flush()

        // `Channel` is safe to use from any thread, unlike `ChannelHandlerContext`, so the
        // continuation below can run on whichever loop the signal request landed on.
        let channel = context.channel
        let finish: @Sendable () -> Void = { [recorder] in
            recorder.markSecondFlush()
            var buffer = channel.allocator.buffer(capacity: 32)
            buffer.writeString("data: second\n\n")
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }

        recorder.whenSignalled(finish)
        // The valve. A client that buffers never signals, and this ends the exchange so the
        // test reports a finding rather than hanging.
        context.eventLoop.scheduleTask(in: Self.patience) { [recorder] in
            recorder.abandonWait()
        }
    }

    private func write(event: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: 32)
        buffer.writeString("data: \(event)\n\n")
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func respondEmpty(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1, status: .noContent, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
        }
    }
}
