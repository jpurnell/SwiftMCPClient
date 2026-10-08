import Foundation
import AsyncHTTPClient
import Crypto
import NIOCore
import NIOPosix
import NIOSSL

/// What a transport is prepared to believe about the server it is talking to.
///
/// Every network transport takes one of these, and there are exactly three things it can say:
///
/// - ``system`` — the platform's root store, which is the default and what a publicly
///   certified server needs.
/// - ``additionalRoots(_:)`` — the platform's root store *and* certificates you supply.
/// - ``onlyRoots(_:)`` — the certificates you supply and nothing else.
///
/// What it cannot say is "do not verify". In all three the certificate chain is validated and
/// the certificate is checked against the host being connected to; a supplied root changes
/// *who is allowed to have signed* the server's certificate, never *whether* that is checked.
///
/// ## Trusting a self-signed server
///
/// A self-signed certificate is its own issuer, so trusting it means supplying it as a root:
///
/// ```swift
/// func selfSignedTransport(url: URL) throws -> StreamableHTTPTransport {
///     let trust = try ServerTrust.onlyRoots([.pemFile("/etc/mcp/dev-server.pem")])
///     return StreamableHTTPTransport(url: url, serverTrust: trust)
/// }
/// ```
///
/// With ``onlyRoots(_:)`` that is also a pin: the server must present a chain ending at that
/// exact certificate, and a different self-signed certificate — which is all an interposed
/// attacker can offer — is refused.
///
/// ## Trusting a private certificate authority
///
/// Supply the authority's certificate. Any server certificate it issued is then trusted for
/// the names that certificate carries:
///
/// ```swift
/// func privateAuthorityTrust(rootPEM: String) throws -> ServerTrust {
///     try ServerTrust.additionalRoots([.pem(rootPEM)])
/// }
/// ```
///
/// ## The hostname still has to match
///
/// A development certificate has to name the host it is reached by, as a subject alternative
/// name — a DNS name for `https://dev.internal`, an IP address for `https://127.0.0.1`. A
/// certificate that names neither is refused however it is trusted. That is deliberate: a
/// root you trust says who signed the certificate, and the name says who it was signed *for*.
///
/// ## Why there is no hash pin
///
/// Pinning by the SHA-256 of a certificate or public key needs a verification callback, and
/// neither `AsyncHTTPClient` nor `WebSocketKit` lets a caller install one — and NIOSSL's
/// callback *replaces* chain validation rather than adding to it. A pin that some transports
/// could not enforce would be worse than none, so this type offers only what all three can
/// honour. ``onlyRoots(_:)`` with the server's own certificate is the pin; and
/// ``rootFingerprints`` is there so an application can show, or compare, exactly what it has
/// been told to trust.
public struct ServerTrust: Sendable, Hashable {

    /// Where a trusted certificate comes from.
    public enum CertificateSource: Sendable, Hashable {
        /// PEM text holding one or more certificates.
        case pem(String)
        /// One DER-encoded certificate.
        case der([UInt8])
        /// The path of a PEM file holding one or more certificates.
        case pemFile(String)
        /// The path of a file holding one DER-encoded certificate.
        case derFile(String)
    }

    /// Whether the platform's root store is consulted.
    ///
    /// `false` only for ``onlyRoots(_:)``, where a certificate signed by a public authority
    /// is refused like any other the caller did not name.
    public let usesSystemRoots: Bool

    /// The SHA-256 of each supplied root's DER encoding, as lowercase hex, in the order the
    /// roots were supplied.
    ///
    /// Empty for ``system``. This is the same value `openssl x509 -fingerprint -sha256`
    /// prints, without the colons — so what an application trusts can be shown to a person
    /// and compared against what they expected.
    public let rootFingerprints: [String]

    /// The parsed roots. Parsed once, when the value is made, so that nothing about what is
    /// trusted is left to be discovered at connect time.
    private let roots: [NIOSSLCertificate]

    private init(usesSystemRoots: Bool, roots: [NIOSSLCertificate], rootFingerprints: [String]) {
        self.usesSystemRoots = usesSystemRoots
        self.roots = roots
        self.rootFingerprints = rootFingerprints
    }

    /// Trust the platform's root store, and nothing else.
    ///
    /// The default for every transport, and the right answer for any server with a
    /// certificate from a public authority.
    public static let system = ServerTrust(usesSystemRoots: true, roots: [], rootFingerprints: [])

    /// Trust the platform's root store and the supplied certificates.
    ///
    /// For a client that talks to public servers and to ones behind a private authority.
    /// Prefer ``onlyRoots(_:)`` when the transport will only ever reach the private one.
    ///
    /// - Parameter sources: The certificates to add. Read and parsed before this returns.
    /// - Returns: The trust.
    /// - Throws: ``ServerTrustError/noCertificates`` if `sources` is empty, or
    ///   ``ServerTrustError/unreadable(_:)`` naming the first source that held no certificate.
    public static func additionalRoots(_ sources: [CertificateSource]) throws -> ServerTrust {
        try make(usesSystemRoots: true, sources: sources)
    }

    /// Trust the supplied certificates and nothing else.
    ///
    /// The server's chain must end at one of them. Supplying a self-signed server's own
    /// certificate pins the connection to that certificate.
    ///
    /// - Parameter sources: The only certificates to trust. Read and parsed before this
    ///   returns.
    /// - Returns: The trust.
    /// - Throws: ``ServerTrustError/noCertificates`` if `sources` is empty, or
    ///   ``ServerTrustError/unreadable(_:)`` naming the first source that held no certificate.
    public static func onlyRoots(_ sources: [CertificateSource]) throws -> ServerTrust {
        try make(usesSystemRoots: false, sources: sources)
    }

