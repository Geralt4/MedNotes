import Foundation
import Security

/// The single gate in front of every storage-backed service.
///
/// States:
///   - `locked`    — no keys in memory, no connections, no services.
///   - `unlocking` — authentication in flight.
///   - `migrating` — a plaintext store is being converted; the wizard owns the UI.
///   - `ready`     — connections and services exist and may serve data.
///   - `failed`    — a terminal error; the UI shows recovery, never an empty store.
///
/// Nothing that touches patient data may run before `ready`. `AppStore` itself
/// refuses to be constructed outside this coordinator.
enum SecureStoreState: Equatable, Sendable {
    case locked
    case unlocking
    case migrating
    case ready
    case failed(String)
}

enum SecureStoreError: Error, LocalizedError, Equatable {
    case locked
    case missingKeyForExistingStore
    /// The key could not be read right now: the prompt was cancelled or
    /// refused, or the keychain is locked. Retrying can succeed; this is never
    /// a missing key.
    case keyUnavailable(Int32)
    case plaintextStoreRequiresMigration
    case migrationFailed(String)
    /// Attachments or restore points exist but the database file does not.
    /// Opening a new empty store beside them would let the next orphan sweep
    /// treat every attachment as unreferenced.
    case databaseMissing

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return String(localized: "The MedNotes database file is missing, although attachments or restore points are still stored. Nothing was changed and no new database was created. Quit MedNotes and put the mednotes.db file back from a Time Machine copy before opening it again.")
        case .locked:
            return String(localized: "MedNotes is locked.")
        case .missingKeyForExistingStore:
            return String(localized: "Encrypted data exists but its device key is missing. Restore from a portable backup to recover.")
        case .keyUnavailable(errSecUserCanceled):
            return String(localized: "Unlock was cancelled. Try again.")
        case .keyUnavailable(errSecAuthFailed):
            return String(localized: "Touch ID or the password was not accepted. Try again.")
        case .keyUnavailable(errSecInteractionNotAllowed):
            return String(localized: "The Keychain is not available yet. Unlock your Mac, then try again.")
        case .keyUnavailable(let status):
            return String(localized: "The device key could not be read from the Keychain (status \(status)). Try again.")
        case .plaintextStoreRequiresMigration:
            return String(localized: "This store is still plaintext. Run the encryption migration before using it.")
        case .migrationFailed(let detail):
            return String(localized: "The encryption migration failed: \(detail)")
        }
    }
}

/// What one read of the root key found.
enum RootKeyLookup: Equatable {
    case present(Data)
    /// The Keychain has no item (`errSecItemNotFound`).
    case absent
    /// An item exists but can never be a root key (wrong length, no data), so
    /// no retry will help and only recovery can replace it.
    case damaged
}

extension KeyManager {
    /// Reads the root key once. Only `.absent` and `.damaged` prove the key is
    /// unusable. A read that fails throws `SecureStoreError.keyUnavailable`
    /// instead, because the key may well be there: treating a cancelled Touch
    /// ID prompt as a missing key would offer to replace a healthy store.
    func lookUpRootKey() throws -> RootKeyLookup {
        do {
            guard let key = try rootKey() else { return .absent }
            return .present(key)
        } catch KeyManagerError.keychainFailure(let status) {
            throw SecureStoreError.keyUnavailable(status)
        } catch KeyManagerError.invalidKeyLength(_), KeyManagerError.missingRootKey {
            return .damaged
        }
    }
}

/// Owns the root key, the derived subkeys and the state transitions. Main-actor
/// isolated because the lock/unlock decisions are driven by UI events; the
/// actual store construction happens on a detached task and is handed back.
@MainActor
final class SecureStoreCoordinator: ObservableObject {
    @Published private(set) var state: SecureStoreState = .locked
    @Published private(set) var lastError: String?

    /// Idle lock interval. The plan mandates five minutes.
    static let idleInterval: TimeInterval = 5 * 60

    private let keyManagerRef: KeyManager
    private let dataRootRef: DataRoot
    private var rootKey: Data?
    private var databaseKey: Data?
    private var attachmentKey: Data?
    private var restoreKey: Data?

    init(keyManager: KeyManager, dataRoot: DataRoot) {
        self.keyManagerRef = keyManager
        self.dataRootRef = dataRoot
    }

    nonisolated var keyManager: KeyManager { keyManagerRef }

    var isReady: Bool { state == .ready }

    /// The store directory must be inspected before unlocking: plaintext data
    /// that has no key yet forces the migration wizard, and encrypted data
    /// with no key is a recovery case, never a fresh empty database. So is a
    /// folder that still holds attachments or restore points but no database.
    enum Preflight: Equatable {
        case empty
        case plaintextStore
        case encryptedStore
        case encryptedWithoutKey
        case databaseMissing
    }

    /// Whether the folder holds data that only a database can account for: an
    /// encrypted attachment object, or a restore point.
    private nonisolated static func holdsStoredData(_ dataRoot: DataRoot) -> Bool {
        let fm = FileManager.default
        let attachments = (try? fm.contentsOfDirectory(atPath: dataRoot.attachmentsURL.path)) ?? []
        if attachments.contains(where: EncryptedFileStore.isSafeStorageID) { return true }
        let restorePoints = (try? fm.contentsOfDirectory(atPath: dataRoot.restorePointsURL.path)) ?? []
        if restorePoints.contains(where: { $0.hasSuffix(".mnrp") }) { return true }
        // The originals of a restore that was cut off and could not be undone.
        return !RestoreRecovery.rollbackFolders(in: dataRoot.rootURL).isEmpty
    }

