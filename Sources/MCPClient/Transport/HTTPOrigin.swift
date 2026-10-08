import Foundation
import Logging

/// The origin of an HTTP URL: how two are compared, and how one is named.
///
/// A transport is configured with one URL, and that URL's origin — scheme, host and port — is
/// the only place it has been told it may send anything. Twice a server gets to suggest
/// somewhere else: the legacy `endpoint` event, and the `Location` of a redirect. Both are
/// resolved as URL references, so both can name another host outright, and both are held to
/// the configured origin by the one function here rather than by a comparison written twice.
///
/// The other half is what may be *said* about a URL. An error message and a log line outlive
/// the request and are read by people the request was never meant for, so a URL reaches them
/// only through ``description(of:)`` or ``redacted(_:)``.
enum HTTPOrigin {

    /// What a server-supplied reference came to, measured against the configured URL.
    enum Resolution: Sendable, Equatable {
        /// On the configured origin. The URL is absolute and has no fragment.
        case sameOrigin(URL)
        /// It brings userinfo of its own. Refused even on the right host: nothing needs it,
        /// and `good.example@evil.test` is how a URL is made to read as one host and reach
        /// another.
        case carriesUserinfo(origin: String)
        /// On another origin — another scheme, host or port, or no HTTP origin at all.
        case otherOrigin(origin: String)
        /// Not something a URL could be made from.
        case notAURL
    }

    /// Resolves a reference a server supplied, and says whether it stays on the configured
    /// origin.
    ///
    /// The reference is resolved as RFC 3986 says, so it is not necessarily a path: an
    /// absolute URL replaces the whole origin, and so does `//host/path`. What it resolves to
    /// is then compared with `configured`:
    ///
    /// - **Same scheme, host and effective port.** Compared as parsed components, never as
    ///   string prefixes; scheme and host case-insensitively; a port left out is the scheme's
    ///   default. `http` where `https` was configured is a different origin — and so is the
    ///   reverse, because an origin is not "at least as secure as".
    /// - **No userinfo of its own.** Userinfo the configured URL already carried is kept by a
    ///   relative reference and is the caller's own; anything else is refused.
    /// - **No fragment.** Dropped, not refused: it is never sent in a request.
    ///
    /// A relative reference cannot fail the first of these — `..` stops at the root of the
    /// origin — so a server that sends a path, as almost all do, sees no difference.
    ///
    /// - Parameters:
    ///   - reference: The value as the server sent it: an `endpoint` event's data, or a
    ///     `Location` header.
    ///   - base: The URL it is relative to — the one whose response carried it.
    ///   - configured: The URL the transport was created with, whose origin is the limit.
    /// - Returns: The resolved URL if it may be used, or why it may not.
    static func resolve(_ reference: String, relativeTo base: URL, heldTo configured: URL) -> Resolution {
        guard let resolved = URL(string: reference, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return .notAURL
        }
        components.fragment = nil

        // Re-read from the string, because the string is what the HTTP client is handed. A
        // check made on one parse and a request made from another is the gap this closes.
        guard let text = components.string, let destination = URL(string: text) else {
            return .notAURL
        }
        let named = description(of: destination)

        let bringsUserinfo = destination.user != nil || destination.password != nil
        let isTheCallersOwn = destination.user == configured.user && destination.password == configured.password
        guard !bringsUserinfo || isTheCallersOwn else {
            return .carriesUserinfo(origin: named)
        }

        // The origin, component by component. Each side is parsed; nothing here is a prefix
        // or a substring test, so `good.example.evil.test` is simply a different host.
        guard let expectedScheme = configured.scheme?.lowercased(),
              let expectedHost = configured.host?.lowercased(), !expectedHost.isEmpty,
              let expectedPort = effectivePort(of: configured),
              destination.scheme?.lowercased() == expectedScheme,
              destination.host?.lowercased() == expectedHost,
              effectivePort(of: destination) == expectedPort else {
            return .otherOrigin(origin: named)
        }
        return .sameOrigin(destination)
    }

