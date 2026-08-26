#if canImport(Security)
import Foundation
import Testing
import Crypto
import Security
@testable import MCPClient

/// The key that every stored credential is sealed with.
///
/// Its failure modes are quiet ones. A key that changes between launches does not report an
/// error — it makes the credential file undecryptable, and the user is asked to sign in again
/// with no explanation. So the tests here are mostly about *not* silently minting a new key.
@Suite("Credential store key")
struct CredentialStoreKeyTests {

    /// First run: there is no key, so one is created and kept.
    @Test("A key is created on first use and stored")
    func createsOnFirstUse() throws {
        let keychain = FakeKeychain()
        let store = CredentialStoreKey(keychain: keychain)

        let key = try store.loadOrCreate()

        #expect(key.bitCount == 256)
        #expect(keychain.items.count == 1, "the key was not persisted")
    }

    /// The one that matters. A second launch must get the *same* key — a new one each time
    /// makes every stored credential unreadable, and that surfaces as an unexplained request
    /// to sign in again rather than as an error anyone can act on.
    @Test("The same key comes back on a later launch")
    func sameKeyOnSecondLaunch() throws {
        let keychain = FakeKeychain()

        let first = try CredentialStoreKey(keychain: keychain).loadOrCreate()
        // A separate instance, as though the process had restarted.
        let second = try CredentialStoreKey(keychain: keychain).loadOrCreate()

        #expect(first == second, "a different key was returned; every credential is now unreadable")
        #expect(keychain.items.count == 1, "a second key was stored over the first")
    }

    /// Two keys generated fresh must differ, or "generation" is not generating anything.
    @Test("Separate keychains get separate keys")
    func separateKeychainsDiffer() throws {
        let first = try CredentialStoreKey(keychain: FakeKeychain()).loadOrCreate()
        let second = try CredentialStoreKey(keychain: FakeKeychain()).loadOrCreate()
        #expect(first != second)
    }

    /// A stored item of the wrong size must be refused rather than replaced. Replacing it
    /// would be the silent path to an unreadable credential file; throwing at least says
    /// which layer failed.
    @Test("A malformed stored key is refused, not replaced")
    func malformedKeyRefused() {
        let keychain = FakeKeychain()
        keychain.items[FakeKeychain.Key(service: CredentialStoreKey.service,
                                        account: CredentialStoreKey.account)] = Data([1, 2, 3])

        let store = CredentialStoreKey(keychain: keychain)
        #expect(throws: CredentialKeyError.malformedKey) {
            try store.loadOrCreate()
        }
        #expect(keychain.items.count == 1, "the malformed item was overwritten")
    }

    /// A keychain that refuses must surface the status. "Keychain failed" is unactionable;
    /// the status is what distinguishes a locked keychain from a missing entitlement.
    @Test("A refusing keychain surfaces its status")
    func refusalSurfacesStatus() {
        let keychain = FakeKeychain()
        keychain.readStatus = errSecInteractionNotAllowed

        #expect(throws: CredentialKeyError.keychain(errSecInteractionNotAllowed)) {
            try CredentialStoreKey(keychain: keychain).loadOrCreate()
        }
    }

    /// A write that fails must throw rather than handing back a key that was never stored —
    /// that key would work for this launch and be gone by the next one.
    @Test("A failed write is reported rather than returning an unstored key")
    func failedWriteReported() {
        let keychain = FakeKeychain()
        keychain.writeStatus = errSecDuplicateItem

        #expect(throws: CredentialKeyError.keychain(errSecDuplicateItem)) {
            try CredentialStoreKey(keychain: keychain).loadOrCreate()
        }
    }

    /// Deleting the key is how a caller discards every credential at once, without having to
    /// reach each one.
    @Test("Deleting the key removes it")
    func deleteRemovesKey() throws {
        let keychain = FakeKeychain()
        let store = CredentialStoreKey(keychain: keychain)

        _ = try store.loadOrCreate()
        #expect(keychain.items.count == 1)

        try store.delete()
        #expect(keychain.items.isEmpty)

        // And the next call mints a fresh one rather than failing.
        _ = try store.loadOrCreate()
        #expect(keychain.items.count == 1)
    }

    /// Deleting a key that is not there is not an error — a user pressing "sign out" twice
    /// should not see a failure.
    @Test("Deleting an absent key is harmless")
    func deleteAbsentKeyIsHarmless() throws {
        let keychain = FakeKeychain()
        let store = CredentialStoreKey(keychain: keychain)

        try store.delete()
        #expect(keychain.items.isEmpty)

        // And the store is still usable afterwards, rather than left in some half-state.
        let key = try store.loadOrCreate()
        #expect(key.bitCount == 256)
        #expect(keychain.items.count == 1)
    }

    /// The key round-trips through storage byte for byte, or the credential file sealed with
    /// it on one launch cannot be opened on the next.
    @Test("The stored bytes reconstruct the same key")
    func storedBytesReconstructKey() throws {
        let keychain = FakeKeychain()
        let created = try CredentialStoreKey(keychain: keychain).loadOrCreate()

        let stored = try #require(keychain.items.values.first)
        #expect(stored.count == 32)
        #expect(SymmetricKey(data: stored) == created)
    }
}

// MARK: - Helpers

/// A keychain that lives in memory.
///
/// The real one prompts, behaves differently under an unsigned test bundle, and leaves items
/// on the developer's machine. None of that exercises the logic being tested here, which is
/// entirely about what happens on the second launch and on refusal.
// Justification: every stored property is private and reached only under `lock`.
private final class FakeKeychain: KeychainAccess, @unchecked Sendable {

    struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var storage: [Key: Data] = [:]
    private var injectedReadStatus: OSStatus?
    private var injectedWriteStatus: OSStatus?

    /// A status to return from reads instead of succeeding.
    var readStatus: OSStatus? {
        get { withLock { injectedReadStatus } }
        set { withLock { injectedReadStatus = newValue } }
    }

    /// A status to return from writes instead of succeeding.
    var writeStatus: OSStatus? {
        get { withLock { injectedWriteStatus } }
        set { withLock { injectedWriteStatus = newValue } }
    }

    var items: [Key: Data] {
        get { withLock { storage } }
        set { withLock { storage = newValue } }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func data(service: String, account: String) throws -> Data? {
        try withLock {
            if let injectedReadStatus { throw CredentialKeyError.keychain(injectedReadStatus) }
            return storage[Key(service: service, account: account)]
        }
    }

    func store(_ data: Data, service: String, account: String) throws {
        try withLock {
            if let injectedWriteStatus { throw CredentialKeyError.keychain(injectedWriteStatus) }
            storage[Key(service: service, account: account)] = data
        }
    }

    func delete(service: String, account: String) throws {
        withLock {
            _ = storage.removeValue(forKey: Key(service: service, account: account))
        }
    }
}
#endif
