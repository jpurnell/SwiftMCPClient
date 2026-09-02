import Foundation
import Testing
@testable import MCPClient

/// The state a Streamable HTTP session carries between requests.
///
/// Kept out of the transport because resumption is a property of the *session*, not of any one
/// request, and because this is the part worth testing without a socket. Every header the
/// specification says to carry — the session id, the negotiated protocol version, the last
/// event id on resume — is decided here, so what goes on the wire is a unit test rather than
/// something inferred from a request nobody can inspect.
@Suite("Streamable HTTP session")
struct StreamableHTTPSessionTests {

    /// Before anything has been negotiated, a session contributes nothing. In particular it
    /// must not send `MCP-Protocol-Version` on `initialize` — that is the one request whose
    /// whole purpose is to find out what the version will be.
    @Test("A fresh session contributes no headers")
    func freshSessionIsSilent() async throws {
        let session = StreamableHTTPSession()

        #expect(await session.sessionID == nil)
        #expect(await session.protocolVersion == nil)
        #expect(await session.headers().isEmpty)
    }

    /// The server assigns a session id once; every later request carries it, which is what
    /// makes the server able to recognise the conversation.
    @Test("An assigned session id is carried on later requests")
    func carriesAssignedSessionID() async throws {
        let session = StreamableHTTPSession()
        await session.adopt(sessionID: "session-abc")

        #expect(await session.headers()["Mcp-Session-Id"] == "session-abc")
    }

    /// A later response arriving without the header does not mean the session ended. The
    /// server states it once; treating its absence as revocation would drop a live session
    /// on the first response that simply did not repeat itself.
    @Test("A response without a session id does not clear the one held")
    func absentHeaderDoesNotClearSession() async throws {
        let session = StreamableHTTPSession()
        await session.adopt(sessionID: "session-abc")
        await session.adopt(sessionID: nil)

        #expect(await session.sessionID == "session-abc")
    }

    /// The version echoed is the one the **server accepted**, which differs from the one
    /// requested whenever it negotiates down. Echoing what we asked for would assert a version
    /// the server already declined.
    @Test("The negotiated version is echoed, not the requested one")
    func echoesNegotiatedVersion() async throws {
        let session = StreamableHTTPSession()
        await session.adopt(protocolVersion: "2024-11-05")

        #expect(await session.headers()["MCP-Protocol-Version"] == "2024-11-05")
    }

    /// Event ids are per stream. The GET channel and a POST response are separate sequences,
    /// and resuming one with the other's id asks the server to replay from a point that never
    /// existed on that stream.
    @Test("Event ids are tracked per stream, independently")
    func eventIDsAreTrackedPerStream() async throws {
        let session = StreamableHTTPSession()
        await session.record(eventID: "get-7", for: .get)
        await session.record(eventID: "post-3", for: .post(requestID: "req-1"))

        #expect(await session.lastEventID(for: .get) == "get-7")
        #expect(await session.lastEventID(for: .post(requestID: "req-1")) == "post-3")
        #expect(await session.lastEventID(for: .post(requestID: "req-2")) == nil)
    }

    /// Only the newest matters — it is where a resume starts from.
    @Test("A newer event id replaces the last")
    func newerEventIDReplacesLast() async throws {
        let session = StreamableHTTPSession()
        await session.record(eventID: "1", for: .get)
        await session.record(eventID: "2", for: .get)

        #expect(await session.lastEventID(for: .get) == "2")
    }

    /// Resuming sends `Last-Event-ID`, so the server replays what was missed rather than
    /// starting the stream over.
    @Test("Resuming carries the last event id")
    func resumingCarriesLastEventID() async throws {
        let session = StreamableHTTPSession()
        await session.record(eventID: "42", for: .get)

        #expect(await session.headers(resuming: .get)["Last-Event-ID"] == "42")
    }

    /// With nothing recorded the header is **absent**, not empty. `Last-Event-ID:` with no
    /// value is a request to replay from an event with an empty id, which is a different
    /// request from "start at the beginning".
    @Test("Resuming with nothing recorded omits the header entirely")
    func resumingWithoutAnIDOmitsTheHeader() async throws {
        let session = StreamableHTTPSession()

        #expect(await session.headers(resuming: .get)["Last-Event-ID"] == nil)
    }

    /// An ordinary request never carries it — only a reconnect does. Sending it on a fresh
    /// stream asks the server to replay history nobody missed.
    @Test("An ordinary request does not carry a last event id")
    func ordinaryRequestOmitsLastEventID() async throws {
        let session = StreamableHTTPSession()
        await session.record(eventID: "42", for: .get)

        #expect(await session.headers()["Last-Event-ID"] == nil)
    }

