#if canImport(SwiftKeychain)
import Foundation
import Testing
import Crypto
import SwiftKeychain
import os
import MCPClient

/// The key that every stored credential is sealed with.
///
/// Its failure modes are quiet ones. A key that changes between launches does not report an
/// error — it makes the credential file undecryptable, and the user is asked to sign in again
/// with no explanation. So the tests here are mostly about *not* silently minting a new key,
/// and about finding the key that earlier versions of this package stored.
@Suite("Credential store key")
struct CredentialStoreKeyTests {

    /// The service every version up to 0.14.0 filed the key under. Written out, not read from
    /// the type under test, so a change to the type cannot quietly move this too.
    static let legacyService = "com.swiftmcpclient.credential-store"

    /// The account every version up to 0.14.0 filed the key under.
    static let legacyAccount = "credential-encryption-key"

    // MARK: - Compatibility with the key earlier versions stored

    /// The item's identity is what finds an existing user's key. Every field is pinned:
    /// service and account name it; the accessibility class is what 0.14.0 wrote; an item
    /// that synchronized, or sat in an access group, would be a different item, and the old
    /// one — with every credential sealed by it — would be left where nothing reads it.
    @Test("The key's Keychain item is the one earlier versions stored")
    func itemIdentityIsPinned() {
        let item = CredentialStoreKey.item

        #expect(item.service == Self.legacyService)
        #expect(item.account == Self.legacyAccount)
        #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
        #expect(item.synchronizable == false)
        #expect(item.accessGroup == nil)
        #expect(item == KeychainItem(
            service: Self.legacyService,
            account: Self.legacyAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly,
            synchronizable: false,
            accessGroup: nil))
    }

    /// Earlier versions wrote the key without `kSecUseDataProtectionKeychain`, which on macOS
    /// is the login (file-based) keychain. The data-protection keychain is a different store:
    /// reading there finds nothing, and the next step would mint a new key. On iOS the flag is
    /// ignored, since there is only one keychain.
    @Test("By default the key is read from the keychain earlier versions wrote it to")
    func defaultKeychainIsTheLoginKeychain() throws {
        let system = try #require(
            CredentialStoreKey().keychain as? SystemKeychain,
            "the default store is not the system Keychain")
        #expect(system.dataProtection == false, "the data-protection keychain does not hold the existing key")
    }

    /// The upgrade, end to end against a stand-in: a key stored at the old identity by an
    /// earlier version is the key this version returns, byte for byte, and nothing is added.
    @Test("A key stored by an earlier version is found and returned unchanged")
    func findsKeyStoredByEarlierVersion() throws {
        let keychain = InMemoryKeychain()
        let existing = Data((0..<32).map { UInt8($0) })
        try keychain.store(existing, as: KeychainItem(service: Self.legacyService, account: Self.legacyAccount))

        let key = try CredentialStoreKey(keychain: keychain).loadOrCreate()

        #expect(key == SymmetricKey(data: existing), "a different key was returned; every stored credential is now unreadable")
        #expect(try keychain.accounts(service: Self.legacyService) == [Self.legacyAccount])
    }

    // MARK: - Behaviour

    /// First run: there is no key, so one is created and kept.
    @Test("A key is created on first use and stored")
    func createsOnFirstUse() throws {
        let keychain = InMemoryKeychain()

        let key = try CredentialStoreKey(keychain: keychain).loadOrCreate()

        #expect(key.bitCount == 256)
        #expect(try keychain.data(for: CredentialStoreKey.item)?.count == 32, "the key was not persisted")
    }

    /// The one that matters. A second launch must get the *same* key — a new one each time
    /// makes every stored credential unreadable.
    @Test("The same key comes back on a later launch")
    func sameKeyOnSecondLaunch() throws {
        let keychain = InMemoryKeychain()

        let first = try CredentialStoreKey(keychain: keychain).loadOrCreate()
        // A separate instance, as though the process had restarted.
        let second = try CredentialStoreKey(keychain: keychain).loadOrCreate()

        #expect(first == second, "a different key was returned; every credential is now unreadable")
        #expect(try keychain.accounts(service: Self.legacyService) == [Self.legacyAccount])
    }

    /// Two keys generated fresh must differ, or "generation" is not generating anything.
    @Test("Separate keychains get separate keys")
    func separateKeychainsDiffer() throws {
        let first = try CredentialStoreKey(keychain: InMemoryKeychain()).loadOrCreate()
        let second = try CredentialStoreKey(keychain: InMemoryKeychain()).loadOrCreate()
        #expect(first != second)
    }

    /// A stored item of the wrong size must be refused rather than replaced. Replacing it
    /// would be the silent path to an unreadable credential file.
    @Test("A malformed stored key is refused, not replaced")
    func malformedKeyRefused() throws {
        let keychain = InMemoryKeychain()
        let malformed = Data([1, 2, 3])
        try keychain.store(malformed, as: CredentialStoreKey.item)

        let error = #expect(throws: KeychainError.self) {
            try CredentialStoreKey(keychain: keychain).loadOrCreate()
        }
        guard case .malformed = error else {
            Issue.record("expected .malformed, got \(String(describing: error))")
            return
        }
        #expect(try keychain.data(for: CredentialStoreKey.item) == malformed, "the malformed item was overwritten")
    }

    /// A locked keychain must surface as locked, never as "no key yet" — that reading would
    /// mint a new key and replace the real one.
    @Test("A locked keychain is reported, not read as empty")
    func lockedKeychainReported() {
        let keychain = RefusingKeychain(refuseReads: .locked)

        #expect(throws: KeychainError.locked) {
            try CredentialStoreKey(keychain: keychain).loadOrCreate()
        }
        #expect(keychain.attemptedWrite == false, "a key was written while the keychain was locked")
    }

    /// A write that fails must throw rather than hand back a key that was never stored —
    /// that key would work for this launch and be gone by the next one.
    @Test("A failed write is reported rather than returning an unstored key")
    func failedWriteReported() {
        let keychain = RefusingKeychain(refuseWrites: .missingEntitlement)

        #expect(throws: KeychainError.missingEntitlement) {
            try CredentialStoreKey(keychain: keychain).loadOrCreate()
        }
    }

    /// Deleting the key is how a caller discards every credential at once.
    @Test("Deleting the key removes it")
    func deleteRemovesKey() throws {
        let keychain = InMemoryKeychain()
        let store = CredentialStoreKey(keychain: keychain)

        let first = try store.loadOrCreate()
        try store.delete()
        #expect(try keychain.data(for: CredentialStoreKey.item) == nil)

        // And the next call mints a fresh one rather than failing.
        let second = try store.loadOrCreate()
        #expect(first != second)
        #expect(try keychain.data(for: CredentialStoreKey.item)?.count == 32, "the fresh key was not persisted")
    }

    /// Deleting a key that is not there is not an error — "sign out" pressed twice should not
    /// fail.
    @Test("Deleting an absent key is harmless")
    func deleteAbsentKeyIsHarmless() throws {
        let keychain = InMemoryKeychain()
        let store = CredentialStoreKey(keychain: keychain)

        try store.delete()

        let key = try store.loadOrCreate()
        #expect(key.bitCount == 256)
    }

    /// The key round-trips through storage byte for byte, or the credential file sealed with
    /// it on one launch cannot be opened on the next.
    @Test("The stored bytes reconstruct the same key")
    func storedBytesReconstructKey() throws {
        let keychain = InMemoryKeychain()
        let created = try CredentialStoreKey(keychain: keychain).loadOrCreate()

        let stored = try #require(try keychain.data(for: CredentialStoreKey.item))
        #expect(stored.count == 32)
        #expect(SymmetricKey(data: stored) == created)
    }
}

