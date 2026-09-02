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
