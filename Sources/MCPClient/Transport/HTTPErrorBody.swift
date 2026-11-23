import Foundation
import AsyncHTTPClient
import NIOCore
import Logging

/// Reads the JSON-RPC error a server put in the body of a non-2xx response.
///
/// MCP servers refuse some requests at the HTTP layer and still explain themselves in JSON-RPC:
/// `400` with `-32022` and the revisions the server speaks, `404` with `-32601` for a method
/// that no longer exists. The code and the data are the protocol's answer; the HTTP status is
/// only how it travelled. A transport that throws on the status alone discards the answer, and
/// everything downstream that decides from the code — which era a server speaks, which version
/// to retry with — decides from `400` instead.
enum HTTPErrorBody {

    /// The most of an error body that is read. Real refusals are a few hundred bytes; the bound
    /// is what stops a server (or anything answering in its place) choosing how much to buffer.
    static let maximumBytes = 64 * 1024

    /// The JSON-RPC error carried by a non-2xx response, if its body is one.
    ///
    /// Reading fails closed: a body that is too large, cannot be read, or is anything other
    /// than a JSON-RPC 2.0 error object yields `nil`, and the caller reports the HTTP status as
    /// it always did.
    ///
    /// - Parameter body: The response body, not yet read.
    /// - Returns: The error, or `nil` when the body is not a JSON-RPC error.
    static func jsonRPCError(in body: HTTPClientResponse.Body) async -> JSONRPCError? {
        let collected: ByteBuffer
        do {
            collected = try await body.collect(upTo: maximumBytes)
        } catch {
            let logger = Logger(label: "MCPClient.HTTPErrorBody")
            // logging: the error body could not be read within its bound, so the HTTP status is reported instead
            logger.debug("error body not read: \(type(of: error))")
            return nil
        }
        return jsonRPCError(in: Data(buffer: collected))
    }

    /// The JSON-RPC error a body holds, if it holds one.
    ///
    /// Strict about shape: `jsonrpc` must be `"2.0"`, `error.code` an integer and
    /// `error.message` a string. A body that merely mentions an `error` is not one.
    ///
    /// - Parameter data: The body.
    /// - Returns: The error, or `nil`.
    static func jsonRPCError(in data: Data) -> JSONRPCError? {
        struct Envelope: Decodable {
            let jsonrpc: String
            let error: JSONRPCError
        }
        // silent: a body that is not a JSON-RPC error is the ordinary case (an HTML page, an
        // OAuth error), and the caller reports the HTTP status for it
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.jsonrpc == "2.0" else {
            return nil
        }
        return envelope.error
    }
}
