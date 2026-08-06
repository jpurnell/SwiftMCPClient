#if canImport(Security)
import Foundation
import Crypto
import Security

/// Why the credential store's key could not be obtained.
public enum CredentialKeyError: Error, Equatable, Sendable {

    /// The Keychain refused the read or the write.
    ///
    /// Carries the OSStatus, because "Keychain failed" is unactionable and the status is the
    /// only thing that distinguishes a locked keychain from a missing entitlement.
    case keychain(OSStatus)

    /// The stored item was not a key of the expected size.
    case malformedKey
}

/// The key that `EncryptedFileClientStorage` seals credentials with,
/// kept in the Keychain.
///
/// The storage deliberately does not decide where its key lives, because that is the security
/// decision and it belongs to the application. This is that decision for an Apple platform:
/// the Keychain holds one small key, and the credential file holds everything else.
///
/// The division is the point. Putting every credential in the Keychain means an item per
/// connection and a prompt surface that grows with them; putting the key beside the file
/// protects nothing at all. One key in the Keychain, one encrypted file next to the app's
/// other state.
public enum CredentialStoreKey {

    /// The service the key is stored under.
    static let service = "com.swiftmcpclient.credential-store"

    /// The account name for the key item.
    static let account = "credential-encryption-key"

    /// The key, creating and storing one on first use.
    ///
    /// Generating on first call rather than requiring setup means a caller cannot forget to,
    /// and a caller who forgot would silently get a new key each launch — which reads as
    /// "the credential file is corrupt" every time.
    ///
    /// - Returns: The key.
    /// - Throws: ``CredentialKeyError``.
    public static func loadOrCreate() throws -> SymmetricKey {
        if let existing = try read() {
            return existing
        }
        let created = SymmetricKey(size: .bits256)
        try write(created)
        return created
    }

    /// Reads the stored key, if there is one.
    static func read() throws -> SymmetricKey? {
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
            guard let data = item as? Data, data.count == 32 else {
                throw CredentialKeyError.malformedKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            // First run, not a failure.
            return nil
        default:
            throw CredentialKeyError.keychain(status)
        }
    }

    /// Stores a key.
    static func write(_ key: SymmetricKey) throws {
        // `Data.init` passed directly rather than wrapped in a closure. A closure whose
        // result mentions the borrowed buffer is indistinguishable from one that lets it
        // escape, and there is no reason to write that shape when the initialiser already
        // takes a sequence of bytes.
        let data = key.withUnsafeBytes(Data.init)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never leaves this device and is unavailable until the device has been unlocked
            // once. A credential key that syncs is a credential key on every device the user
            // owns, including ones they have stopped using.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialKeyError.keychain(status)
        }
    }

    /// Removes the stored key.
    ///
    /// The credential file becomes unreadable, which is the intended effect: this is how a
    /// caller discards every stored credential at once without needing to reach each one.
    public static func delete() throws {
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
#endif
