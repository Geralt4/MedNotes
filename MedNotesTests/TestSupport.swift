import Foundation
import Sodium
import XCTest
@testable import MedNotes

/// Test-only construction helpers.
///
/// Production derives the database and attachment keys from one root key via
/// `StoreKeyContext`; these helpers do exactly the same from a deterministic
/// per-root seed, so a test that prepares a file directly and a session that
/// opens it later agree on the key.
enum TestKeys {
    /// A fixed 32-byte root key, distinct per root path so parallel tests
    /// never share key material in a way that would mask a bug.
    static func root(for root: DataRoot) -> Data {
        derive(seed: "\(root.rootURL.path)|root")
    }

    static func root(forPath path: String) -> Data {
        derive(seed: "\(path)|root")
    }

    static func database(for dataRoot: DataRoot) -> Data {
        subkey(root(for: dataRoot), StoreKeyContext.database)
    }

    static func restorePoint(for dataRoot: DataRoot) -> Data {
        subkey(root(for: dataRoot), StoreKeyContext.restorePoints)
    }

    static func attachment(for dataRoot: DataRoot) -> Data {
        subkey(root(for: dataRoot), StoreKeyContext.attachments)
    }

    static func database(forPath path: String) -> Data {
        subkey(root(forPath: path), StoreKeyContext.database)
    }

    static func attachment(forPath path: String) -> Data {
        subkey(root(forPath: path), StoreKeyContext.attachments)
    }

    /// A failed derivation stops the run: a silent all-zero key would give the
    /// database, attachment and restore-point keys one value and let wrong-key
    /// tests pass for the wrong reason.
    private static func subkey(_ rootKey: Data, _ context: String) -> Data {
        do {
            return try StoreKeyContext.subkey(rootKey: rootKey, context: context)
        } catch {
            preconditionFailure("test key derivation failed: \(error)")
        }
    }

    private static func derive(seed: String) -> Data {
        var bytes = [UInt8]()
        let seedBytes = Array(seed.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seedBytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        for _ in 0..<4 {
            hash ^= hash >> 33
            hash = hash &* 0xff51afd7ed558ccd
            bytes.append(contentsOf: withUnsafeBytes(of: hash.bigEndian) { Array($0) })
        }
        return Data(bytes.prefix(32))
    }
}

extension AppStore {
    /// An encrypted store over a temporary root, with deterministic keys.
    static func testStore(dataRoot: DataRoot) throws -> AppStore {
        try AppStore(
            dataRoot: dataRoot,
            databaseKey: TestKeys.database(for: dataRoot),
            attachmentKey: TestKeys.attachment(for: dataRoot),
            restorePointKey: TestKeys.restorePoint(for: dataRoot))
    }
}

extension AppSession {
    /// A session over a temporary root with an in-memory key manager, so the
    /// test never touches the real Keychain. `defaults` comes from
    /// `TestDefaults.suite`: the init refuses the host's `.standard`.
    static func testSession(dataRoot: DataRoot, defaults: UserDefaults) -> AppSession {
        AppSession(
            dataRoot: dataRoot,
            defaults: defaults,
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: dataRoot)))
    }
}

/// Preferences for test sessions, never the host's own.
///
/// The hosted suite runs in the app's real container, where every suite name
/// leaves a plist in Library/Preferences. So a test class uses one fixed
/// suite, emptied before and after every test, and its file is deleted when
/// the test bundle finishes. Not at tearDown: cfprefsd writes an emptied
/// domain back on its own flush, about every ten seconds (measured on
/// 2026-09-25), and a file deleted before that write comes back.
enum TestDefaults {
    /// The suite `name`, emptied. Call it in setUp.
    static func suite(_ name: String) -> UserDefaults {
        clear(name)
        return UserDefaults(suiteName: name)!
    }

    /// Empties the suite `name`. Call it in tearDown.
    static func clear(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        TestDefaultsFiles.shared.cleared(name)
    }
}

/// Deletes the fixed suites' plists once the bundle is done with them.
private final class TestDefaultsFiles: NSObject, XCTestObservation {
    static let shared = TestDefaultsFiles()

    /// Longer than cfprefsd's flush interval: once this long has passed since
    /// a suite was last emptied, no write for it can still be pending.
    private static let flushInterval: TimeInterval = 12

    private let lock = NSLock()
    private var lastCleared: [String: Date] = [:]
    private var isObserving = false

    func cleared(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        lastCleared[name] = Date()
        if !isObserving {
            isObserving = true
            XCTestObservationCenter.shared.addTestObserver(self)
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return }
        lock.lock()
        let suites = lastCleared
        lock.unlock()
        for (name, cleared) in suites {
            let file = library.appendingPathComponent("Preferences/\(name).plist")
            // Wait for the flush that writes the emptied suite, or until none
            // can still be coming.
            while Date() < cleared.addingTimeInterval(Self.flushInterval),
                  !Self.holdsEmptiedSuite(file, since: cleared) {
                Thread.sleep(forTimeInterval: 0.1)
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Whether `file` was written after `date` and holds no values.
    private static func holdsEmptiedSuite(_ file: URL, since date: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date, modified >= date,
              let data = try? Data(contentsOf: file),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return false }
        return values.isEmpty
    }
}

extension Database {
    /// Runs raw SQL on the actor's connection. Test-only: production code
    /// always goes through a typed method.
    func execForTesting(_ sql: String) throws {
        try conn.exec(sql)
    }
}

extension EncryptedFileStore {
    /// An encrypted attachment store over a temporary root, keyed from the
    /// root path so tests can reopen it.
    static func testStore(at url: URL) throws -> EncryptedFileStore {
        try EncryptedFileStore(root: url, key: TestKeys.attachment(forPath: url.path))
    }
}

/// Wall-clock limits in tests assume an uninstrumented build: under the address
/// or thread sanitizer everything runs several times slower.
enum TestEnvironment {
    static var isSanitized: Bool {
        let inserted = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? ""
        return inserted.contains("asan") || inserted.contains("tsan") || inserted.contains("ubsan")
    }
}

extension SQLConnection {
    /// An encrypted connection to a test store, keyed from the path.
    static func testConnection(path: String) throws -> SQLConnection {
        try SQLConnection(path: path, key: TestKeys.database(forPath: path))
    }
}

extension Database {
    /// The value SQLite reports for a PRAGMA on this connection, as text.
    func pragmaForTesting(_ name: String) throws -> String? {
        let s = try conn.prepare("PRAGMA \(name)")
        guard try s.step() else { return nil }
        return s.columnText(0) ?? s.columnInt(0).map(String.init)
    }

    /// An encrypted database at `path` using the test key derived from `root`.
    static func testDatabase(path: String, root: DataRoot) throws -> Database {
        try Database(path: path, key: TestKeys.database(for: root))
    }

    /// An encrypted database at `path` with a key derived from the path
    /// itself, for tests that never build a `DataRoot`.
    static func testDatabase(path: String) throws -> Database {
        try Database(path: path, key: TestKeys.database(forPath: path))
    }
}
