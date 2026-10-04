import Foundation
import Testing
import Crypto
import NIOSSL
@testable import MCPClient

/// What a transport is prepared to believe about the server it is talking to.
///
/// These replace three tests that constructed a transport with `trustSelfSignedCertificates:
/// true` and asserted nothing. What that flag did was set NIOSSL's verification to `.none`,
/// which is not trust in a self-signed certificate — it is trust in whoever answers. Every
/// test here asserts the configuration NIOSSL is actually handed, because the old defect was
/// invisible everywhere else.
@Suite("ServerTrust")
struct ServerTrustTests {

    // MARK: - The default

    @Test("The default verifies the chain and the hostname against the system roots")
    func systemVerifiesFully() {
        let configuration = ServerTrust.system.makeTLSConfiguration()

        #expect(configuration.certificateVerification == .fullVerification)
        #expect(configuration.trustRoots == .default)
        #expect(configuration.additionalTrustRoots == [])
        #expect(ServerTrust.system.usesSystemRoots == true)
        #expect(ServerTrust.system.rootFingerprints == [])
    }

    // MARK: - Supplied roots

    @Test("Additional roots are added to the system roots, with verification left on")
    func additionalRootsKeepSystemRoots() throws {
        let identity = try TestIdentity.selfSigned()
        let trust = try ServerTrust.additionalRoots([.pem(identity.pem)])
        let configuration = trust.makeTLSConfiguration()

        #expect(configuration.certificateVerification == .fullVerification)
        #expect(configuration.trustRoots == .default)
        #expect(configuration.additionalTrustRoots == [.certificates([try certificate(identity)])])
        #expect(trust.usesSystemRoots == true)
        #expect(trust.rootFingerprints == [fingerprint(identity)])
    }

    @Test("Only-roots replaces the system roots, with verification left on")
    func onlyRootsReplaceSystemRoots() throws {
        let identity = try TestIdentity.selfSigned()
        let trust = try ServerTrust.onlyRoots([.der(identity.der)])
        let configuration = trust.makeTLSConfiguration()

        #expect(configuration.certificateVerification == .fullVerification)
        #expect(configuration.trustRoots == .certificates([try certificate(identity)]))
        #expect(configuration.additionalTrustRoots == [])
        #expect(trust.usesSystemRoots == false)
        #expect(trust.rootFingerprints == [fingerprint(identity)])
    }

