import Foundation
import Testing
import MCPClient
@testable import MCPExplorer

/// What the Explorer's "trusted certificate" field turns into.
///
/// The field replaces a toggle labelled "Trust self-signed certificates", which did not do
/// that: it turned certificate verification off. A file path cannot be mistaken for an off
/// switch, and these check that it is not one.
@Suite("Trusted certificate file")
struct TrustedCertificateFileTests {

    /// A public certificate with no key, valid until 2126. The fingerprint below is what
    /// `openssl x509 -fingerprint -sha256` printed for it, so the expected value comes from
    /// outside this package.
    private static let fixture = """
        -----BEGIN CERTIFICATE-----
        MIIBnjCCAUOgAwIBAgIUOectdds2c9YRe7YidIl1xm08aTYwCgYIKoZIzj0EAwIw
        IzEhMB8GA1UEAwwYTUNQRXhwbG9yZXIgdGVzdCBmaXh0dXJlMCAXDTI2MTAwNDAz
        NDQyMloYDzIxMjYwOTEwMDM0NDIyWjAjMSEwHwYDVQQDDBhNQ1BFeHBsb3JlciB0
        ZXN0IGZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARwFCzOLzThrelP
        LoO5bw5fFhnjaIrVt9VQBQRSA5ayW3ImvIVscAn4vbfelNykRjVMPk4nwMytBxmc
        LZoJBsPPo1MwUTAdBgNVHQ4EFgQUQVCEFgY695yGih37zZBQkebov+IwHwYDVR0j
        BBgwFoAUQVCEFgY695yGih37zZBQkebov+IwDwYDVR0TAQH/BAUwAwEB/zAKBggq
        hkjOPQQDAgNJADBGAiEA1ef7enXlzDdYKV1wBhZTnzPKBWou0g7W4bGin5MKXKcC
        IQDWwg6Z4tYtX8rPuMDW9APsO34xUCRAXzyfIv7KqaST4g==
        -----END CERTIFICATE-----

        """
    private static let fixtureFingerprint =
        "3efc4002d9fd0161d91cc8280d95d3df56e5ebcb2f55e4ca51bcab5045da53de"

    @Test("An empty field means the system roots", arguments: ["", "   ", "\n\t"])
    func emptyMeansSystem(field: String) throws {
        #expect(try TrustedCertificateFile.serverTrust(for: field) == ServerTrust.system)
    }

    @Test("A certificate file becomes the only root")
    func fileBecomesOnlyRoot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-trust-\(UUID().uuidString).pem")
        try Data(Self.fixture.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) } // silent: best-effort cleanup of a temporary file

        // Padded, as a pasted path often is.
        let trust = try TrustedCertificateFile.serverTrust(for: "  \(url.path)\n")

        #expect(trust.usesSystemRoots == false)
        #expect(trust.rootFingerprints == [Self.fixtureFingerprint])
    }

    /// A path that names nothing must stop the connection. Falling back to the system roots
    /// would connect to a public server the user believed they had restricted.
    @Test("A file that cannot be read is an error, not a fallback")
    func unreadableFileThrows() {
        let path = "/nonexistent/explorer-trust-\(UUID().uuidString).pem"
        #expect(throws: ServerTrustError.unreadable(.pemFile(path))) {
            _ = try TrustedCertificateFile.serverTrust(for: path)
        }
    }
}