    /// The NIOSSL client configuration this trust amounts to.
    ///
    /// The one place in the package a client `TLSConfiguration` is built. Verification is
    /// whatever `makeClientConfiguration()` set — chain and hostname — and nothing here
    /// touches it; the only fields written are the two that say which roots to verify against.
    func makeTLSConfiguration() -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        guard !roots.isEmpty else { return configuration }
        if usesSystemRoots {
            configuration.additionalTrustRoots = [.certificates(roots)]
        } else {
            configuration.trustRoots = .certificates(roots)
        }
        return configuration
    }

    /// An HTTP client that verifies servers against this trust.
    ///
    /// Shared by both HTTP transports, so there is one answer to "what does a request
    /// verify against" rather than one per transport.
    ///
    /// Supplied roots are always enforced by NIOSSL. On Apple platforms `AsyncHTTPClient`
    /// otherwise runs on Network.framework and *translates* a `TLSConfiguration` for it, and
    /// that translation does not carry `additionalTrustRoots` at all — so the configuration
    /// would say one thing and the connection would verify against another. Running on NIO's
    /// own event loops makes the configuration built above the one that is enforced, and
    /// makes it the same one on macOS and Linux. ``system`` keeps the platform's stack.
    ///
    /// The client does **not** follow redirects. `AsyncHTTPClient` follows them to any
    /// origin when asked to follow at all, so the transports ask it not to and follow the
    /// same-origin ones themselves, through ``SameOriginRedirects``. A request made on this
    /// client by any other route gets a `3xx` back as the answer.
    ///
    /// - Parameter connectTimeout: How long a connection attempt may take.
    /// - Returns: The client. The caller owns it and must shut it down.
    func makeHTTPClient(connectTimeout: TimeAmount) -> HTTPClient {
        var configuration = HTTPClient.Configuration(tlsConfiguration: makeTLSConfiguration())
        configuration.timeout.connect = connectTimeout
        configuration.redirectConfiguration = .disallow
        guard !roots.isEmpty else {
            return HTTPClient(configuration: configuration)
        }
        return HTTPClient(
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            configuration: configuration)
    }

    // MARK: - Loading

    private static func make(usesSystemRoots: Bool, sources: [CertificateSource]) throws -> ServerTrust {
        // An empty list is refused rather than interpreted. Under `onlyRoots` it would be a
        // client that trusts nothing; under `additionalRoots` it would quietly mean `.system`.
        guard !sources.isEmpty else { throw ServerTrustError.noCertificates }

        var roots: [NIOSSLCertificate] = []
        var fingerprints: [String] = []
        for source in sources {
            // All or nothing: a subset of the roots someone asked for is a different trust
            // decision from the one they made.
            let loaded = try load(source)
            guard !loaded.isEmpty else { throw ServerTrustError.unreadable(source) }
            for certificate in loaded {
                fingerprints.append(try fingerprint(of: certificate, from: source))
                roots.append(certificate)
            }
        }
        return ServerTrust(usesSystemRoots: usesSystemRoots, roots: roots, rootFingerprints: fingerprints)
    }

    private static func load(_ source: CertificateSource) throws -> [NIOSSLCertificate] {
        do {
            switch source {
            case .pem(let text):
                return try NIOSSLCertificate.fromPEMBytes(Array(text.utf8))
            case .der(let bytes):
                return [try NIOSSLCertificate(bytes: bytes, format: .der)]
            case .pemFile(let path):
                return try NIOSSLCertificate.fromPEMFile(path)
            case .derFile(let path):
                return [try NIOSSLCertificate.fromDERFile(path)]
            }
        } catch {
            // The underlying error is BoringSSL's and says little a caller can act on; which
            // source it was is the useful part, and the error carries it.
            throw ServerTrustError.unreadable(source)
        }
    }

    private static func fingerprint(
        of certificate: NIOSSLCertificate,
        from source: CertificateSource
    ) throws -> String {
        let der: [UInt8]
        do {
            der = try certificate.toDERBytes()
        } catch {
            throw ServerTrustError.unreadable(source)
        }
        return SHA256.hash(data: der).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}

/// Why a ``ServerTrust`` could not be made.
///
/// Thrown when the trust is constructed, not when a transport connects — a certificate that
/// cannot be read is a mistake in configuration, and it is reported where the configuration
/// is written. Nothing falls back to ``ServerTrust/system``.
public enum ServerTrustError: Error, Sendable, Equatable {
    /// No certificate sources were supplied.
    case noCertificates

    /// A source did not yield a certificate: the text or bytes did not parse, the file could
    /// not be read, or it held none.
    ///
    /// - Parameter source: The source that failed.
    case unreadable(ServerTrust.CertificateSource)
}

extension ServerTrustError: CustomStringConvertible {
    /// A description suitable for a log line or an error alert.
    public var description: String {
        switch self {
        case .noCertificates:
            return "No certificates were supplied to trust."
        case .unreadable(.pem):
            return "The supplied PEM text holds no readable certificate."
        case .unreadable(.der):
            return "The supplied DER bytes are not a certificate."
        case .unreadable(.pemFile(let path)):
            return "No certificate could be read from the PEM file at \(path)."
        case .unreadable(.derFile(let path)):
            return "No certificate could be read from the DER file at \(path)."
        }
    }
}
