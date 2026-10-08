import Foundation
import Testing
import MCP
@testable import MCPClient

/// Working out which era a server speaks, and handing back a connection already oriented to it.
///
/// This lives apart from ``MCPClientConnection`` on purpose. MCP is young and its shape has
/// already changed twice in a year — sessions and a handshake, then neither. Era *policy* is the
/// part most likely to change again, and a connection that carried it would be edited every time
/// it did. Here, adding an era is adding a case to a factory.
@Suite("Connection factory")
struct ConnectionFactoryTests {

    /// A modern server answers `server/discover`, which is both the probe and the negotiation:
    /// it says which versions the server speaks, so nothing has to be guessed.
    @Test("A stateless server is detected without a handshake", .timeLimit(.minutes(1)))
    func detectsStatelessServer() async throws {
        let transport = EraStubTransport(era: .stateless, supports: ["2026-07-28"])
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")

        #expect(connected.era == .stateless)
        #expect(connected.protocolVersion == "2026-07-28")
        #expect(await transport.methodsSent.contains("initialize") == false,
                "a handshake was sent to a server that removed the method")
    }

    /// An older server does not know `server/discover` and says so. That — not a bare `400` —
    /// is what a fallback is allowed to act on.
    @Test("A handshake-era server is detected and initialized", .timeLimit(.minutes(1)))
    func detectsHandshakeServer() async throws {
        let transport = EraStubTransport(era: .handshake, supports: ["2025-06-18"])
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")

        #expect(connected.era == .handshake)
        #expect(connected.protocolVersion == "2025-06-18")
        #expect(await transport.methodsSent.contains("initialize"))
    }

    /// The trap the specification warns about: a modern server answering `400` for a version it
    /// does not support is *correcting* the client, not revealing itself as old. Falling back
    /// here would send `initialize` to a server that removed the method.
    @Test("A version refusal is corrected, not downgraded", .timeLimit(.minutes(1)))
    func refusalIsCorrectedNotDowngraded() async throws {
        let transport = EraStubTransport(
            era: .stateless, supports: ["2026-07-28"], refusesFirstVersion: true)
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")

        #expect(connected.era == .stateless, "a modern server was mistaken for an old one")
        #expect(await transport.methodsSent.contains("initialize") == false)
    }

    /// A server sharing no version with this client is told apart from one that is merely old.
    /// Guessing a version it refused would produce a failure that reads as a bug here.
    @Test("No mutual version fails clearly", .timeLimit(.minutes(1)))
    func noMutualVersionFails() async throws {
        let transport = EraStubTransport(era: .stateless, supports: ["2099-01-01"])

        await #expect(throws: (any Error).self) {
            _ = try await MCPConnectionFactory.connect(
                transport: transport, clientName: "probe", clientVersion: "1.0")
        }
    }

    /// The negotiated version is the newest both sides know, not the newest either knows.
    @Test("The best mutual version is chosen", .timeLimit(.minutes(1)))
    func choosesBestMutualVersion() async throws {
        let transport = EraStubTransport(
            era: .stateless, supports: ["2024-11-05", "2025-11-25", "2099-01-01"])
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")

        #expect(connected.protocolVersion == "2025-11-25")
    }
}

/// What the fallback does to the transport it is handed.
///
/// `ConnectionFactoryTests.detectsHandshakeServer` failed in 2 of 33 full runs measured, with
/// `connectionFailed("nothing queued")`, on a mock transport, and passed alone. The cause was
/// in the factory, not the test. Beginning a stateless session starts a dispatcher, whose loop
/// sits in `transport.receive()`. When the server turned out to be handshake-era the factory
/// made a *second* connection on the same transport and called `initialize` on it, which
/// reads its answer with a `receive()` of its own — while the first connection's loop was
/// still parked in one. Two readers, one response: whichever was resumed took it. If that was
/// the first connection's dispatcher, it filed the response under an id nobody there was
/// waiting for, and `initialize` waited for an answer that had already been delivered
/// elsewhere. Against a real transport that is a hang until the caller's own timeout, since
/// `initialize` reads the transport directly and has none.
@Suite("Connection factory — one reader per transport")
struct ConnectionFactoryReaderTests {