    @Test("A PEM bundle contributes every certificate in it, in order")
    func pemBundleContributesEveryCertificate() throws {
        let first = try TestIdentity.selfSigned(commonName: "first")
        let second = try TestIdentity.selfSigned(commonName: "second")
        let trust = try ServerTrust.onlyRoots([.pem(first.pem + "\n" + second.pem)])

        #expect(trust.rootFingerprints == [fingerprint(first), fingerprint(second)])
        #expect(trust.makeTLSConfiguration().trustRoots
                == .certificates([try certificate(first), try certificate(second)]))
    }

    @Test("Several sources are concatenated in the order given")
    func sourcesAreConcatenated() throws {
        let first = try TestIdentity.selfSigned(commonName: "first")
        let second = try TestIdentity.selfSigned(commonName: "second")
        let trust = try ServerTrust.additionalRoots([.der(second.der), .pem(first.pem)])

        #expect(trust.rootFingerprints == [fingerprint(second), fingerprint(first)])
    }

    @Test("A PEM file is read when the trust is made")
    func pemFileIsRead() throws {
        let identity = try TestIdentity.selfSigned()
        let path = try TestIdentity.temporaryFile(Array(identity.pem.utf8), fileExtension: "pem")
        defer { try? FileManager.default.removeItem(atPath: path) } // silent: best-effort cleanup of a temporary file

        let trust = try ServerTrust.onlyRoots([.pemFile(path)])

        #expect(trust.rootFingerprints == [fingerprint(identity)])
        #expect(trust.makeTLSConfiguration().certificateVerification == .fullVerification)
    }

    @Test("A DER file is read when the trust is made")
    func derFileIsRead() throws {
        let identity = try TestIdentity.selfSigned()
        let path = try TestIdentity.temporaryFile(identity.der, fileExtension: "der")
        defer { try? FileManager.default.removeItem(atPath: path) } // silent: best-effort cleanup of a temporary file

        let trust = try ServerTrust.additionalRoots([.derFile(path)])

        #expect(trust.rootFingerprints == [fingerprint(identity)])
    }

    @Test("Equal trust compares equal, and different roots do not")
    func equality() throws {
        let identity = try TestIdentity.selfSigned()
        let other = try TestIdentity.selfSigned()

        #expect(try ServerTrust.onlyRoots([.pem(identity.pem)]) == ServerTrust.onlyRoots([.der(identity.der)]))
        #expect(try ServerTrust.onlyRoots([.pem(identity.pem)]) != ServerTrust.onlyRoots([.pem(other.pem)]))
        #expect(try ServerTrust.onlyRoots([.pem(identity.pem)]) != ServerTrust.additionalRoots([.pem(identity.pem)]))
        #expect(ServerTrust.system == ServerTrust.system)
    }

    // MARK: - Failing closed

    /// An empty list under `onlyRoots` would be a client that trusts nothing, and under
    /// `additionalRoots` one that silently means `.system`. Neither is what anyone wrote.
    @Test("No sources is an error, not a silent default", arguments: [true, false])
    func emptySourcesThrow(only: Bool) {
        #expect(throws: ServerTrustError.noCertificates) {
            _ = only ? try ServerTrust.onlyRoots([]) : try ServerTrust.additionalRoots([])
        }
    }

    @Test("Text that holds no certificate is refused")
    func garbagePEMThrows() {
        let source = ServerTrust.CertificateSource.pem("not a certificate")
        #expect(throws: ServerTrustError.unreadable(source)) {
            _ = try ServerTrust.onlyRoots([source])
        }
    }

    @Test("Bytes that are not a DER certificate are refused")
    func garbageDERThrows() {
        let source = ServerTrust.CertificateSource.der([0x30, 0x03, 0x02, 0x01, 0x01])
        #expect(throws: ServerTrustError.unreadable(source)) {
            _ = try ServerTrust.additionalRoots([source])
        }
    }

    @Test("A file that is not there is refused rather than skipped")
    func missingFileThrows() {
        let source = ServerTrust.CertificateSource.pemFile("/nonexistent/mcp-trust-\(UUID().uuidString).pem")
        #expect(throws: ServerTrustError.unreadable(source)) {
            _ = try ServerTrust.onlyRoots([source])
        }
    }

    /// One bad source must not be dropped while the good ones are kept: the caller asked for
    /// a set of roots, and a subset of it is a different trust decision.
    @Test("One unreadable source fails the whole set")
    func oneBadSourceFailsTheSet() throws {
        let identity = try TestIdentity.selfSigned()
        let bad = ServerTrust.CertificateSource.pem("")
        #expect(throws: ServerTrustError.unreadable(bad)) {
            _ = try ServerTrust.additionalRoots([.pem(identity.pem), bad])
        }
    }

    // MARK: - Every transport uses it

    @Test("Each transport verifies fully by default")
    func transportsDefaultToFullVerification() throws {
        let expected = ServerTrust.system.makeTLSConfiguration()
        let http = try requireURL("https://mcp.example.com/mcp")
        let socket = try requireURL("wss://mcp.example.com/ws")

        for configuration in [
            StreamableHTTPTransport(url: http).tlsConfiguration,
            HTTPSSETransport(url: http).tlsConfiguration,
            WebSocketTransport(url: socket).tlsConfiguration,
        ] {
            #expect(configuration.certificateVerification == .fullVerification)
            #expect(configuration.trustRoots == expected.trustRoots)
            #expect(configuration.additionalTrustRoots == [])
        }
    }

    @Test("Each transport hands NIOSSL the supplied roots with verification on")
    func transportsCarrySuppliedRoots() throws {
        let identity = try TestIdentity.selfSigned()
        let trust = try ServerTrust.onlyRoots([.pem(identity.pem)])
        let roots = NIOSSLTrustRoots.certificates([try certificate(identity)])
        let http = try requireURL("https://mcp.example.com/mcp")
        let socket = try requireURL("wss://mcp.example.com/ws")

        for configuration in [
            StreamableHTTPTransport(url: http, serverTrust: trust).tlsConfiguration,
            HTTPSSETransport(url: http, serverTrust: trust).tlsConfiguration,
            WebSocketTransport(url: socket, serverTrust: trust).tlsConfiguration,
        ] {
            #expect(configuration.certificateVerification == .fullVerification)
            #expect(configuration.trustRoots == roots)
            #expect(configuration.additionalTrustRoots == [])
        }
    }

    // MARK: - Helpers

    private func certificate(_ identity: TestIdentity) throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: identity.der, format: .der)
    }

    /// Computed here from the DER rather than read back from `ServerTrust`, so the expected
    /// value does not come from the code under test.
    private func fingerprint(_ identity: TestIdentity) -> String {
        SHA256.hash(data: identity.der).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
