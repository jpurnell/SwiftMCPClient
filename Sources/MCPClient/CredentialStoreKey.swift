#if canImport(Security)
import Foundation
import Crypto
import Security

/// Why the credential store's key could not be obtained.
public enum CredentialKeyError: Error, Equatable, Sendable {

    /// The Keychain refused the read, the write, or the delete.
    ///
    /// Carries the `OSStatus`, because "Keychain failed" is unactionable and the status is
    /// the only thing distinguishing a locked keychain from a missing entitlement.
    case keychain(OSStatus)

    /// The stored item was not a key of the expected size.
    ///
    /// Refused rather than replaced. Replacing it would mint a new key and quietly make every
    /// stored credential undecryptable, which reaches the user as an unexplained request to
    /// sign in again.
    case malformedKey
}

/// Somewhere small secrets are kept.
///
/// A protocol so the logic above it can be tested. The real Keychain prompts, behaves
/// differently under an unsigned test bundle, and leaves items on the machine that ran the
/// tests — none of which exercises the behaviour that matters here, which is what happens on
/// the *second* launch and when a read is refused.
public protocol KeychainAccess: Sendable {

    /// The data stored for a service and account, if any.
    func data(service: String, account: String) throws -> Data?

    /// Stores data, replacing anything already there.
    func store(_ data: Data, service: String, account: String) throws

    /// Removes stored data. Removing what is not there is not an error.
    func delete(service: String, account: String) throws
}

/// The system Keychain.
public struct SystemKeychain: KeychainAccess {

    /// Creates an accessor.
    public init() {}

    /// Reads an item.
    ///
    /// - Parameters:
    ///   - service: The service the item is filed under.
    ///   - account: The account name.
    /// - Returns: The data, or `nil` if there is no such item.
    /// - Throws: ``CredentialKeyError/keychain(_:)``.
    public func data(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            // First run, not a failure.
            return nil
        default:
            throw CredentialKeyError.keychain(status)
        }
    }

    /// Stores an item, replacing any existing one.
    ///
    /// - Parameters:
    ///   - data: What to store.
    ///   - service: The service to file it under.
    ///   - account: The account name.
    /// - Throws: ``CredentialKeyError/keychain(_:)``.
    public func store(_ data: Data, service: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never leaves this device, and is unavailable until the device has been unlocked
            // once. A credential key that syncs is a credential key on every device the user
            // owns, including the ones they stopped using.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemAdd(attributes as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Replace rather than fail. An add that collides means something is already
            // filed here, and the caller asked for this value to be the one stored.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw CredentialKeyError.keychain(status)
        }
    }

    /// Removes an item.
    ///
    /// - Parameters:
    ///   - service: The service the item is filed under.
    ///   - account: The account name.
    /// - Throws: ``CredentialKeyError/keychain(_:)``.
    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialKeyError.keychain(status)
        }
    }
}

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
public struct CredentialStoreKey {

    /// The service the key is filed under.
    static let service = "com.swiftmcpclient.credential-store"

    /// The account name for the key item.
    static let account = "credential-encryption-key"

    /// A 256-bit key, in bytes.
    private static let keyByteCount = 32

    private let keychain: any KeychainAccess

    /// Creates an accessor for the credential key.
    ///
    /// - Parameter keychain: Where the key is kept. Defaults to the system Keychain.
    public init(keychain: any KeychainAccess = SystemKeychain()) {
        self.keychain = keychain
    }

    /// The key, creating and storing one on first use.
    ///
    /// Generated here rather than required from a caller, because a caller who forgot would
    /// get a fresh key each launch — and a fresh key does not report an error, it makes every
    /// stored credential undecryptable and sends the user back to a sign-in screen with no
    /// explanation.
    ///
    /// - Returns: The key.
    /// - Throws: ``CredentialKeyError``.
    public func loadOrCreate() throws -> SymmetricKey {
        if let stored = try keychain.data(service: Self.service, account: Self.account) {
            guard stored.count == Self.keyByteCount else {
                // Not replaced. See `malformedKey`.
                throw CredentialKeyError.malformedKey
            }
            return SymmetricKey(data: stored)
        }

        let created = SymmetricKey(size: .bits256)
        // `Data.init` passed directly rather than wrapped in a closure: a closure whose result
        // mentions the borrowed buffer cannot be told apart from one that lets it escape, and
        // the initialiser already takes a sequence of bytes.
        let bytes = created.withUnsafeBytes(Data.init)

        // Stored before it is returned. Handing back a key that was never written would work
        // for this launch and be gone by the next one, taking every credential with it.
        try keychain.store(bytes, service: Self.service, account: Self.account)
        return created
    }

    /// Removes the stored key.
    ///
    /// The credential file becomes undecryptable, which is the intended effect: this is how a
    /// caller discards every stored credential at once without reaching each one.
    ///
    /// - Throws: ``CredentialKeyError/keychain(_:)``.
    public func delete() throws {
        try keychain.delete(service: Self.service, account: Self.account)
    }
}
#endif