// MARK: - Helpers

/// A keychain that refuses reads, writes, or both, with a chosen error, and holds nothing.
///
/// `InMemoryKeychain` never refuses, and the cases worth testing are the refusals: a locked
/// device and an unsigned process.
private final class RefusingKeychain: KeychainAccess {

    private let readError: KeychainError?
    private let writeError: KeychainError?
    private let wrote = OSAllocatedUnfairLock(initialState: false)

    init(refuseReads readError: KeychainError? = nil, refuseWrites writeError: KeychainError? = nil) {
        self.readError = readError
        self.writeError = writeError
    }

    /// Whether anything tried to store or add an item.
    var attemptedWrite: Bool { wrote.withLock { $0 } }

    func data(for item: KeychainItem) throws(KeychainError) -> Data? {
        if let readError { throw readError }
        return nil
    }

    func store(_ data: Data, as item: KeychainItem) throws(KeychainError) {
        wrote.withLock { $0 = true }
        if let writeError { throw writeError }
    }

    func add(_ data: Data, as item: KeychainItem) throws(KeychainError) -> Bool {
        wrote.withLock { $0 = true }
        if let writeError { throw writeError }
        return true
    }

    func delete(_ item: KeychainItem) throws(KeychainError) {
        if let writeError { throw writeError }
    }

    func accounts(service: String) throws(KeychainError) -> [String] {
        if let readError { throw readError }
        return []
    }
}
#endif
