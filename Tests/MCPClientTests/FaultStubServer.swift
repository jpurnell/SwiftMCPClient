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
    }

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
                    try channel.pipeline.syncOperations.addHandler(FaultHandler(fault: fault))
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

/// Applies the chosen fault to one connection.
// Justification: EventLoop-confined by NIO; it holds no mutable state at all.
private final class FaultHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let fault: FaultStubServer.Fault

    init(fault: FaultStubServer.Fault) {
        self.fault = fault
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
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