    /// The stub delivers each response to the reader that has been waiting longest, and
    /// refuses a second reader outright. Neither is exotic: it is what a queue with one
    /// consumer does, and what the real transports' single continuation cannot do at all.
    @Test("Falling back to a handshake never reads the transport from two places at once",
          .timeLimit(.minutes(1)))
    func fallbackHasOneReader() async throws {
        let transport = SingleReaderTransport()

        // Raced against a limit, because the defect is a wait that never ends: the response
        // goes to a reader that was not waiting for it, and the one that was waits on. The
        // limit is reached only by a failing run, and releasing the transport is what lets
        // that run finish and say so.
        let (outcomes, outcome) = AsyncStream<Result<MCPConnectionFactory.Connected, any Error>?>.makeStream()
        let connecting = Task {
            do {
                outcome.yield(.success(try await MCPConnectionFactory.connect(
                    transport: transport, clientName: "probe", clientVersion: "1.0")))
            } catch {
                outcome.yield(.failure(error))
            }
        }
        let limit = Task {
            try await Task.sleep(for: .seconds(5))
            outcome.yield(nil)
        }
        var first: Result<MCPConnectionFactory.Connected, any Error>??
        for await result in outcomes {
            first = result
            break
        }
        limit.cancel()
        guard let finished = first, let result = finished else {
            Issue.record("the handshake's answer never reached it; methods sent: \(await transport.methodsSent), overlapping reads: \(await transport.overlappingReads)")
            try await transport.disconnect()
            _ = await connecting.result
            return
        }
        let connected = try result.get()

        #expect(connected.era == .handshake)
        #expect(connected.protocolVersion == "2025-06-18")
        #expect(await transport.methodsSent == ["server/discover", "initialize", "notifications/initialized"])
        #expect(await transport.overlappingReads == 0,
                "the transport was read by two callers at once")

        // And the connection it hands back is the one that is listening: a request made on
        // it is answered.
        let tools = try await connected.connection.listTools()
        #expect(tools.isEmpty)
        try await connected.connection.disconnect()
    }

    /// A stateless connection that is disconnected has to disconnect its transport. It did
    /// not: `beginStateless` connected the transport without recording that it had, so
    /// `disconnect()` skipped it — and an HTTP transport left holding a live client is a
    /// process that traps when the client is deallocated.
    @Test("Disconnecting a stateless connection disconnects its transport", .timeLimit(.minutes(1)))
    func statelessDisconnectReachesTheTransport() async throws {
        let transport = SingleReaderTransport(era: .stateless)
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")
        #expect(connected.era == .stateless)

        try await connected.connection.disconnect()
        #expect(await transport.disconnects == 1)
    }
}

/// A transport with one queue and room for one reader, which says so when a second arrives.
private actor SingleReaderTransport: MCPTransport {

    private let era: MCPClientConnection.Era
    private var pending: [Data] = []
    private var reader: CheckedContinuation<Data, any Error>?
    private(set) var methodsSent: [String] = []
    private(set) var overlappingReads = 0
    private(set) var disconnects = 0

    init(era: MCPClientConnection.Era = .handshake) {
        self.era = era
    }

    func connect() async throws {}

    func disconnect() async throws {
        disconnects += 1
        reader?.resume(throwing: MCPClient.MCPError.transportClosed)
        reader = nil
    }

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let method = object["method"] as? String ?? ""
        methodsSent.append(method)
        guard let id = object["id"] else { return }

        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch (method, era) {
        case ("server/discover", .handshake):
            response["error"] = ["code": -32601, "message": "Method not found"]
        case ("server/discover", .stateless):
            response["result"] = [
                "supportedVersions": ["2026-07-28"],
                "capabilities": [String: Any](),
                "resultType": "complete"
            ]
        case ("initialize", _):
            response["result"] = [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "1.0.0"]
            ]
        case ("tools/list", _):
            response["result"] = ["tools": [[String: Any]]()]
        default:
            response["result"] = ["resultType": "complete"]
        }
        let encoded = try JSONSerialization.data(withJSONObject: response)
        if let reader {
            self.reader = nil
            reader.resume(returning: encoded)
        } else {
            pending.append(encoded)
        }
    }

    func receive() async throws -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        guard reader == nil else {
            overlappingReads += 1
            throw MCPClient.MCPError.connectionFailed(reason: "a second reader arrived while one was waiting")
        }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
}

