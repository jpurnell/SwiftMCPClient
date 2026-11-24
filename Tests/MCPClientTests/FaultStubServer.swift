import Foundation
import NIOCore
import NIOPosix

/// A loopback listener that accepts a connection and then misbehaves in one chosen way.
///
/// The failures a transport has to describe are the ones a well-behaved stub cannot produce:
/// a peer that says nothing, one that hangs up, and one that answers with something that is
/// not HTTP. Each is provoked here on purpose so that what the client's networking stack
/// *says* about it is observed rather than assumed.
actor FaultStubServer {

    /// What the listener does with a connection once it has it.
    enum Fault: Sendable {
        /// Accepts, reads, and never answers.
        case silent
        /// Hangs up as soon as the first bytes arrive.
        case closesOnRequest
        /// Answers with bytes that are not an HTTP response, then hangs up.
        case garbage(String)
        /// Answers by method, with bytes written exactly as given. A `GET` is answered with
        /// `get` and the connection left open, as a stream is; anything else is answered
        /// with `other` and the connection closed — which is how a body shorter than its
        /// `Content-Length` is produced, or one with no length at all.
        case byMethod(get: String, other: String)
        /// Answers with `head` and then a body that never ends: 64 KiB at a time, for as
        /// long as the peer keeps reading, up to `ceiling` bytes — a stop for the test, far
        /// beyond anything a bounded reader takes.
        case endlessBody(head: String, ceiling: Int)
    }

    /// How many body bytes an ``Fault/endlessBody(head:ceiling:)`` listener has written.
    nonisolated var bodyBytesWritten: Int { written.value }

    private let written = ByteCount()

    /// How many connections the listener has accepted.
    nonisolated var connectionsAccepted: Int { accepted.value }

    private let accepted = ByteCount()

    private var channel: Channel?

    private init() {}

    /// Starts a listener.
    ///
    /// - Parameter fault: How every connection is treated.
    /// - Returns: The running listener.
    static func start(_ fault: Fault) async throws -> FaultStubServer {
        let server = FaultStubServer()
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        FaultHandler(fault: fault, written: server.written, accepted: server.accepted))
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        await server.adopt(channel)
        return server
    }

    private func adopt(_ channel: Channel) {
        self.channel = channel
    }

    /// The port the listener is on.
    var port: Int {
        get throws {
            guard let port = channel?.localAddress?.port else { throw StubServerError.notListening }
            return port
        }
    }

    /// A URL on this listener.
    ///
    /// - Parameters:
    ///   - scheme: The scheme to give it.
    ///   - path: The path.
    ///   - query: An already percent-encoded query, if any.
    func url(scheme: String = "http", path: String, query: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "127.0.0.1"
        components.port = try port
        components.path = path
        components.percentEncodedQuery = query
        guard let url = components.url else { throw StubServerError.notListening }
        return url
    }

    /// Stops listening.
    func stop() {
        guard let channel else { return }
        self.channel = nil
        channel.close(promise: nil)
    }

    /// Stops listening and returns once the port is closed, so that a connection to it is
    /// refused rather than racing the close.
    func stopAndWait() async throws {
        guard let channel else { return }
        self.channel = nil
        try await channel.close().get()
    }
}

/// A count shared between a listener's connections and the test reading it.
// Justification: the only mutable state is `count`, private and reached only under `lock`.
final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The count so far.
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Adds to the count.
    func add(_ bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        count += bytes
    }
}

/// Applies the chosen fault to one connection.
// Justification: EventLoop-confined by NIO; its one mutable flag is read and written only on the channel's event loop.
private final class FaultHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let fault: FaultStubServer.Fault
    private let written: ByteCount

    private let accepted: ByteCount

    init(fault: FaultStubServer.Fault, written: ByteCount, accepted: ByteCount) {
        self.fault = fault
        self.written = written
        self.accepted = accepted
    }

    func channelActive(context: ChannelHandlerContext) {
        accepted.add(1)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch fault {
        case .silent:
            return
        case .closesOnRequest:
            context.close(promise: nil)
        case .garbage(let text):
            var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                bound.value.close(promise: nil)
            }
        case .byMethod(let get, let other):
            // Only the read that begins a request is answered; a body arriving in a second
            // read is not a second request.
            let request = unwrapInboundIn(data)
            let start = request.getString(at: request.readerIndex, length: min(8, request.readableBytes)) ?? ""
            let isGet = start.hasPrefix("GET ")
            guard isGet || start.hasPrefix("POST ") || start.hasPrefix("DELETE ") else { return }
            let text = isGet ? get : other
            var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                guard !isGet else { return }
                // Half-closed, not closed: the request's body may still be on its way, and
                // data arriving at a closed socket is answered with a reset, which can take
                // the response with it before the client has read it. The FIN still ends a
                // body that has no length, and still cuts one short of its `Content-Length`.
                bound.value.close(mode: .output, promise: nil)
                // The client closes its side on seeing the end; this is for one that does not.
                bound.value.eventLoop.scheduleTask(in: .seconds(2)) {
                    bound.value.close(promise: nil)
                }
            }
        case .endlessBody(let head, let ceiling):
            guard !started else { return }
            started = true
            var buffer = context.channel.allocator.buffer(capacity: head.utf8.count)
            buffer.writeString(head)
            context.write(wrapOutboundOut(buffer), promise: nil)
            pour(context: context, ceiling: ceiling)
        }
    }

    /// Whether an endless body has begun on this connection.
    private var started = false

    /// Writes the next 64 KiB, and the one after when that has gone out.
    private func pour(context: ChannelHandlerContext, ceiling: Int) {
        guard written.value < ceiling, context.channel.isActive else {
            context.close(promise: nil)
            return
        }
        let chunk = 64 * 1024
        var buffer = context.channel.allocator.buffer(capacity: chunk)
        buffer.writeRepeatingByte(UInt8(ascii: "a"), count: chunk)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let counter = written
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { result in
            guard case .success = result else { return }
            counter.add(chunk)
            handler.value.pour(context: bound.value, ceiling: ceiling)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
