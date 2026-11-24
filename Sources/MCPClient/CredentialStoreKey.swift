#if canImport(SwiftKeychain)
import Foundation
import Crypto
import SwiftKeychain

/// The key that `EncryptedFileClientStorage` seals credentials with, kept in the Keychain.
///
/// The storage deliberately does not decide where its key lives, because that is the security
/// decision and it belongs to the application. This is that decision for an Apple platform:
/// the Keychain holds one small key, and the credential file holds everything else.
///
/// The division is the point. Putting every credential in the Keychain means an item per
/// connection and a prompt surface that grows with them; putting the key beside the file
/// protects nothing at all. One key in the Keychain, one encrypted file next to the app's
/// other state.
///
/// The Keychain itself is SwiftKeychain's: pass any `KeychainAccess`, such as its
/// `InMemoryKeychain` in tests. Errors are SwiftKeychain's `KeychainError`.
public struct CredentialStoreKey: Sendable {

    /// The Keychain item the key is kept in.
    ///
    /// Fixed, and the same item every earlier version of this package wrote: a key filed
    /// anywhere else is a key that is not found, and a key that is not found is replaced by a
    /// new one that cannot open any credential sealed before it. Kept on this device, readable
    /// after the first unlock, never synchronized, in the application's own access group.
    public static let item = KeychainItem(
        service: "com.swiftmcpclient.credential-store",
        account: "credential-encryption-key",
        accessibility: .afterFirstUnlockThisDeviceOnly,
        synchronizable: false,
        accessGroup: nil)

    /// Where the key is kept.
    public let keychain: any KeychainAccess

    /// Creates an accessor for the credential key.
    ///
    /// The default is the system Keychain without the data-protection keychain, which on
    /// macOS means the login keychain. That is where every earlier version stored the key, and
    /// where an unsigned command-line build can store one at all. On iOS there is only one
    /// keychain and the choice is ignored.
    ///
    /// - Parameter keychain: Where the key is kept.
    public init(keychain: any KeychainAccess = SystemKeychain(dataProtection: false)) {
        self.keychain = keychain
    }

    /// The key, creating and storing one on first use.
    ///
    /// Generated here rather than required from a caller, because a caller who forgot would
    /// get a fresh key each launch — and a fresh key does not report an error, it makes every
    /// stored credential undecryptable and sends the user back to a sign-in screen with no
    /// explanation.
    ///
    /// A stored item of the wrong size is refused rather than replaced, a refused read
    /// (`KeychainError.locked`, for one) is thrown rather than read as "no key yet", and a new
    /// key is only added, never stored over another: if a second process created one first,
    /// that one is returned.
    ///
    /// - Returns: The key.
    /// - Throws: `KeychainError`.
    public func loadOrCreate() throws(KeychainError) -> SymmetricKey {
        SymmetricKey(data: try KeychainKey.loadOrCreate(Self.item, using: keychain))
    }

    /// Removes the stored key.
    ///
    /// The credential file becomes undecryptable, which is the intended effect: this is how a
    /// caller discards every stored credential at once without reaching each one. Removing a
    /// key that is not there is not an error.
    ///
    /// - Throws: `KeychainError`.
    public func delete() throws(KeychainError) {
        try keychain.delete(Self.item)
    }
}
#endif