    /// A session that has ended — a `DELETE`, or a `404` telling us the server has forgotten
    /// it — leaves nothing behind. Keeping the event ids would resume a stream that no longer
    /// exists, and keeping the version would assert a negotiation that has to happen again.
    @Test("Clearing a session leaves nothing to carry")
    func clearingLeavesNothing() async throws {
        let session = StreamableHTTPSession()
        await session.adopt(sessionID: "session-abc")
        await session.adopt(protocolVersion: "2024-11-05")
        await session.record(eventID: "42", for: .get)

        await session.clear()

        #expect(await session.sessionID == nil)
        #expect(await session.protocolVersion == nil)
        #expect(await session.lastEventID(for: .get) == nil)
        #expect(await session.headers(resuming: .get).isEmpty)
    }

    /// All three together, which is the state every request after initialization is made in.
    @Test("A negotiated, resuming session carries all three headers")
    func fullyEstablishedSessionCarriesEverything() async throws {
        let session = StreamableHTTPSession()
        await session.adopt(sessionID: "session-abc")
        await session.adopt(protocolVersion: "2025-06-18")
        await session.record(eventID: "9", for: .get)

        let headers = await session.headers(resuming: .get)

        #expect(headers == [
            "Mcp-Session-Id": "session-abc",
            "MCP-Protocol-Version": "2025-06-18",
            "Last-Event-ID": "9"
        ])
    }
}

/// The negotiated version reaching the transport that has to echo it.
///
/// `didNegotiate` is a mechanism with exactly one caller, and a mechanism with no caller is the
/// failure this package has now made twice — `updateAuthorization(_:)` sat uncalled for months.
/// This asserts the call happens, at a transport that records it.
@Suite("Protocol version negotiation")
struct ProtocolVersionNegotiationTests {

    /// The version the *server* returned is what gets told to the transport — not the version
    /// requested, which differs whenever the server negotiates down.
    @Test("Initialization tells the transport what the server accepted")
    func initializeTellsTheTransport() async throws {
        let transport = RecordingTransport(negotiated: "2024-11-05")
        let connection = MCPClientConnection(transport: transport)

        _ = try await connection.initialize(
            clientName: "Test", clientVersion: "1.0.0", protocolVersion: "2025-06-18")

        #expect(await transport.negotiatedVersions == ["2024-11-05"],
                "the transport was told the requested version, or was not told at all")
    }
}

/// A transport that answers an initialize handshake and records what it is told.
private actor RecordingTransport: MCPTransport {

    private(set) var negotiatedVersions: [String] = []
    private let negotiated: String
    private var pending: [Data] = []

    init(negotiated: String) {
        self.negotiated = negotiated
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func didNegotiate(protocolVersion: String) async {
        negotiatedVersions.append(protocolVersion)
    }

    func send(_ data: Data) async throws {
        // Only the request needs answering; `notifications/initialized` carries no id.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "protocolVersion": negotiated,
                "capabilities": [:],
                "serverInfo": ["name": "stub", "version": "1.0.0"]
            ]
        ]
        pending.append(try JSONSerialization.data(withJSONObject: response))
    }

    func receive() async throws -> Data {
        guard !pending.isEmpty else {
            throw MCPError.connectionFailed(reason: "nothing queued")
        }
        return pending.removeFirst()
    }
}

/// When the mirrored request-metadata headers apply.
///
/// `Mcp-Method` and `Mcp-Name` arrived in 2026-07-28. Sending them to an earlier server offers
/// headers it has no rule for; withholding them from a server that requires *and validates*
/// them is a `400` on every request.
@Suite("Streamable HTTP session — request metadata era")
struct RequestMetadataEraTests {

    /// Nothing negotiated, nothing mirrored. The `initialize` request itself predates any
    /// answer about which revision is in play.
    @Test("Before negotiation, no metadata headers")
    func beforeNegotiation() async throws {
        #expect(await StreamableHTTPSession().mirrorsRequestMetadata == false)
    }

    /// The revisions this client can meet, and what each expects. Dated revisions sort
    /// lexicographically, which is why the protocol names them this way — but relying on that
    /// silently is how a comparison survives until the day a version is not a date.
    @Test("Each revision gets what it expects", arguments: [
        ("2024-11-05", false),
        ("2025-03-26", false),
        ("2025-06-18", false),
        ("2025-11-25", false),
        ("2026-07-28", true)
    ])
    func perRevision(version: String, mirrors: Bool) async throws {
        let session = StreamableHTTPSession()
        await session.adopt(protocolVersion: version)

        #expect(await session.mirrorsRequestMetadata == mirrors)
    }

    /// A revision after the one that introduced them still gets them. A client that only ever
    /// matched the exact version it was written against stops conforming the day the next
    /// revision ships.
    @Test("A later revision still gets them")
    func laterRevision() async throws {
        let session = StreamableHTTPSession()
        await session.adopt(protocolVersion: "2027-03-01")

        #expect(await session.mirrorsRequestMetadata)
    }
}
