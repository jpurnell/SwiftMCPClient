import Foundation
import Logging
import MCP

/// Opens a connection to a server whose protocol era is not known in advance.
///
/// MCP changed shape twice in a year: a handshake with sessions, then neither. Deciding *which*
/// shape a server speaks is the part most likely to change again, so it lives here rather than
/// inside ``MCPClientConnection`` — a connection that carried era policy would be edited every
/// time a revision landed. Adding an era here is adding a case.
///
/// ## How the era is established
///
/// By asking `server/discover`, which servers implementing 2026-07-28 **must** answer. That
/// single request is both the probe and the negotiation: its answer names every version the
/// server speaks, so nothing has to be guessed and no version is tried speculatively.
///
/// The specification warns about the trap this avoids. A modern server answers `400` for an
/// unsupported version, a missing capability, or a header mismatch — all of which mean "you are
/// talking to a modern server and got something wrong", **not** "this server is old". A client
/// that read any refusal as an old server would downgrade and then send `initialize` to a
/// server that removed the method. So the refusal's *code* decides, via
/// ``MCPClientConnection/era(forRefusalCode:)``, and an unrecognised one is the only thing that
/// justifies falling back.
public enum MCPConnectionFactory {

    /// A connection, and what was learned about the server while opening it.
    public struct Connected: Sendable {
        /// The connection, already oriented to the server's era.
        public let connection: MCPClientConnection
        /// Which shape of the protocol the server speaks.
        public let era: MCPClientConnection.Era
        /// The version both sides settled on.
        public let protocolVersion: String
        /// What the server says it can do, where it said so.
        ///
        /// From `initialize` in the handshake era and from `server/discover` in the stateless
        /// one. `nil` only if a server answered neither, which a conformant one does not.
        public let serverCapabilities: ServerCapabilities?
        /// What the server calls itself.
        ///
        /// A field of the handshake's result in the old era; in the stateless one, servers
        /// identify themselves in each result's `_meta` instead, because there is no handshake
        /// left to say it once.
        public let serverInfo: ServerInfo?
    }

    /// Why a connection could not be established.
    public enum FactoryError: Error, Equatable, Sendable {
        /// The server named versions, and this client speaks none of them.
        ///
        /// Distinct from any transport failure on purpose: nothing is wrong with the network or
        /// the server, and retrying will not help. Someone has to upgrade.
        case noMutualProtocolVersion(serverSupports: [String])
    }

    /// Connects, working out the era on the way.
    ///
    /// - Parameters:
    ///   - transport: The transport to speak over.
    ///   - clientName: This client's name, reported to the server.
    ///   - clientVersion: This client's version.
    ///   - capabilities: What this client can do, declared to the server.
    ///   - requestTimeout: How long a request may take before it is abandoned.
    ///   - preferred: The revision to try first. Defaults to the newest this client speaks.
    /// - Returns: The connection, its era, and the negotiated version.
    /// - Throws: ``FactoryError/noMutualProtocolVersion(serverSupports:)``, or whatever the
    ///   transport threw.
    public static func connect(
        transport: any MCPTransport,
        clientName: String,
        clientVersion: String,
        capabilities: ClientCapabilities = ClientCapabilities(),
        requestTimeout: Duration = .seconds(30),
        preferred: String = MCPClientConnection.supportedProtocolVersions.last ?? "2026-07-28"
    ) async throws -> Connected {
        let connection = MCPClientConnection(transport: transport, requestTimeout: requestTimeout)

        // Begins as though the server were modern. Nothing is committed by this: a stateless
        // session is a declaration, not a handshake, so being wrong costs one request.
        try await connection.beginStateless(
            protocolVersion: preferred, clientName: clientName, clientVersion: clientVersion)

        do {
            let discovered = try await connection.discoverServer()
            return try await settle(
                connection: connection,
                serverSupports: discovered.supportedVersions,
                serverCapabilities: Self.capabilities(from: discovered.capabilities),
                serverInfo: Self.info(from: discovered._meta?.serverInfo),
                clientName: clientName,
                clientVersion: clientVersion)
        } catch let error as MCPError {
            // Recorded here, at the moment the era is actually decided. Without it, a modern
            // server that corrected us leaves no trace: the connection works, and nothing says
            // the first version offered was refused.
            let logger = Logger(label: "MCPClient.MCPConnectionFactory")
            // logging: the refusal that determines which era this connection is opened in
            logger.debug("server/discover failed (\(error.localizedDescription)); deciding the era from it")

            return try await recover(
                from: error,
                connection: connection,
                transport: transport,
                clientName: clientName,
                clientVersion: clientVersion,
                capabilities: capabilities,
                requestTimeout: requestTimeout,
                preferred: preferred)
        }
    }

