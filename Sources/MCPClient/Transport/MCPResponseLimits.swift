import Foundation
import AsyncHTTPClient
import NIOCore

/// How much a server may send in one piece before a transport stops reading it.
///
/// A response is read into memory before it is decoded, and so is each Server-Sent Event. With
/// no limit, the amount of memory a connection costs is the server's to choose — a body with
/// no end, or an event whose terminating blank line never comes, is read until the process
/// has none left. Each limit bounds one message: what is read past it is not buffered, the
/// read is abandoned, and the failure is ``MCPError/responseTooLarge(limit:reason:)``.
///
/// The defaults are generous on purpose. A JSON-RPC message is usually a few kilobytes and
/// occasionally — a tool catalogue, a resource with an embedded image — a few megabytes; ten
/// mebibytes is beyond anything a well-behaved server was found to send, and small enough
/// that a hostile one cannot do harm with it. Raise a limit for a server known to need it.
public struct MCPResponseLimits: Sendable, Equatable {

    /// The default for both limits: 10 MiB.
    public static let defaultMaximumBytes = 10 * 1024 * 1024

    /// The most bytes one HTTP response body may hold when it is a single JSON document.
    ///
    /// Applies to the body of a `POST`'s response that is not an event stream. A value below
    /// `1` is treated as `1`.
    public var maximumResponseBytes: Int

    /// The most bytes one Server-Sent Event may hold, from its first line to the blank line
    /// that ends it.
    ///
    /// Applies to every event stream a transport reads: a `POST`'s streamed response, the
    /// server-initiated stream, a resumption, and the legacy HTTP+SSE stream. A stream may
    /// carry any number of events; this bounds each. A value below `1` is treated as `1`.
    public var maximumEventBytes: Int

    /// Creates a pair of limits.
    ///
    /// - Parameters:
    ///   - maximumResponseBytes: The most bytes one JSON response body may hold. Default 10 MiB.
    ///   - maximumEventBytes: The most bytes one Server-Sent Event may hold. Default 10 MiB.
    public init(
        maximumResponseBytes: Int = MCPResponseLimits.defaultMaximumBytes,
        maximumEventBytes: Int = MCPResponseLimits.defaultMaximumBytes
    ) {
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.maximumEventBytes = max(1, maximumEventBytes)
    }

    /// The limits a transport uses unless it is given others: 10 MiB each.
    public static let standard = MCPResponseLimits()

    /// The error for one piece of a response that went past its limit.
    ///
    /// - Parameters:
    ///   - limit: The limit, in bytes.
    ///   - what: What was being read, in a few words — `"response body"`, `"event"`.
    ///   - url: Where it was being read from. Only its origin is named.
    /// - Returns: The error.
    static func exceeded(_ limit: Int, reading what: String, from url: URL?) -> MCPError {
        let origin = url.map(HTTPOrigin.description(of:)) ?? "the server"
        return .responseTooLarge(
            limit: limit,
            reason: "A single \(what) from \(origin) is larger than the \(limit)-byte limit. "
                + "Reading stopped there and what had arrived was discarded")
    }

    /// Reads a response body into memory, up to a limit.
    ///
    /// The one place a transport collects a body, so that a read which fails has one
    /// description. A body past the limit is not buffered past it: a declared `Content-Length`
    /// over the limit is refused from the response head, before anything is read, and an
    /// undeclared one is stopped at the chunk that crosses it.
    ///
    /// - Parameters:
    ///   - response: The response, its body unread.
    ///   - limit: The most bytes to accept.
    ///   - url: Where it is being read from. Only its origin is named.
    /// - Returns: The body.
    /// - Throws: ``MCPError/responseTooLarge(limit:reason:)`` if the body is larger than
    ///   `limit`; ``MCPError/connectionFailed(reason:)``, composed by ``TransportFailure``,
    ///   if reading it failed — the networking library's own error is not passed on.
    static func collect(
        _ response: HTTPClientResponse,
        upTo limit: Int,
        from url: URL
    ) async throws -> ByteBuffer {
        // A length the server declared is known from the response head, so a body that says
        // it is too large is refused on that alone. Left to `collect(upTo:)`, the refusal
        // races the connection: a server that sends the body and closes can make the read
        // fail as a dropped connection before the size is ever checked.
        if let declared = response.headers.first(name: "Content-Length").flatMap({ Int($0) }),
           declared > limit {
            throw exceeded(limit, reading: "response body", from: url)
        }
        do {
            return try await response.body.collect(upTo: limit)
        } catch is NIOTooManyBytesError {
            throw exceeded(limit, reading: "response body", from: url)
        } catch {
            throw MCPError.connectionFailed(reason: TransportFailure.reason(for: error, reaching: url))
        }
    }
}