    /// Classifies the store. Only encrypted data reads the key; a read that
    /// fails throws `SecureStoreError.keyUnavailable` rather than reporting
    /// `.encryptedWithoutKey`.
    nonisolated static func preflight(dataRoot: DataRoot, keyManager: KeyManager) throws -> Preflight {
        try inspect(dataRoot: dataRoot, keyManager: keyManager).preflight
    }

    /// The preflight plus the key it read, so one Keychain query (one Touch ID
    /// prompt) both classifies an encrypted store and unlocks it.
    private nonisolated static func inspect(
        dataRoot: DataRoot, keyManager: KeyManager
    ) throws -> (preflight: Preflight, key: Data?) {
        let dbURL = dataRoot.databaseURL
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return (holdsStoredData(dataRoot) ? .databaseMissing : .empty, nil)
        }
        if SQLiteHeaderInspection.isPlaintextSQLite(at: dbURL) { return (.plaintextStore, nil) }
        guard case .present(let key) = try keyManager.lookUpRootKey() else {
            return (.encryptedWithoutKey, nil)
        }
        return (.encryptedStore, key)
    }

    /// Loads (or creates) the root key and derives the subkeys, reading the
    /// Keychain at most once. Never opens a database. Returns the preflight
    /// outcome so the caller can route.
    ///
    /// A read that was cancelled or refused throws `.keyUnavailable` and
    /// leaves the coordinator `locked`, so Unlock can simply be retried; only
    /// a key item that is really absent throws `.missingKeyForExistingStore`.
    func authenticate() throws -> Preflight {
        state = .unlocking
        lastError = nil
        do {
            let (preflight, key) = try Self.inspect(dataRoot: dataRootRef, keyManager: keyManagerRef)
            switch preflight {
            case .plaintextStore:
                rootKey = nil
                state = .migrating
                return preflight

            case .encryptedWithoutKey:
                let message = SecureStoreError.missingKeyForExistingStore.localizedDescription
                state = .failed(message)
                lastError = message
                throw SecureStoreError.missingKeyForExistingStore

            case .databaseMissing:
                // No key is created and no database is opened: the files that
                // are left stay exactly as they are.
                let message = SecureStoreError.databaseMissing.localizedDescription
                state = .failed(message)
                lastError = message
                throw SecureStoreError.databaseMissing

            case .encryptedStore:
                guard let key else { throw SecureStoreError.missingKeyForExistingStore }
                try install(rootKey: key)

            case .empty:
                let key: Data
                do {
                    key = try keyManagerRef.createRootKey()
                } catch KeyManagerError.keychainFailure(let status) {
                    throw SecureStoreError.keyUnavailable(status)
                }
                try install(rootKey: key)
            }
            state = .ready
            return preflight
        } catch let error as SecureStoreError {
            if case .keyUnavailable = error {
                lastError = error.localizedDescription
                state = .locked
            }
            throw error
        } catch {
            // Anything else (a `KeyManagerError` from the key path, say) must
            // not leave the coordinator in `.unlocking` with no message: it
            // reads as locked, so Unlock can be tried again.
            lastError = error.localizedDescription
            state = .locked
            throw error
        }
    }

    /// Called by the migration wizard once a new root key exists and the
    /// encrypted store has been validated. The wizard writes the key through
    /// `createMigrationKey` first so the key is never held across a crash.
    func finishMigration(rootKey: Data) throws {
        try install(rootKey: rootKey)
        state = .ready
    }

    /// Called once `StoreRecovery` has installed a restored store and stored
    /// its new key. Installs that key directly: reading it back would only
    /// ask for Touch ID again.
    func finishRecovery(rootKey: Data) throws {
        try install(rootKey: rootKey)
        state = .ready
    }

    /// Creates the root key the migration will use and returns it. The key is
    /// persisted immediately: a crash after this point leaves an encrypted
    /// store whose key exists, which is the recoverable direction.
    @discardableResult
    func createMigrationKey() throws -> Data {
        let key = try keyManagerRef.createRootKey()
        try install(rootKey: key)
        return key
    }

    private func install(rootKey: Data) throws {
        guard rootKey.count == 32 else { throw KeyManagerError.invalidKeyLength(rootKey.count) }
        self.rootKey = rootKey
        self.databaseKey = try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.database)
        self.attachmentKey = try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.attachments)
        self.restoreKey = try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.restorePoints)
    }

    func requireDatabaseKey() throws -> Data {
        guard state == .ready, let databaseKey else { throw SecureStoreError.locked }
        return databaseKey
    }

    func requireAttachmentKey() throws -> Data {
        guard state == .ready, let attachmentKey else { throw SecureStoreError.locked }
        return attachmentKey
    }

    func requireRestoreKey() throws -> Data {
        guard state == .ready, let restoreKey else { throw SecureStoreError.locked }
        return restoreKey
    }

    /// Wipes every key buffer and returns to `locked`. Idempotent.
    func lock() {
        rootKey = nil
        databaseKey = nil
        attachmentKey = nil
        restoreKey = nil
        EncryptedFileStore.purgeOrphanedTemporaries(in: dataRootRef.externalCopiesURL)
        if case .failed = state { return }
        state = .locked
    }
}