    /// Carries the SDK's identity shape into the one this client's API speaks.
    private static func info(from serverInfo: Server.Info?) -> ServerInfo? {
        guard let serverInfo else { return nil }
        return ServerInfo(name: serverInfo.name, version: serverInfo.version)
    }

    /// Carries the SDK's capability shape into the one this client's API speaks.
    ///
    /// Two vocabularies exist because the wire types come from the shared SDK while the
    /// connection's own API predates it. Converting through JSON keeps them in step without
    /// either side having to know the other's Swift type — and if a field is added on one side
    /// and not the other, it is simply absent rather than a compile error nobody can act on.
    private static func capabilities(from serverCapabilities: Server.Capabilities) -> ServerCapabilities? {
        // silent: a capability set that will not round-trip is reported as none, and a caller
        // treating "none" as "cannot" is the safe reading
        guard let data = try? JSONEncoder().encode(serverCapabilities),
              let converted = try? JSONDecoder().decode(ServerCapabilities.self, from: data) else {
            return nil
        }
        return converted
    }

    /// Decides what a failed discovery meant, and acts on it.
    private static func recover(
        from error: MCPError,
        connection: MCPClientConnection,
        transport: any MCPTransport,
        clientName: String,
        clientVersion: String,
        capabilities: ClientCapabilities,
        requestTimeout: Duration,
        preferred: String
    ) async throws -> Connected {
        let code: Int?
        if case .requestFailed(let failed, _, _) = error { code = failed } else { code = nil }

        switch MCPClientConnection.era(forRefusalCode: code) {
        case .stateless:
            // A modern server correcting us. The versions it named are the answer, and falling
            // back here would be downgrading a server that is perfectly current.
            let supported = MCPClientConnection.supportedVersions(from: error)
            return try await settle(
                connection: connection,
                serverSupports: supported,
                serverCapabilities: nil,
                serverInfo: nil,
                clientName: clientName,
                clientVersion: clientVersion)

        case .handshake:
            // The server did not recognise the request. Only this justifies `initialize`.
            let logger = Logger(label: "MCPClient.MCPConnectionFactory")
            // logging: which answer led to the fallback, since the choice is not otherwise visible
            logger.debug("server did not answer server/discover (\(error)); using the handshake era")

            let handshake = MCPClientConnection(
                transport: transport, requestTimeout: requestTimeout)
            // The newest this client speaks, not `initialize`'s default. A handshake negotiates
            // *down* — the client names its best and the server answers with the best it
            // shares — so asking for an old revision does not play safe, it caps the result and
            // leaves the server no way to offer better.
            let result = try await handshake.initialize(
                clientName: clientName,
                clientVersion: clientVersion,
                capabilities: capabilities,
                protocolVersion: preferred)
            return Connected(
                connection: handshake,
                era: .handshake,
                protocolVersion: result.protocolVersion,
                serverCapabilities: result.capabilities,
                serverInfo: result.serverInfo)
        }
    }

    /// Settles on a version both sides speak, re-declaring it if it is not what was tried.
    private static func settle(
        connection: MCPClientConnection,
        serverSupports: [String],
        serverCapabilities: ServerCapabilities?,
        serverInfo: ServerInfo?,
        clientName: String,
        clientVersion: String
    ) async throws -> Connected {
        guard let mutual = MCPClientConnection.bestMutualVersion(serverSupports: serverSupports) else {
            throw FactoryError.noMutualProtocolVersion(serverSupports: serverSupports)
        }

        // Re-declared only when it differs. The declaration is what every later request states,
        // so leaving it at a version the server did not accept would fail every one of them.
        if await connection.negotiatedProtocolVersion != mutual {
            try await connection.beginStateless(
                protocolVersion: mutual, clientName: clientName, clientVersion: clientVersion)
        }
        return Connected(
            connection: connection,
            era: .stateless,
            protocolVersion: mutual,
            serverCapabilities: serverCapabilities,
            serverInfo: serverInfo)
    }
}