    /// The port a URL's requests go to: the one it names, else its scheme's default.
    ///
    /// - Parameter url: An absolute URL.
    /// - Returns: `nil` unless the scheme is `http` or `https` — nothing else is a place an
    ///   HTTP transport can send to, so nothing else has a port worth comparing.
    static func effectivePort(of url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return url.port ?? 443
        case "http": return url.port ?? 80
        default: return nil
        }
    }

    /// Whether a redirect is the same host asking for `https` where `http` was configured.
    ///
    /// Not followed either way — an origin is not "at least as secure as" — but worth telling
    /// apart, because the caller's mistake and its remedy are both specific: the configured
    /// URL is plaintext, and the `https` one should be configured instead.
    ///
    /// - Parameters:
    ///   - configured: The URL the transport was created with.
    ///   - origin: The destination's origin, as ``description(of:)`` names it.
    /// - Returns: `true` only for `http` → `https` with the host unchanged.
    static func isUpgrade(from configured: URL, toOrigin origin: String) -> Bool {
        guard configured.scheme?.lowercased() == "http",
              let expectedHost = configured.host?.lowercased(), !expectedHost.isEmpty,
              let destination = URL(string: origin),
              destination.scheme?.lowercased() == "https",
              destination.host?.lowercased() == expectedHost else {
            return false
        }
        return true
    }

    /// Whether whatever is sent to a URL crosses a network unencrypted.
    ///
    /// None of the network transports refuses a plaintext URL. `http://` and `ws://` are how
    /// a server on loopback or a private network is reached, and ``ServerTrust`` decides
    /// which certificate an `https` or `wss` server may present, not whether there is one.
    /// What they do, all three alike, is warn once when a credential is configured and this
    /// is `true`.
    ///
    /// - Parameter url: The URL a transport was configured with.
    /// - Returns: `true` for `http` or `ws` to any host but this machine — `localhost`, an
    ///   address in `127.0.0.0/8`, or `::1`. Compared as a parsed host, so
    ///   `localhost.evil.test` is not loopback.
    static func isPlaintextToRemote(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "ws" else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard host != "localhost", host != "::1" else { return false }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return !(isIPv4 && octets.first == "127")
    }


    /// Warns, once per connect, that configured credentials are about to cross a network
    /// unencrypted.
    ///
    /// The same line from all three network transports, so that "is this deployment sending
    /// a token in the clear" has one thing to search a log for.
    ///
    /// - Parameters:
    ///   - url: The URL the transport was configured with.
    ///   - carriesCredentials: Whether any header or an `authorization:` provider is
    ///     configured. Every custom header counts: an API key travels in one as often as in
    ///     `Authorization`.
    ///   - label: The transport's logger label.
    static func warnIfPlaintextToRemote(_ url: URL, carriesCredentials: Bool, label: String) {
        guard carriesCredentials, isPlaintextToRemote(url) else { return }
        let logger = Logger(label: label)
        // logging: swift-log has no privacy annotations; an origin only — no path, query, userinfo or header
        logger.warning("sending configured headers to \(description(of: url)) unencrypted; use an https:// or wss:// URL for a server on another machine")
    }

    /// What is said of a URL that has no origin to name.
    static let noOrigin = "(no origin)"

    /// `scheme://host[:port]` — the most an error or a log line says about a URL a *server*
    /// chose.
    ///
    /// Userinfo, path and query are left out on purpose: the first is a credential, and the
    /// rest is whatever the server wanted written into the caller's logs.
    ///
    /// - Parameter url: The URL to name.
    /// - Returns: Its origin, or ``noOrigin`` if it has no host.
    static func description(of url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return noOrigin
        }
        let authority = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port else { return "\(scheme)://\(authority)" }
        return "\(scheme)://\(authority):\(port)"
    }

    /// What stands in for a path segment that might be a credential.
    ///
    /// Made of characters a URL path does not have to escape, so the redacted URL is still a
    /// URL, and of a shape no real segment has.
    static let redactedSegment = "-redacted-"

    /// A URL with everything that can carry a secret taken off: no userinfo, no query, no
    /// fragment, and no path segment that could be a credential.
    ///
    /// What an error or a log line says about a URL the *caller* is using.
    ///
    /// - **Userinfo** goes: it is a credential by definition.
    /// - **The query** goes, whole: on a legacy HTTP+SSE endpoint it is usually the session
    ///   id, and on a configured URL it is where an API key ends up when a server documents
    ///   `?key=…`.
    /// - **The fragment** goes.
    /// - **The path** is kept segment by segment, because "which endpoint failed" is the
    ///   useful part — but a deployment can put its key there too (`/mcp/<key>/sse`), so each
    ///   segment that ``couldBeCredential(_:)`` is replaced with ``redactedSegment``.
    /// - **Scheme, host and port** stay. They are the origin, and an error that does not say
    ///   which server it is about is not worth having.
    ///
    /// - Parameter url: The URL to describe.
    /// - Returns: The redacted URL, or `nil` if it cannot be taken apart at all.
    static func redactedURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                // A segment that will not decode is not one that can be vouched for.
                guard let decoded = String(segment).removingPercentEncoding,
                      !couldBeCredential(decoded) else {
                    return redactedSegment
                }
                return String(segment)
            }
            .joined(separator: "/")
        return components.url
    }

    /// The longest a path segment may be and still be kept.
    static let longestOrdinarySegment = 32

    /// The longest run of letters taken for a word.
    static let longestWord = 16

    /// Whether a path segment could be a credential, and so is left out of error text.
    ///
    /// The question is asked the safe way round. Nothing can recognise every key, so this
    /// recognises what an *ordinary* segment looks like — `mcp`, `sse`, `messages`, `v1`,
    /// `.well-known`, `oauth-protected-resource`, `2025-06-18` — and treats everything else
    /// as a possible credential. A segment is ordinary only if **all** of these hold:
    ///
    /// 1. It is at most ``longestOrdinarySegment`` characters.
    /// 2. It uses only ASCII letters, digits, `-`, `_`, `.` and `~`.
    /// 3. Split at `-`, `_`, `.` and `~`, every piece is one of:
    ///    - a **word**: letters only, at most ``longestWord`` of them, with no more than two
    ///      capitals after its first letter unless it is capitals throughout (`messages`,
    ///      `getToolsList`, `MCP`);
    ///    - a **small number**: one to four digits (`42`, `2025`);
    ///    - a **word and a version**: a word of at most eight letters followed by one to three
    ///      digits (`v1`, `oauth2`).
    ///
    /// So a UUID, a run of hex, a JWT, anything base64, a prefixed key such as
    /// `sk-live-abc123`, a long number, and any segment mixing letters and digits freely are
    /// all redacted — as is anything with a character outside that set once percent-decoded.
    ///
    /// **What this does not catch:** a credential that *is* a few short words —
    /// `/mcp/correct-horse/sse`, or a key that happens to be eight lowercase letters — is
    /// indistinguishable from a path and is kept. And only the path is examined: a key in the
    /// host name (`https://<key>.mcp.example`) is part of the origin, and stays. A deployment
    /// that needs its URL kept out of logs entirely should carry the key in a header.
    ///
    /// - Parameter segment: One path segment, percent-decoded.
    /// - Returns: `true` if it is replaced in error and log text.
    static func couldBeCredential(_ segment: String) -> Bool {
        guard !segment.isEmpty else { return false }
        guard segment.count <= longestOrdinarySegment else { return true }

        let separators: Set<Character> = ["-", "_", ".", "~"]
        guard segment.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || separators.contains($0) }) else {
            return true
        }
        return !segment
            .split(omittingEmptySubsequences: true) { separators.contains($0) }
            .allSatisfy(isOrdinaryPiece)
    }

    /// Whether one piece of a segment is a word, a small number, or a word and a version.
    private static func isOrdinaryPiece(_ piece: Substring) -> Bool {
        let letters = piece.prefix { $0.isLetter }
        let digits = piece[letters.endIndex...]
        guard digits.allSatisfy(\.isNumber) else { return false }

        if letters.isEmpty { return digits.count <= 4 }
        guard isWord(letters) else { return false }
        return digits.isEmpty || (letters.count <= 8 && digits.count <= 3)
    }

    /// Whether a run of letters reads as a word rather than as key material.
    private static func isWord(_ letters: Substring) -> Bool {
        guard letters.count <= longestWord else { return false }
        let capitals = letters.dropFirst().filter(\.isUppercase).count
        return capitals <= 2 || letters.allSatisfy(\.isUppercase)
    }

    /// ``redactedURL(_:)`` as text, for a message.
    ///
    /// - Parameter url: The URL to describe.
    /// - Returns: Origin and redacted path, or ``noOrigin`` if the URL cannot be taken apart.
    ///   Never the original string: a fallback that printed what it could not redact would
    ///   be the leak.
    static func redacted(_ url: URL) -> String {
        redactedURL(url)?.absoluteString ?? noOrigin
    }
}
