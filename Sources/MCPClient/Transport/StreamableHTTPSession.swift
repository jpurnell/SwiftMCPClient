import Foundation

/// The state a Streamable HTTP session carries between requests.
///
/// Three things outlive any one request: the session id the server assigned, the protocol
/// version it agreed to, and the last event seen on each stream. All three exist to be put
/// back on the wire, so this type's real interface is ``headers(for:resuming:)`` — deciding
/// what a request carries is the whole job, and keeping that decision here makes it a unit
/// test rather than something inferred from a request nobody can inspect.
///
/// Separate from the transport because resumption is a property of the *session*, not of a
/// request, and because a transport's state is only reachable through a socket.
actor StreamableHTTPSession {

    /// Which stream an event id belongs to.
    ///
    /// The GET channel and each POST response are independent sequences. Resuming one with
    /// another's id asks the server to replay from a point that never existed on that stream.
    enum StreamKind: Sendable, Hashable {

        /// The long-lived, server-initiated stream.
        case get

        /// The response stream for one request.
        case post(requestID: String)
    }

    /// Header names, spelled once.
    private enum Header {
        static let session = "Mcp-Session-Id"
        static let protocolVersion = "MCP-Protocol-Version"
        static let lastEvent = "Last-Event-ID"
    }

    /// The session id the server assigned, if it assigned one.
    private(set) var sessionID: String?

    /// The protocol version the server **accepted**, which is not always the one requested.
    private(set) var protocolVersion: String?

    private var lastEventIDs: [StreamKind: String] = [:]

    /// Creates a session that has negotiated nothing yet.
    init() {}

    /// Adopts a session id from a response.
    ///
    /// A `nil` argument is ignored rather than treated as revocation. The server states the id
    /// once; reading its absence from a later response as "the session ended" would drop a
    /// live session on the first response that simply did not repeat itself.
    ///
    /// - Parameter sessionID: The `Mcp-Session-Id` header, if the response carried one.
    func adopt(sessionID: String?) {
        guard let sessionID else { return }
        self.sessionID = sessionID
    }

    /// Adopts the version the server agreed to.
    ///
    /// - Parameter protocolVersion: The version from the `initialize` result — what the server
    ///   accepted, not what was asked for. They differ whenever it negotiates down, and
    ///   echoing the request would assert a version the server has already declined.
    func adopt(protocolVersion: String) {
        self.protocolVersion = protocolVersion
    }

    /// Records the most recent event seen on a stream, for `Last-Event-ID` on reconnect.
    ///
    /// - Parameters:
    ///   - eventID: The `id:` field of the event just delivered.
    ///   - stream: Which stream it arrived on.
    func record(eventID: String, for stream: StreamKind) {
        lastEventIDs[stream] = eventID
    }

    /// The last event seen on a stream, if any.
    func lastEventID(for stream: StreamKind) -> String? {
        lastEventIDs[stream]
    }

    /// Forgets everything, for a session the server no longer has.
    ///
    /// Called on `DELETE`, and on a `404` answering a request that carried a session id. The
    /// event ids go too: resuming a stream that no longer exists asks for a replay from a
    /// point the server has forgotten. So does the version, because re-initializing
    /// re-negotiates it.
    func clear() {
        sessionID = nil
        protocolVersion = nil
        lastEventIDs.removeAll()
    }

    /// The revision that first required `Mcp-Method` and `Mcp-Name`.
    ///
    /// Compared as a string because these are dated revisions, and ISO dates sort
    /// lexicographically — which is the whole reason the protocol names versions this way.
    static let requestMetadataRevision = "2026-07-28"

    /// Whether this session's server expects the mirrored request-metadata headers.
    ///
    /// False until a version is negotiated. Sending them to a server that predates them offers
    /// headers it has no rule for; sending them to one that requires them and validates is the
    /// difference between a request and a `400`.
    var mirrorsRequestMetadata: Bool {
        guard let protocolVersion else { return false }
        return protocolVersion >= Self.requestMetadataRevision
    }

    /// The headers this session contributes to a request.
    ///
    /// `MCP-Protocol-Version` appears only once a version has been negotiated, which is what
    /// keeps it off the `initialize` request — the one request whose purpose is to find out
    /// what the version will be.
    ///
    /// `Last-Event-ID` appears only when reconnecting a stream that has seen an event. The
    /// stream is a parameter only in that case, because the session id and the version do not
    /// depend on which stream is being opened, and asking a caller which stream it means when
    /// the answer cannot matter invites a wrong answer nothing would catch.
    ///
    /// An absent id omits the header rather than sending an empty one: `Last-Event-ID:` with
    /// no value asks the server to replay from an event whose id is the empty string, which is
    /// a different request from "start at the beginning".
    ///
    /// - Parameter stream: The stream being reconnected, or `nil` for an ordinary request.
    /// - Returns: The headers to merge into the request.
    func headers(resuming stream: StreamKind? = nil) -> [String: String] {
        var headers: [String: String] = [:]
        if let sessionID {
            headers[Header.session] = sessionID
        }
        if let protocolVersion {
            headers[Header.protocolVersion] = protocolVersion
        }
        if let stream, let lastEventID = lastEventIDs[stream] {
            headers[Header.lastEvent] = lastEventID
        }
        return headers
    }
}
