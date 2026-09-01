import Foundation

/// How long a dynamic client registration is good for, read off the raw response.
///
/// RFC 7591 §3.2.1 lets a server return `client_secret_expires_at` when it registers a client.
/// SwiftOAuth's `ClientRegistrationResponse` does not model it, so the value is otherwise
/// discarded at the one moment it is available — and a registration that expires then does so
/// invisibly. The first evidence is a refresh failing `invalid_client` weeks later, at which
/// point nothing connects the failure to the sign-in that caused it.
///
/// Diagnostic only. Nothing here changes what the client does; it changes what it can say
/// afterwards, which for a value observable exactly once is most of what matters.
enum RegistrationLifetime {

    /// What a server said about its client secret's lifetime.
    enum Expiry: Equatable, Sendable, CustomStringConvertible {

        /// The server said nothing. Not a promise that the secret lasts — just silence.
        case unspecified

        /// The server said zero, which RFC 7591 defines as never expiring.
        case never

        /// The server named a moment.
        case at(Date)

        /// A phrase for a log, distinguishing the three cases in words.
        ///
        /// The distinction that matters is `unspecified` against `never`: one is a server
        /// promising the secret outlives everything, the other is a server that has promised
        /// nothing at all, and an enum case name in a log conveys neither.
        var description: String {
            switch self {
            case .unspecified:
                return "the server did not say when the client secret expires"
            case .never:
                return "the client secret never expires"
            case .at(let date):
                return "the client secret expires at \(date.formatted(.iso8601))"
            }
        }
    }

    /// Reads the expiry from a registration response body.
    ///
    /// Never throws. A body this cannot read still registered a client successfully, and
    /// failing a sign-in over an unreadable diagnostic would trade a working session for a
    /// note nobody asked for.
    ///
    /// - Parameter data: The raw JSON the registration endpoint returned.
    /// - Returns: What the server said, or ``Expiry/unspecified`` if it said nothing readable.
    static func expiry(from data: Data) -> Expiry {
        // An unreadable body is the `unspecified` result rather than an error: the
        // registration itself succeeded, and this only reads a note it left behind.
        // silent: an unreadable body is `unspecified`; the registration already succeeded
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              // `NSNumber` rather than `Int`: JSONSerialization boxes every number, and a
              // server sending `0.0` is still saying zero.
              let seconds = fields["client_secret_expires_at"] as? NSNumber else {
            return .unspecified
        }

        let value = seconds.doubleValue
        guard value != 0 else { return .never }
        return .at(Date(timeIntervalSince1970: value))
    }
}
