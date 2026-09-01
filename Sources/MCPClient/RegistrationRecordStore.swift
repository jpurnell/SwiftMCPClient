import Foundation
import Crypto
import Logging
import SwiftOAuthClient

/// Where a dynamic client registration is kept between launches.
///
/// The credential a sign-in produces is only half of what a later launch needs. The other half
/// is the registration that obtained it — a refresh token is bound to the `client_id` it was
/// issued to (RFC 6749 §6), so a client that registers again cannot use the credential already
/// on file, and the server accumulates one dead registration per launch.
///
/// A protocol so the logic above it can be tested without a file, and so an application that
/// keeps its state somewhere other than a sealed file can say so.
///
/// ## What an implementation must guarantee
///
/// **An unreadable store must not report itself as empty.** Empty means "this user has never
/// signed in", and that answer sends a caller to a fresh sign-in, which mints a new
/// registration and orphans the stored credential. Throw instead; a caller can act on a throw.
public protocol RegistrationRecordStore: Sendable {

    /// The registration for a connection, if one is stored.
    func record(for connection: ConnectionID) async throws -> ClientRegistrationResponse?

    /// Stores a registration, replacing any previous one for the same connection.
    func store(_ record: ClientRegistrationResponse, for connection: ConnectionID) async throws

    /// Forgets a connection's registration.
    ///
    /// Removing what is not there is not an error.
    func remove(_ connection: ConnectionID) async throws
}

