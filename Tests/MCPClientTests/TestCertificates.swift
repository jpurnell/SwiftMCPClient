import Foundation
import Crypto
import NIOSSL
import SwiftASN1
import X509

/// A certificate minted for one test run, with the key that goes with it.
///
/// Generated rather than checked in. A fixture would mean a private key in the repository,
/// and one with an expiry date — a suite that goes red on a calendar day nobody remembers
/// choosing. These are valid for an hour around the moment they are made.
struct TestIdentity {

    /// The certificate, DER-encoded.
    let der: [UInt8]

    /// The certificate, PEM-encoded.
    let pem: String

    /// The private key, PEM-encoded. Only a server ever needs this.
    let keyPEM: String

    /// A self-signed certificate naming the loopback address.
    ///
    /// - Parameters:
    ///   - commonName: The subject, and — being self-signed — the issuer.
    ///   - names: The subject alternative names. Defaults to what the loopback stub servers
    ///     are reached by, `127.0.0.1`; a test of hostname checking passes something else.
    ///   - isAuthority: Whether the certificate claims to be a CA. A self-signed server
    ///     certificate made by hand usually does not, so both shapes have to be trusted.
    /// - Returns: The identity.
    /// - Throws: If the certificate cannot be built or serialized.
    static func selfSigned(
        commonName: String = "SwiftMCPClient test server",
        names: [GeneralName] = TestIdentity.loopbackNames,
        isAuthority: Bool = false
    ) throws -> TestIdentity {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(commonName) }
        return try issue(
            subject: name, subjectKey: key, issuer: name, issuerKey: key,
            names: names, isAuthority: isAuthority)
    }

    /// A private certificate authority and a server certificate it signed.
    ///
    /// - Returns: The authority, which a client is told to trust, and the leaf, which the
    ///   server presents. The client never sees the leaf ahead of time.
    /// - Throws: If either certificate cannot be built or serialized.
    static func authorityAndLeaf() throws -> (authority: TestIdentity, leaf: TestIdentity) {
        let authorityKey = P256.Signing.PrivateKey()
        let authorityName = try DistinguishedName { CommonName("SwiftMCPClient test CA") }
        let authority = try issue(
            subject: authorityName, subjectKey: authorityKey,
            issuer: authorityName, issuerKey: authorityKey,
            names: [], isAuthority: true)

        let leafKey = P256.Signing.PrivateKey()
        let leaf = try issue(
            subject: try DistinguishedName { CommonName("SwiftMCPClient test leaf") },
            subjectKey: leafKey, issuer: authorityName, issuerKey: authorityKey,
            names: loopbackNames, isAuthority: false)
        return (authority, leaf)
    }

    /// The names the loopback stub servers answer to.
    static let loopbackNames: [GeneralName] = [
        .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
        .dnsName("localhost"),
    ]

    /// A server-side TLS context presenting this identity.
    ///
    /// - Returns: The context.
    /// - Throws: If the certificate or key does not load.
    func serverContext() throws -> NIOSSLContext {
        let certificate = try NIOSSLCertificate(bytes: der, format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(key))
        return try NIOSSLContext(configuration: configuration)
    }

    /// Writes `bytes` to a fresh file in the temporary directory.
    ///
    /// - Parameters:
    ///   - bytes: What to write.
    ///   - fileExtension: The extension, without the dot.
    /// - Returns: The path.
    /// - Throws: If the file cannot be written.
    static func temporaryFile(_ bytes: [UInt8], fileExtension: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-trust-\(UUID().uuidString).\(fileExtension)")
        try Data(bytes).write(to: url)
        return url.path
    }

    private static func issue(
        subject: DistinguishedName,
        subjectKey: P256.Signing.PrivateKey,
        issuer: DistinguishedName,
        issuerKey: P256.Signing.PrivateKey,
        names: [GeneralName],
        isAuthority: Bool
    ) throws -> TestIdentity {
        let now = Date()
        let extensions = try Certificate.Extensions {
            if isAuthority {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
            } else {
                Critical(BasicConstraints.notCertificateAuthority)
            }
            if !names.isEmpty {
                SubjectAlternativeNames(names)
                // Apple's verifier refuses a TLS server certificate without this, and a
                // certificate made for a server ought to say so anyway.
                try ExtendedKeyUsage([.serverAuth])
            }
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(subjectKey.publicKey),
            notValidBefore: now.addingTimeInterval(-1800),
            notValidAfter: now.addingTimeInterval(1800),
            issuer: issuer,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(issuerKey))

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return TestIdentity(
            der: serializer.serializedBytes,
            pem: try certificate.serializeAsPEM().pemString,
            keyPEM: subjectKey.pemRepresentation)
    }
}
