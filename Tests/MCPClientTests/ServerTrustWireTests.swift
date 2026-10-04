import Foundation
import Testing
@testable import MCPClient

/// Whether a handshake completes — asked of a real TLS server on loopback.
///
/// A configuration can say `.fullVerification` and still be wrong about what it verifies
/// against, so these assert the only thing a server can observe: whether the request arrived.
/// A request that reached the server was sent over a connection the client agreed to; a count
/// of zero means the client refused before sending anything.
@Suite("ServerTrust — on the wire")
struct ServerTrustWireTests {

    // MARK: - Trusted

    @Test("A self-signed certificate supplied as the only root is trusted")
    func selfSignedAsOnlyRoot() async throws {
        let server = try TestIdentity.selfSigned()
        let arrived = try await requests(
            presenting: server, trusting: try .onlyRoots([.pem(server.pem)]))
        #expect(arrived == 1)
    }

    @Test("A self-signed certificate that claims to be a CA is trusted the same way")
    func selfSignedAuthorityAsOnlyRoot() async throws {
        let server = try TestIdentity.selfSigned(isAuthority: true)
        let arrived = try await requests(
            presenting: server, trusting: try .onlyRoots([.der(server.der)]))
        #expect(arrived == 1)
    }

    @Test("A self-signed certificate supplied as an additional root is trusted")
    func selfSignedAsAdditionalRoot() async throws {
        let server = try TestIdentity.selfSigned()
        let arrived = try await requests(
            presenting: server, trusting: try .additionalRoots([.pem(server.pem)]))
        #expect(arrived == 1)
    }

    @Test("A private CA is trusted for a leaf the client has never seen")
    func privateAuthority() async throws {
        let (authority, leaf) = try TestIdentity.authorityAndLeaf()
        let arrived = try await requests(
            presenting: leaf, trusting: try .onlyRoots([.pem(authority.pem)]))
        #expect(arrived == 1)
    }

    // MARK: - Refused

    /// The case the old flag existed for, and the one it got wrong: with nothing supplied, a
    /// self-signed server is refused.
    @Test("The default refuses a self-signed server")
    func systemRefusesSelfSigned() async throws {
        let server = try TestIdentity.selfSigned()
        await #expect {
            _ = try await requests(presenting: server, trusting: .system)
        } throws: { Self.isTLSRefusal($0) }
    }

    /// What `certificateVerification = .none` could not do. Trusting one self-signed
    /// certificate is not trusting another: a server presenting a different one — which is
    /// what an interposed attacker has — is refused before a byte of the request is sent.
    @Test("Trusting one self-signed certificate does not trust another",
          arguments: [true, false])
    func wrongCertificateFailsClosed(only: Bool) async throws {
        let server = try TestIdentity.selfSigned()
        let impostor = try TestIdentity.selfSigned()
        let sources = [ServerTrust.CertificateSource.pem(server.pem)]
        let trust = only ? try ServerTrust.onlyRoots(sources) : try ServerTrust.additionalRoots(sources)

        let recorder = ArrivalCount()
        await #expect {
            _ = try await requests(presenting: impostor, trusting: trust, recorder: recorder)
        } throws: { Self.isTLSRefusal($0) }
        #expect(await recorder.count == 0)
    }

    @Test("A leaf from some other private CA is refused")
    func wrongAuthorityFailsClosed() async throws {
        let (authority, _) = try TestIdentity.authorityAndLeaf()
        let (_, strangerLeaf) = try TestIdentity.authorityAndLeaf()

        let recorder = ArrivalCount()
        await #expect {
            _ = try await requests(
                presenting: strangerLeaf, trusting: try .onlyRoots([.pem(authority.pem)]),
                recorder: recorder)
        } throws: { Self.isTLSRefusal($0) }
        #expect(await recorder.count == 0)
    }

    /// Supplying a root narrows *who signed it*, never *who it is for*. A trusted certificate
    /// issued for another name is still the wrong server.
    @Test("A trusted certificate for a different host is refused", arguments: [true, false])
    func hostnameIsStillChecked(only: Bool) async throws {
        let server = try TestIdentity.selfSigned(names: [.dnsName("elsewhere.example")])
        let sources = [ServerTrust.CertificateSource.pem(server.pem)]
        let trust = only ? try ServerTrust.onlyRoots(sources) : try ServerTrust.additionalRoots(sources)

        let recorder = ArrivalCount()
        await #expect {
            _ = try await requests(presenting: server, trusting: trust, recorder: recorder)
        } throws: { Self.isTLSRefusal($0) }
        #expect(await recorder.count == 0)
    }

    // MARK: - Helpers

    /// Whether an error is the transport reporting a failed TLS handshake.
    ///
    /// "It threw" is not enough: a stub that never started, or a request that timed out,
    /// throws too. The transport reports a refusal as `connectionFailed` carrying the TLS
    /// layer's own error — NIOSSL's wherever roots were supplied, and Network.framework's on
    /// an Apple platform when the system roots are in use.
    private static func isTLSRefusal(_ error: any Error) -> Bool {
        guard case .connectionFailed(let reason) = error as? MCPError else { return false }
        return reason.contains("NIOSSL") || reason.contains("NWTLSError")
    }

    /// Sends one request through a Streamable HTTP transport to an HTTPS stub.
    ///
    /// - Parameters:
    ///   - identity: What the server presents.
    ///   - trust: What the client is told to trust.
    ///   - recorder: Told how many requests arrived, on the failure path too — a throwing
    ///     call returns nothing, and "it threw" does not by itself say nothing was sent.
    /// - Returns: How many requests reached the server.
    private func requests(
        presenting identity: TestIdentity,
        trusting trust: ServerTrust,
        recorder: ArrivalCount? = nil
    ) async throws -> Int {
        let server = try await StubHTTPServer.start(
            replies: [.ok(#"{"jsonrpc":"2.0","id":1}"#)],
            tls: try identity.serverContext())
        let transport = StreamableHTTPTransport(
            url: try await server.url,
            openServerStream: false,
            connectionTimeout: 3,
            serverTrust: trust)
        try await transport.connect()

        do {
            try await transport.send(Data(#"{"id":1}"#.utf8))
            _ = try await transport.receive()
        } catch {
            await recorder?.set(await server.received.count)
            // silent: teardown after the failure this test is about
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
        let arrived = await server.received.count
        await recorder?.set(arrived)
        // silent: the DELETE that ends a session is not what is being asserted
        try? await transport.disconnect()
        await server.stop()
        return arrived
    }
}

/// Carries a count out of a call that throws.
private actor ArrivalCount {
    /// Starts at a value no server can report, so an assertion of zero cannot pass because
    /// the helper never ran.
    private(set) var count = -1

    func set(_ value: Int) { count = value }
}
