import Foundation
import Testing
@testable import MCPClient

/// How long a dynamic client registration is good for.
///
/// RFC 7591 lets a server put `client_secret_expires_at` on a registration response, and
/// `ClientRegistrationResponse` does not model it — so a registration that expires does so
/// invisibly, and the first evidence is a refresh failing `invalid_client` long after the
/// sign-in that would explain it. Reading it off the raw response is the difference between
/// predicting that and being surprised by it.
@Suite("Registration lifetime")
struct RegistrationLifetimeTests {

    /// The ordinary case for a server that does expire secrets: seconds since the epoch.
    @Test("An expiry timestamp is read as a date")
    func readsExpiryTimestamp() throws {
        let json = Data(#"{"client_id":"abc","client_secret_expires_at":1767225600}"#.utf8)

        #expect(RegistrationLifetime.expiry(from: json)
                == .at(Date(timeIntervalSince1970: 1_767_225_600)))
    }

    /// RFC 7591 §3.2.1: zero means the secret does not expire. Distinct from the field being
    /// absent, and the distinction is the whole point — one is a promise, the other is silence.
    @Test("Zero means the secret never expires")
    func zeroMeansNever() throws {
        let json = Data(#"{"client_id":"abc","client_secret_expires_at":0}"#.utf8)

        #expect(RegistrationLifetime.expiry(from: json) == .never)
    }

    /// A server that says nothing has not promised anything. Reported as unspecified rather
    /// than as "never", which would be inventing a guarantee on the server's behalf.
    @Test("An absent field is unspecified, not never")
    func absentIsUnspecified() throws {
        let json = Data(#"{"client_id":"abc"}"#.utf8)

        #expect(RegistrationLifetime.expiry(from: json) == .unspecified)
    }

    /// Diagnostics must not throw. A body this cannot read still registered a client
    /// successfully, and failing the sign-in over an unreadable *note* would be absurd.
    @Test("An unreadable body is unspecified rather than an error")
    func unreadableIsUnspecified() throws {
        #expect(RegistrationLifetime.expiry(from: Data("not json".utf8)) == .unspecified)
        #expect(RegistrationLifetime.expiry(from: Data()) == .unspecified)
    }

    /// A non-numeric value is a server sending something the RFC does not describe. Read as
    /// unspecified rather than coerced into a date nobody can defend.
    @Test("A non-numeric expiry is unspecified")
    func nonNumericIsUnspecified() throws {
        let json = Data(#"{"client_secret_expires_at":"soon"}"#.utf8)

        #expect(RegistrationLifetime.expiry(from: json) == .unspecified)
    }

    /// The description is what reaches a log, so it has to distinguish the three cases in
    /// words rather than printing an enum case name that means nothing to whoever reads it.
    @Test("Each case describes itself distinctly")
    func descriptionsAreDistinct() throws {
        let descriptions = [
            RegistrationLifetime.Expiry.unspecified.description,
            RegistrationLifetime.Expiry.never.description,
            RegistrationLifetime.Expiry.at(Date(timeIntervalSince1970: 1_767_225_600)).description
        ]

        #expect(Set(descriptions).count == 3)
        #expect(descriptions[0].contains("did not say"))
        #expect(descriptions[1].contains("never"))
    }
}
