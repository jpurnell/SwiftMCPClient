import Foundation
import Testing
import Crypto
import SwiftOAuthClient
@testable import MCPClient

/// Where a dynamic client registration is kept between launches.
///
/// The registration is the half of a signed-in session that was never persisted, and its
/// absence is not recoverable by repeating the work: a refresh token is bound to the
/// `client_id` that obtained it (RFC 6749 §6), so registering again orphans the credential
/// that is already on file. That is what these tests are protecting — a record that survives
/// a restart, and a store that says so plainly when it cannot be read rather than reporting
/// the file as empty.
@Suite("Registration record store")
struct RegistrationRecordStoreTests {

    /// The one that matters: a record written by one process is readable by the next.
    ///
    /// Two instances over the same file and key, because a single instance answering from its
    /// own cache would pass this while a fresh launch found nothing.
    @Test("A record written on one launch is read on the next")
    func roundTripsAcrossInstances() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }
        let key = freshKeyBytes()

        let written = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        try await written.store(registration(), for: connection())

        let read = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        let restored = try await read.record(for: connection())

        #expect(restored == registration(), "the registration did not survive a restart")
    }

    /// First run. Nothing stored is `nil`, not an error — a caller seeing this offers sign-in.
    @Test("An empty store reports nothing rather than failing")
    func absentRecordIsNil() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: freshKeyBytes()))

        #expect(try await store.record(for: connection()) == nil)
    }

    /// Records are per connection. Signing in to a second server must not hand back the
    /// first server's `client_id`, which would present the wrong client at the token endpoint.
    @Test("A record for one connection is not returned for another")
    func recordsAreKeyedByConnection() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: freshKeyBytes()))
        try await store.store(registration(), for: connection())

        let other = ConnectionID(
            tenant: "local", provider: "other.example.com", account: "https://other.example.com")
        #expect(try await store.record(for: other) == nil)
    }

    /// Signing in again replaces the record rather than accumulating one per launch — the
    /// stored credential belongs to the newest registration, and an older `client_id` would
    /// refresh as `invalid_client`.
    @Test("Storing again replaces the previous record")
    func storingReplacesPreviousRecord() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }
        let key = freshKeyBytes()

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        try await store.store(registration(), for: connection())
        try await store.store(registration(clientId: "client-2"), for: connection())

        let read = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        let restored = try await read.record(for: connection())

        #expect(restored?.clientId == "client-2")
    }

    /// Signing out has to be able to forget the registration too. Leaving it behind means the
    /// next resume rebuilds a connection whose credential is gone.
    @Test("A removed record is gone on the next launch")
    func removeForgetsTheRecord() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }
        let key = freshKeyBytes()

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        try await store.store(registration(), for: connection())
        try await store.remove(connection())

        let read = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        #expect(try await read.record(for: connection()) == nil)
    }

    /// Removing what is not there is not an error — a user pressing "sign out" twice should
    /// not see a failure.
    @Test("Removing an absent record is harmless")
    func removingAbsentRecordIsHarmless() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: freshKeyBytes()))
        try await store.remove(connection())

        #expect(try await store.record(for: connection()) == nil)
    }

    /// A truncated file must be named as unreadable, not reported as empty. Empty looks like a
    /// first run, and a first run sends the user to a sign-in that mints a fresh registration
    /// — orphaning the credential still sitting in `credentials.enc`.
    @Test("A truncated file is refused, not read as empty")
    func truncatedFileThrows() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }
        let key = freshKeyBytes()

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        try await store.store(registration(), for: connection())

        let sealed = try Data(contentsOf: file)
        try sealed.prefix(sealed.count / 2).write(to: file, options: [.atomic])

        let reopened = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: key))
        await #expect(throws: StorageError.cannotDecrypt) {
            try await reopened.record(for: connection())
        }
    }

    /// Same reasoning for the wrong key. A key that changed — a Keychain item replaced, a
    /// file copied to another machine — is a broken store, and a caller must be able to tell
    /// that from "you have never signed in".
    @Test("The wrong key is refused, not read as empty")
    func wrongKeyThrows() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: freshKeyBytes()))
        try await store.store(registration(), for: connection())

        let other = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: freshKeyBytes()))
        await #expect(throws: StorageError.cannotDecrypt) {
            try await other.record(for: connection())
        }
    }

    /// The whole point of sealing the file. A `client_secret` readable in the bytes on disk
    /// would make this store a plaintext secret store with extra steps.
    @Test("Nothing readable is written to disk")
    func fileRevealsNothing() async throws {
        let file = try temporaryFile()
        defer { removeFile(file) }

        let store = try EncryptedFileRegistrationStore(url: file, key: SymmetricKey(data: freshKeyBytes()))
        try await store.store(registration(), for: connection())

        let bytes = try Data(contentsOf: file)
        #expect(bytes.range(of: Data("secret-value".utf8)) == nil, "the client secret is on disk in the clear")
        #expect(bytes.range(of: Data("client-1".utf8)) == nil, "the client id is on disk in the clear")
        #expect(bytes.range(of: Data("mcp.example.com".utf8)) == nil, "which server was connected is readable")
    }

    /// The in-memory double has to behave like the file store for everything a caller can
    /// observe, or tests written against it prove nothing about the real one.
    @Test("The in-memory store round-trips and forgets like the file store")
    func inMemoryStoreMatchesFileBehaviour() async throws {
        let store = InMemoryRegistrationStore()

        #expect(try await store.record(for: connection()) == nil)

        try await store.store(registration(), for: connection())
        #expect(try await store.record(for: connection()) == registration())

        try await store.remove(connection())
        #expect(try await store.record(for: connection()) == nil)
    }
}

// MARK: - Helpers

/// The connection every fixture is filed under.
private func connection() -> ConnectionID {
    ConnectionID(
        tenant: "local", provider: "mcp.example.com", account: "https://mcp.example.com")
}

/// A registration as a server would have issued it.
private func registration(clientId: String = "client-1") -> ClientRegistrationResponse {
    ClientRegistrationResponse(
        clientId: clientId,
        clientSecret: "secret-value",
        clientName: "Test Client",
        redirectUris: ["http://127.0.0.1:49152/callback"])
}

/// Key material for a store, as bytes.
///
/// Bytes rather than a `SymmetricKey`, because a key shared between two stores has to cross an
/// actor boundary twice — and `SymmetricKey` is `Sendable` on Apple platforms but not under
/// swift-crypto on Linux, where passing one to an actor initialiser is a data race. `Data` is
/// `Sendable` everywhere, so the bytes travel and each store builds its own key.
func freshKeyBytes() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes(Data.init)
}

/// A path in a fresh directory, for a file the test will create.
///
/// A directory per test rather than a shared one: the suite runs in parallel, and two tests
/// sealing the same path with different keys would fail each other rather than themselves.
private func temporaryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "RegistrationRecordStoreTests")
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "registrations.enc")
}

/// Removes a test's directory, ignoring a file that was never written.
private func removeFile(_ url: URL) {
    // silent: a test that never wrote the file has nothing to clean up, and a cleanup
    // failure must not be reported as the test failing.
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
