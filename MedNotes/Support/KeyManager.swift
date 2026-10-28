import Foundation
import Security
import Sodium

/// The device root key and the subkeys derived from it.
///
/// One random 256-bit root key is generated during migration and stored in the
/// Keychain as a non-synchronizing item, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
/// gated on user presence (Touch ID or the account password). Every other key is
/// derived from it with libsodium's KDF, so a single Keychain prompt covers the
/// database, attachments and restore points.
///
/// Nothing here writes a key to disk; the in-memory implementation exists for
/// tests and the CLI, which never touch the user's Keychain.
protocol KeyManager: Sendable {
    /// Returns the existing root key, or nil only when no key item exists.
    /// A read that fails (a cancelled or refused prompt, a locked keychain)
    /// throws: the key may well be there.
    func rootKey() throws -> Data?
    /// Creates the root key if absent and returns it.
    func createRootKey() throws -> Data
    /// Stores `key` as the root key; throws if an item already exists. Used
    /// only by recovery, once the restored store has validated under it.
    func storeRootKey(_ key: Data) throws
    /// Removes the root key. Used only by explicit recovery flows.
    func deleteRootKey() throws
}

enum KeyManagerError: Error, LocalizedError, Equatable {
    case keychainFailure(Int32)
    case missingRootKey
    case derivationFailed
    case invalidKeyLength(Int)

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            return String(localized: "The device key could not be read from the Keychain (status \(status)).")
        case .missingRootKey:
            return String(localized: "The device key is missing. Restore from a portable backup to recover this data.")
        case .derivationFailed:
            return String(localized: "A storage key could not be derived from the device key.")
        case .invalidKeyLength(let count):
            return String(localized: "The device key has an unexpected length (\(count) bytes).")
        }
    }
}

/// Derives the labelled subkeys used by each store. Contexts are fixed 8-byte
/// libsodium KDF contexts; the index is always 0 because each context already
/// names one purpose.
enum StoreKeyContext {
    static let database = "mn.db.v1"
    static let attachments = "mn.fs.v1"
    static let restorePoints = "mn.rp.v1"
    static let archive = "mn.arc.v1"

    /// A fresh random root key.
    static func newRootKey() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func subkey(rootKey: Data, context: String) throws -> Data {
        guard rootKey.count == 32 else { throw KeyManagerError.invalidKeyLength(rootKey.count) }
        let sodium = Sodium()
        guard let derived: Bytes = sodium.keyDerivation.derive(
            secretKey: [UInt8](rootKey),
            index: 0,
            length: 32,
            context: context) else {
            throw KeyManagerError.derivationFailed
        }
        return Data(derived)
    }
}

/// The production Keychain implementation.
///
/// Uses `SecAccessControl` with `.userPresence` so reading the key requires
/// Touch ID or the account password. `kSecUseDataProtectionKeychain` keeps the
/// item in the modern (data-protection) keychain, which is what makes
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` meaningful on macOS.
final class KeychainKeyManager: KeyManager {
    static let defaultService = "com.johnteam.MedNotes.devicekey"
    static let defaultAccount = "root"

    private let service: String
    private let account: String

    init(service: String = KeychainKeyManager.defaultService,
         account: String = KeychainKeyManager.defaultAccount) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func accessControl() -> SecAccessControl? {
        SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            nil)
    }

    func rootKey() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseOperationPrompt as String] = String(localized: "Unlock MedNotes")
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyManagerError.keychainFailure(status) }
        guard let data = result as? Data else { throw KeyManagerError.missingRootKey }
        guard data.count == 32 else { throw KeyManagerError.invalidKeyLength(data.count) }
        return data
    }

    @discardableResult
    func createRootKey() throws -> Data {
        if let existing = try rootKey() { return existing }
        let key = StoreKeyContext.newRootKey()
        let status = add(key)
        if status == errSecDuplicateItem {
            // Another process added it between the read above and this add.
            // Returning the un-stored `key` would tell the caller a key exists
            // while the Keychain holds a different one, and the next launch
            // would see an encrypted store with no usable key.
            guard let existing = try rootKey() else { throw KeyManagerError.missingRootKey }
            return existing
        }
        guard status == errSecSuccess else { throw KeyManagerError.keychainFailure(status) }
        return key
    }

    func storeRootKey(_ key: Data) throws {
        guard key.count == 32 else { throw KeyManagerError.invalidKeyLength(key.count) }
        let status = add(key)
        guard status == errSecSuccess else { throw KeyManagerError.keychainFailure(status) }
    }

    private func add(_ key: Data) -> OSStatus {
        // Fail closed: assigning a nil access control would drop the key from the
        // query and store it with no user-presence gate.
        guard let access = accessControl() else { return errSecParam }
        var query = baseQuery()
        query[kSecValueData as String] = key
        query[kSecAttrAccessControl as String] = access
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil)
    }

    func deleteRootKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyManagerError.keychainFailure(status)
        }
    }
}

/// Test/CLI implementation: a key held in memory for the lifetime of the
/// process. Used by the unit test suite so nothing touches the real Keychain,
/// and by the dry-run importer which writes to a throwaway store.
final class InMemoryKeyManager: KeyManager, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    init(key: Data? = nil) {
        self.key = key
    }

    func rootKey() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    @discardableResult
    func createRootKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let key { return key }
        let fresh = StoreKeyContext.newRootKey()
        key = fresh
        return fresh
    }

    func storeRootKey(_ newKey: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard key == nil else { throw KeyManagerError.keychainFailure(errSecDuplicateItem) }
        key = newKey
    }

    func deleteRootKey() throws {
        lock.lock(); defer { lock.unlock() }
        key = nil
    }
}
