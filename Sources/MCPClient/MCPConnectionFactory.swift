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
    ///   - preferred: The revision to try first. Defaults to the newest this client speaks.
    /// - Returns: The connection, its era, and the negotiated version.
    /// - Throws: ``FactoryError/noMutualProtocolVersion(serverSupports:)``, or whatever the
    ///   transport threw.
    public static func connect(
        transport: any MCPTransport,
        clientName: String,
        clientVersion: String,
        preferred: String = MCPClientConnection.supportedProtocolVersions.last ?? "2026-07-28"
    ) async throws -> Connected {
        let connection = MCPClientConnection(transport: transport)

        // Begins as though the server were modern. Nothing is committed by this: a stateless
        // session is a declaration, not a handshake, so being wrong costs one request.
        try await connection.beginStateless(
            protocolVersion: preferred, clientName: clientName, clientVersion: clientVersion)

        do {
            let discovered = try await connection.discoverServer()
            return try await settle(
                connection: connection,
                serverSupports: discovered.supportedVersions,
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
                clientVersion: clientVersion)
        }
    }

    /// Decides what a failed discovery meant, and acts on it.
    private static func recover(
        from error: MCPError,
        connection: MCPClientConnection,
        transport: any MCPTransport,
        clientName: String,
        clientVersion: String
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
                clientName: clientName,
                clientVersion: clientVersion)

        case .handshake:
            // The server did not recognise the request. Only this justifies `initialize`.
            let logger = Logger(label: "MCPClient.MCPConnectionFactory")
            // logging: which answer led to the fallback, since the choice is not otherwise visible
            logger.debug("server did not answer server/discover (\(error)); using the handshake era")

            let handshake = MCPClientConnection(transport: transport)
            let result = try await handshake.initialize(
                clientName: clientName, clientVersion: clientVersion)
            return Connected(
                connection: handshake,
                era: .handshake,
                protocolVersion: result.protocolVersion)
        }
    }

    /// Settles on a version both sides speak, re-declaring it if it is not what was tried.
    private static func settle(
        connection: MCPClientConnection,
        serverSupports: [String],
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
        return Connected(connection: connection, era: .stateless, protocolVersion: mutual)
    }
}
