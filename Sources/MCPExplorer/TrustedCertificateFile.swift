import Foundation
import MCPClient

/// Turns the connection form's "trusted certificate" field into what a transport is given.
///
/// The field replaces a toggle that read "Trust self-signed certificates" and switched
/// certificate verification off. Naming a file is the honest form of the same wish: the
/// server's certificate — or the private authority that issued it — is what gets trusted, and
/// the chain and hostname are checked as they are for any other server.
enum TrustedCertificateFile {

    /// The trust a connection should be made with.
    ///
    /// - Parameter field: What is in the form field: a path to a PEM file, or nothing.
    /// - Returns: ``ServerTrust/system`` for an empty field; otherwise trust in the
    ///   certificates in that file and in nothing else, so a field left filled in cannot
    ///   quietly widen what a public server is checked against.
    /// - Throws: ``ServerTrustError`` if a path was given and no certificate could be read
    ///   from it. The connection is not attempted.
    static func serverTrust(for field: String) throws -> ServerTrust {
        let path = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .system }
        return try .onlyRoots([.pemFile(path)])
    }
}