/// Registrations kept in an encrypted file.
///
/// The persistent counterpart to ``InMemoryRegistrationStore``, and the sibling of SwiftOAuth's
/// `EncryptedFileClientStorage`: same AES-GCM discipline, same key, a file beside it. Kept
/// separate rather than folded into the credential file because the two have different owners
/// — one is SwiftOAuth's format, this one is ours — and a client that persisted its
/// registrations *inside* another package's file would break on that package's next format
/// change.
///
/// ## What is protected, and from what
///
/// A registration carries a `client_secret`. Sealed with **AES-GCM**, which authenticates as
/// well as encrypts: a store that merely encrypted would open a tampered file into plausible
/// nonsense, and presenting nonsense at a token endpoint is indistinguishable to the user from
/// having been signed out.
///
/// The **whole file** is sealed, so which servers have been connected to is not readable
/// either. This protects a file at rest — copied out of a backup, read off a disk. It does not
/// protect against a process that can already read this one's memory.
///
/// ## The key
///
/// Supplied by the caller, not derived here. On an Apple platform that means
/// ``CredentialStoreKey`` — the same key that opens `credentials.enc`, because the two files
/// are worth exactly the same to an attacker and a second key would double the number of
/// things that can be lost without adding anything.
public actor EncryptedFileRegistrationStore: RegistrationRecordStore {

    /// Records as last read or written, so the file is not re-opened per lookup.
    private var cache: [String: ClientRegistrationResponse]?

    private let url: URL
    private let key: SymmetricKey

    /// Creates a store over a file.
    ///
    /// The file need not exist; it is created on first write. The containing directory is
    /// created if it is missing, so a caller naming a path under Application Support does not
    /// have to make the path first.
    ///
    /// - Parameters:
    ///   - url: Where the registrations live — conventionally `registrations.enc`, beside the
    ///     credential file.
    ///   - key: The key to seal them with.
    /// - Throws: If the containing directory could not be created.
    public init(url: URL, key: SymmetricKey) throws {
        self.url = url
        self.key = key

        // Created unconditionally: `withIntermediateDirectories` succeeds when the directory is
        // already there, and checking first would be a time-of-check race — the directory can
        // appear or vanish between the check and the use.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// The registration for this connection, if one is stored.
    ///
    /// - Parameter connection: Which connection.
    /// - Returns: The registration, or `nil` if none is held.
    /// - Throws: `StorageError.cannotDecrypt` if the file cannot be opened with this key,
    ///   `StorageError.unreadable` if it opened but did not decode.
    public func record(for connection: ConnectionID) async throws -> ClientRegistrationResponse? {
        try load()[connection.description]
    }

    /// Stores a registration, replacing any previous one.
    ///
    /// - Parameters:
    ///   - record: What to store.
    ///   - connection: Which connection it belongs to.
    /// - Throws: `StorageError.cannotWrite` if the write could not be made durable.
    public func store(
        _ record: ClientRegistrationResponse,
        for connection: ConnectionID
    ) async throws {
        var records = try load()
        records[connection.description] = record
        try save(records)
    }

    /// Forgets a connection's registration.
    ///
    /// - Parameter connection: Which connection to forget.
    /// - Throws: `StorageError.cannotWrite`.
    public func remove(_ connection: ConnectionID) async throws {
        var records = try load()
        records.removeValue(forKey: connection.description)
        try save(records)
    }

    // MARK: - The file

    /// Reads and decrypts, or returns what was already read.
    private func load() throws -> [String: ClientRegistrationResponse] {
        if let cache { return cache }

        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First run. Read and handle rather than checking existence first: a file can be
            // created or removed between the check and the read, and the absent case has to be
            // handled here regardless.
            let logger = Logger(label: "MCPClient.RegistrationRecordStore")
            // logging: the absent file is the answer to "why am I being asked to sign in again"
            logger.debug("no registration file yet; treating as first run: \(error.localizedDescription)")
            cache = [:]
            return [:]
        } catch {
            // Distinct from the case above: a file that exists and cannot be read must not be
            // mistaken for a first run.
            let logger = Logger(label: "MCPClient.RegistrationRecordStore")
            // logging: the underlying reason, which the thrown error deliberately does not carry
            logger.error("registration file could not be read: \(error.localizedDescription)")
            throw StorageError.cannotDecrypt
        }

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            // A wrong key and a tampered file arrive here identically, and both must throw.
            // Returning empty would look like a first run and send the caller to a sign-in that
            // registers again — orphaning the credential this registration belongs to.
            let logger = Logger(label: "MCPClient.RegistrationRecordStore")
            // logging: which of key or contents failed is the whole diagnosis
            logger.error("registration file could not be opened with this key: \(error.localizedDescription)")
            throw StorageError.cannotDecrypt
        }

        do {
            let records = try JSONDecoder().decode(
                [String: ClientRegistrationResponse].self, from: plaintext)
            cache = records
            return records
        } catch {
            let logger = Logger(label: "MCPClient.RegistrationRecordStore")
            // logging: decrypted-but-undecodable means a format change, not a bad key
            logger.error("registration file decrypted but did not decode: \(error.localizedDescription)")
            throw StorageError.unreadable
        }
    }

    /// Encrypts and writes.
    ///
    /// Written atomically. A half-written registration file is unopenable — AES-GCM
    /// authenticates the whole of it — so a partial write does not lose one record, it loses
    /// every session on the machine.
    private func save(_ records: [String: ClientRegistrationResponse]) throws {
        let encoder = JSONEncoder()
        // Sorted keys so the same records produce the same plaintext. The ciphertext still
        // differs every time — AES-GCM uses a fresh nonce — but the input to it does not depend
        // on a per-process hash seed.
        encoder.outputFormatting = [.sortedKeys]

        do {
            let plaintext = try encoder.encode(records)
            guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
                throw StorageError.cannotWrite
            }
            try combined.write(to: url, options: [.atomic])
        } catch {
            // Every failure here is the same to a caller: nothing durable was written, and the
            // next launch will ask the user to sign in. The reason is logged because "could not
            // write" alone leaves an operator nothing to go on.
            let logger = Logger(label: "MCPClient.RegistrationRecordStore")
            // logging: the underlying reason, which the thrown error deliberately does not carry
            logger.error("registrations could not be written: \(error.localizedDescription)")
            throw StorageError.cannotWrite
        }

        // Only after the write succeeded. Updating first would leave this store answering from
        // a state the file does not hold.
        cache = records
    }
}

/// Registrations held in memory.
///
/// For tests, and for a tool where re-registering on restart is acceptable. **Not** for an
/// application that persists its credentials: the credential would outlive the registration
/// that can use it, which is the exact failure this whole file exists to prevent.
public actor InMemoryRegistrationStore: RegistrationRecordStore {

    private var records: [ConnectionID: ClientRegistrationResponse] = [:]

    /// Creates an empty store.
    public init() {}

    /// The registration for this connection, if one is stored.
    ///
    /// - Parameter connection: Which connection.
    /// - Returns: The registration, or `nil` if none is held.
    public func record(for connection: ConnectionID) async throws -> ClientRegistrationResponse? {
        records[connection]
    }

    /// Stores a registration, replacing any previous one.
    ///
    /// - Parameters:
    ///   - record: What to store.
    ///   - connection: Which connection it belongs to.
    public func store(
        _ record: ClientRegistrationResponse,
        for connection: ConnectionID
    ) async throws {
        records[connection] = record
    }

    /// Forgets a connection's registration.
    ///
    /// - Parameter connection: Which connection to forget.
    public func remove(_ connection: ConnectionID) async throws {
        records.removeValue(forKey: connection)
    }
}
