import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// A loopback WebSocket server that completes the upgrade and answers the client's first
/// message the way a test chose.
///
/// `WebSocketTransport` was never exercised against a server that finished an upgrade and
/// then spoke: the upgrade tests refuse, redirect or hang up. A transport that cannot get a
/// message off a working connection passed all of them. This is the other half — a real
/// RFC 6455 peer, so that what the client does with frames is observed rather than assumed.
///
/// It replies only after the client has sent something, as a request/response protocol does:
/// a frame written the instant the upgrade completes can arrive before the client has
/// registered a handler for it.
actor WebSocketStubServer {

    /// What the server writes back to the client's first message.
    enum Reply: Sendable {
        /// One text frame carrying a JSON-RPC response of `bytes` bytes.
        case single(bytes: Int)
        /// One message of `total` bytes, sent as non-final text and continuation frames of
        /// `fragment` bytes each.
        case fragmented(total: Int, fragment: Int)
    }

    private var channel: Channel?

    private init() {}

    /// Starts a listener.
    ///
    /// - Parameter reply: What every connection is answered with.
    /// - Returns: The running listener.
    static func start(reply: Reply) async throws -> WebSocketStubServer {
        let server = WebSocketStubServer()
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                WebSocketReplyHandler(reply: reply))
                        }
                    })
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        await server.adopt(channel)
        return server
    }

    private func adopt(_ channel: Channel) {
        self.channel = channel
    }

    /// A `ws://` URL on this listener.
    func url() throws -> URL {
        guard let port = channel?.localAddress?.port else { throw StubServerError.notListening }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/"
        guard let url = components.url else { throw StubServerError.notListening }
        return url
    }

    /// Stops listening.
    func stop() {
        guard let channel else { return }
        self.channel = nil
        channel.close(promise: nil)
    }

    /// A JSON-RPC response of exactly `bytes` bytes, so a test can name a size on the wire.
    static func message(bytes: Int) -> String {
        let prefix = #"{"jsonrpc":"2.0","id":1,"result":{"pad":""#
        let suffix = #""}}"#
        let padding = max(0, bytes - prefix.utf8.count - suffix.utf8.count)
        return prefix + String(repeating: "a", count: padding) + suffix
    }
}

/// Answers the first data frame it is sent, and the close frame that ends the conversation.
// Justification: WebSocketReplyHandler is confined to its channel's event loop by NIO, and its one mutable flag, `replied`, is read and written only from `channelRead` on that loop.
private final class WebSocketReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let reply: WebSocketStubServer.Reply
    private var replied = false

    init(reply: WebSocketStubServer.Reply) {
        self.reply = reply
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            guard !replied else { return }
            replied = true
            write(reply, to: context)
        case .ping:
            var pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            pong.maskKey = nil
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                bound.value.close(promise: nil)
            }
        default:
            break
        }
    }

    private func write(_ reply: WebSocketStubServer.Reply, to context: ChannelHandlerContext) {
        switch reply {
        case .single(let bytes):
            let text = WebSocketStubServer.message(bytes: bytes)
            var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
        case .fragmented(let total, let fragment):
            let bytes = Array(WebSocketStubServer.message(bytes: total).utf8)
            let size = max(1, fragment)
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + size)
                var buffer = context.channel.allocator.buffer(capacity: end - offset)
                buffer.writeBytes(bytes[offset..<end])
                let frame = WebSocketFrame(
                    fin: end == bytes.count,
                    opcode: offset == 0 ? .text : .continuation,
                    data: buffer)
                // Flushed once, after the last: the fragments reach the peer as fast as the
                // socket takes them, which is how a peer floods one.
                context.write(wrapOutboundOut(frame), promise: nil)
                offset = end
            }
            context.flush()
        }
    }
}