/// A server of a chosen era.
private actor EraStubTransport: MCPTransport {

    private let era: MCPClientConnection.Era
    private let supports: [String]
    private let refusesFirstVersion: Bool
    private var refusedOnce = false
    private var pending: [Data] = []
    private(set) var methodsSent: [String] = []

    init(
        era: MCPClientConnection.Era,
        supports: [String],
        refusesFirstVersion: Bool = false
    ) {
        self.era = era
        self.supports = supports
        self.refusesFirstVersion = refusesFirstVersion
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        let method = object["method"] as? String ?? ""
        methodsSent.append(method)

        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch (method, era) {
        case ("server/discover", .stateless) where refusesFirstVersion && !refusedOnce:
            refusedOnce = true
            // A modern server correcting the client, which must not be read as an old one.
            response["error"] = ["code": -32022, "message": "unsupported",
                                 "data": ["supported": supports]]
        case ("server/discover", .stateless):
            response["result"] = [
                "supportedVersions": supports,
                "capabilities": [String: Any](),
                "resultType": "complete"
            ]
        case ("server/discover", .handshake):
            // An older server does not know the method.
            response["error"] = ["code": -32601, "message": "Method not found"]
        case ("initialize", _):
            response["result"] = [
                "protocolVersion": supports.first ?? "2025-06-18",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "1.0.0"]
            ]
        default:
            response["result"] = ["resultType": "complete"]
        }
        pending.append(try JSONSerialization.data(withJSONObject: response))
    }

    func receive() async throws -> Data {
        for _ in 0..<200 {
            if !pending.isEmpty { return pending.removeFirst() }
            // silent: a cancelled sleep ends the wait, and the throw below reports it
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw MCPClient.MCPError.connectionFailed(reason: "nothing queued")
    }
}

/// What version the handshake fallback asks for.
///
/// A handshake negotiates *down*: the client names the newest revision it speaks and the server
/// answers with the newest it shares. Asking for an old one therefore does not "play safe" — it
/// caps the result, and the server has no way to offer better.
@Suite("Connection factory — handshake version")
struct HandshakeVersionTests {

    /// The fallback asks for this client's newest, not for whatever `initialize` defaults to.
    ///
    /// This is why a server supporting 2025-11-25 was negotiating 2024-11-05: the default is
    /// four revisions old and the fallback never overrode it.
    @Test("The handshake asks for the newest version this client speaks", .timeLimit(.minutes(1)))
    func asksForNewest() async throws {
        let transport = NegotiatingStubTransport(supports: "2025-11-25")
        _ = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")

        #expect(await transport.requestedVersion == MCPClientConnection.supportedProtocolVersions.last,
                "the fallback asked for something other than this client's newest")
    }

    /// And takes what the server answers with, which is what negotiating down means.
    @Test("The server's answer is what the connection uses", .timeLimit(.minutes(1)))
    func usesTheServersAnswer() async throws {
        let transport = NegotiatingStubTransport(supports: "2025-11-25")
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0")

        #expect(connected.protocolVersion == "2025-11-25")
    }
}

/// A handshake-era server that negotiates down to what it supports.
private actor NegotiatingStubTransport: MCPTransport {

    private let supports: String
    private var pending: [Data] = []
    private(set) var requestedVersion: String?

    init(supports: String) {
        self.supports = supports
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        let method = object["method"] as? String ?? ""

        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if method == "server/discover" {
            response["error"] = ["code": -32601, "message": "Method not found"]
        } else if method == "initialize" {
            let params = object["params"] as? [String: Any]
            requestedVersion = params?["protocolVersion"] as? String
            // Negotiating down: the server answers with what it supports, whatever was asked.
            response["result"] = [
                "protocolVersion": supports,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "1.0.0"]
            ]
        } else {
            response["result"] = ["resultType": "complete"]
        }
        pending.append(try JSONSerialization.data(withJSONObject: response))
    }

    func receive() async throws -> Data {
        for _ in 0..<200 {
            if !pending.isEmpty { return pending.removeFirst() }
            // silent: a cancelled sleep ends the wait, and the throw below reports it
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw MCPClient.MCPError.connectionFailed(reason: "nothing queued")
    }
}
