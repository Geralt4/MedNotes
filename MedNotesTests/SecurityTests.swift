import AppKit
import Security
import Sodium
import SwiftUI
import XCTest
@testable import MedNotes

/// The acceptance tests for the encrypted store: SQLCipher rejects bad keys,
/// the file on disk carries no patient text or SQLite header, attachments
/// authenticate every chunk, and the migration converts a plaintext store
/// safely.
final class SecurityTests: XCTestCase {
    private var tempDir: URL!
    private var roots: [DataRoot] = []
    /// The sessions' preferences: never the host's own, which are the
    /// owner's. One fixed suite, emptied around every test. See `TestDefaults`.
    private static let defaultsName = "MedNotesTests.Security"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDownWithError() throws {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRoot(_ name: String = "root") throws -> DataRoot {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent(name, isDirectory: true))
        roots.append(root)
        return root
    }

    // MARK: - SQLCipher

    func testDatabaseFileHasNoSQLiteHeaderAndNoPatientText() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Αναστάσιος"
        patient.profile.lastName = "Παπαδόπουλος"
        patient.profile.amka = "12047812347"
        try await store.patients.save(patient)
        try await store.notes.save(Note(title: "Ward round", content: "UNIQUE-PATIENT-MARKER"))
        await store.close()

        let bytes = try Data(contentsOf: root.databaseURL)
        XCTAssertFalse(bytes.prefix(15) == Data("SQLite format 3".utf8),
                       "the database must not begin with a plaintext SQLite header")
        XCTAssertNil(bytes.range(of: Data("UNIQUE-PATIENT-MARKER".utf8)),
                     "patient text must not be readable in the file")
        XCTAssertNil(bytes.range(of: Data("Αναστάσιος".utf8)),
                     "patient names must not be readable in the file")
    }

    func testWrongKeyIsRejectedAndCorrectKeyOpens() throws {
        let root = try makeRoot()
        let path = root.databaseURL.path
        let db = try Database(path: path, key: TestKeys.database(for: root))
        Task { await db.close() }
        XCTAssertNotNil(try Database(path: path, key: TestKeys.database(for: root)))
        XCTAssertThrowsError(try Database(path: path, key: Data(repeating: 0x11, count: 32))) { error in
            XCTAssertEqual(error as? SQLiteError, .wrongKey)
        }
    }

    func testACorruptFirstPageStaysWrongKeyAndALaterPageIsReportedAsDamaged() async throws {
        func errorAfterFlipping(page: Int) async throws -> Error? {
            let root = try makeRoot("corrupt-page-\(page)")
            let path = root.databaseURL.path
            let db = try Database(path: path, key: TestKeys.database(for: root))
            for index in 0..<20 {
                try await db.saveNote(Note(
                    title: "note \(index)", content: String(repeating: "x", count: 8_192)))
            }
            let pageSizeText = try await db.pragmaForTesting("page_size")
            let pageSize = try XCTUnwrap(Int(pageSizeText ?? ""))
            try await db.checkpoint()
            await db.close()

            var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertGreaterThan(bytes.count, 3 * pageSize, "the test needs a page after the first")
            let offset = (page - 1) * pageSize + pageSize / 2
            bytes[offset] ^= 0x01
            try bytes.write(to: URL(fileURLWithPath: path))

            do {
                _ = try Database(path: path, key: TestKeys.database(for: root))
                XCTFail("a damaged database must not open")
                return nil
            } catch {
                return error
            }
        }

        // Both cases are a failed page HMAC. Page 1 cannot prove whether the
        // key or the page is wrong; a later page proves the key opened page 1.
        let first = try await errorAfterFlipping(page: 1)
        XCTAssertEqual(first as? SQLiteError, .wrongKey)
        let later = try await errorAfterFlipping(page: 3)
        XCTAssertEqual(later as? SQLiteError, .corruptDatabase(page: 3))
        XCTAssertEqual(later?.localizedDescription,
                       String(localized: "The database file is damaged. Restore a backup or a restore point, and don't keep using this file."),
                       "the page number stays in the error, not in the message")
    }

    func testAbsentKeyCannotOpenAnEncryptedStore() throws {
        let root = try makeRoot()
        _ = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        // A plaintext connection over an encrypted file must fail rather than
        // expose garbage rows.
        XCTAssertThrowsError(try Database(path: root.databaseURL.path))
    }

    func testTempStoreAndForeignKeysAreHardened() async throws {
        let root = try makeRoot()
        let db = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        // 2 is MEMORY: temp tables and sort spills never reach the disk.
        let tempStore = try await db.pragmaForTesting("temp_store")
        XCTAssertEqual(tempStore, "2")
        let foreignKeys = try await db.pragmaForTesting("foreign_keys")
        XCTAssertEqual(foreignKeys, "1")
        let trustedSchema = try await db.pragmaForTesting("trusted_schema")
        XCTAssertEqual(trustedSchema, "0")
        let violations = try await db.foreignKeyCheck()
        XCTAssertEqual(violations, 0)
        try await db.close()
    }

    // MARK: - Attachments

    func testAttachmentRoundTripAndWrongKey() async throws {
        let root = try makeRoot()
        let store = try EncryptedFileStore(
            root: root.attachmentsURL, key: TestKeys.attachment(for: root))
        let payload = Data("attachment bytes".utf8)
        let id = try await store.store(payload)
        XCTAssertTrue(EncryptedFileStore.isSafeStorageID(id))
        let roundTrip = try await store.read(storageID: id)
        XCTAssertEqual(roundTrip, payload)

        let otherKey = Data(repeating: 0x22, count: 32)
        let wrong = try EncryptedFileStore(root: root.attachmentsURL, key: otherKey)
        do {
            _ = try await wrong.read(storageID: id)
            XCTFail("a wrong attachment key must not decrypt")
        } catch {
            XCTAssertEqual(error as? EncryptedFileStore.StoreError, .corruptOrWrongKey)
        }
    }

    func testAttachmentBitFlipTruncationAndReorderingAreRejected() async throws {
        let root = try makeRoot()
        let store = try EncryptedFileStore(
            root: root.attachmentsURL, key: TestKeys.attachment(for: root))
        // Two chunks so reordering is representable.
        let payload = Data(repeating: 0x41, count: EncryptedFileStore.chunkSize + 1024)
        let id = try await store.store(payload)
        let url = try store.url(for: id)
        let original = try Data(contentsOf: url)

        let headerOffset = min(BackupArchiveV2.headerLength + 5, original.count - 1)
        var flipped = original
        flipped[headerOffset] ^= 0x01
        try flipped.write(to: url)
        await assertStoreReadFails(store, id)

        var truncated = original.prefix(original.count - 50)
        try truncated.write(to: url)
        await assertStoreReadFails(store, id)

        // Reorder the two sealed chunks (they live after the header).
        let headerLength = 4 + 1 + EncryptedFileStore.saltLength
            + SecretStream.XChaCha20Poly1305.HeaderBytes
        let firstChunk = EncryptedFileStore.chunkSize + SecretStream.XChaCha20Poly1305.ABytes
        var reordered = original.prefix(headerLength)
        reordered.append(original.subdata(in: (headerLength + firstChunk)..<original.count))
        reordered.append(original.subdata(in: headerLength..<(headerLength + firstChunk)))
        try reordered.write(to: url)
        await assertStoreReadFails(store, id)

        // Bytes after the final chunk are not covered by any tag.
        var appended = original
        appended.append(Data(repeating: 0x00, count: 16))
        try appended.write(to: url)
        await assertStoreReadFails(store, id)

        try original.write(to: url)
        let intact = try await store.read(storageID: id)
        XCTAssertEqual(intact, payload, "the untouched container still reads")
    }

    private func assertStoreReadFails(_ store: EncryptedFileStore, _ id: String,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await store.read(storageID: id)
            XCTFail("corrupted attachment must not decrypt", file: file, line: line)
        } catch {
            // expected
        }
    }

    func testAttachmentRejectsMaliciousStorageIDs() async throws {
        let root = try makeRoot()
        let store = try EncryptedFileStore(
            root: root.attachmentsURL, key: TestKeys.attachment(for: root))
        for bad in ["../escape", "a/b", ".", "..", "", "not-a-uuid", "\u{0}"] {
            XCTAssertFalse(EncryptedFileStore.isSafeStorageID(bad), "\(bad) must be refused")
            do {
                _ = try await store.read(storageID: bad)
                XCTFail("malicious id accepted: \(bad)")
            } catch {
                XCTAssertEqual(error as? EncryptedFileStore.StoreError, .maliciousIdentifier)
            }
        }
    }

    func testAttachmentExternalOpenUses0600AndCleanupRemovesIt() async throws {
        let root = try makeRoot()
        let store = try EncryptedFileStore(
            root: root.attachmentsURL, key: TestKeys.attachment(for: root))
        let id = try await store.store(Data("scan".utf8))
        let url = try await store.openExternally(storageID: id, preferredName: "scan.pdf")
        let folder = url.deletingLastPathComponent()
        // Only this test's own file, and its folder once empty: were the copy
        // to land in the app's folder, emptying that would delete the owner's.
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            if folder.standardizedFileURL != DataRoot.appExternalCopiesURL.standardizedFileURL {
                rmdir(folder.path)
            }
        }
        XCTAssertNotEqual(folder.standardizedFileURL, DataRoot.appExternalCopiesURL.standardizedFileURL,
                          "a store given no folder writes to its own, never the app's")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: url), Data("scan".utf8))

        await store.clearExternalTemporaries()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "locking must remove the plaintext temporary")
    }

    func testAttachmentReadAndCopyFailuresAreNotReportedAsBadCiphertext() async throws {
        let root = try makeRoot("attachment-failures")
        let key = TestKeys.attachment(for: root)
        let store = try EncryptedFileStore(root: root.attachmentsURL, key: key)
        let missing = try await store.store(Data("missing".utf8))
        try FileManager.default.removeItem(at: try store.url(for: missing))
        do {
            _ = try await store.read(storageID: missing)
            XCTFail("a missing attachment must not read")
        } catch {
            XCTAssertEqual(error as? EncryptedFileStore.StoreError, .unreadable)
            XCTAssertEqual(error.localizedDescription,
                           String(localized: "The attachment file couldn't be read. Check that it still exists and that you have permission to open it."))
        }

        // A plain file where the external-copy folder should be makes the
        // directory creation fail, as a full disk or a permission error would.
        let blocker = tempDir.appendingPathComponent("not-a-copy-folder-\(UUID().uuidString)")
        try Data("occupied".utf8).write(to: blocker)
        let blocked = try EncryptedFileStore(
            root: root.attachmentsURL, key: key, externalCopiesURL: blocker)
        let stored = try await blocked.store(Data("scan".utf8))
        do {
            _ = try await blocked.openExternally(storageID: stored, preferredName: "scan.pdf")
            XCTFail("a copy that cannot be written must not be opened")
        } catch {
            XCTAssertEqual(error as? EncryptedFileStore.StoreError, .externalCopyFailed)
            XCTAssertEqual(error.localizedDescription,
                           String(localized: "The attachment couldn't be opened because its temporary copy couldn't be saved. Free up disk space or check that the folder is writable, then try again."))
        }
    }

    func testAttachmentPaddingHidesLength() async throws {
        let root = try makeRoot()
        let store = try EncryptedFileStore(
            root: root.attachmentsURL, key: TestKeys.attachment(for: root))
        func size(of count: Int, byte: UInt8) async throws -> Int {
            let id = try await store.store(Data(repeating: byte, count: count))
            let attributes = try FileManager.default.attributesOfItem(atPath: try store.url(for: id).path)
            return try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
        }
        // The length header and the salt come before the bytes, inside the block.
        let fullBlock = EncryptedFileStore.paddingBlock - 8 - EncryptedFileStore.saltLength
        let oneByte = try await size(of: 1, byte: 0x01)
        let lastOfTheBlock = try await size(of: fullBlock, byte: 0x02)
        let firstOfTheNext = try await size(of: fullBlock + 1, byte: 0x03)
        XCTAssertEqual(oneByte, lastOfTheBlock,
                       "everything up to the block boundary pads to the same ciphertext size")
        XCTAssertGreaterThan(firstOfTheNext, lastOfTheBlock, "one byte past it is the next block")
    }

    // MARK: - Secure store coordinator

    func testPreflightClassifiesEveryStoreState() throws {
        let empty = try makeRoot("empty")
        let manager = InMemoryKeyManager()
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(dataRoot: empty, keyManager: manager), .empty)

        // A plaintext SQLite file is recognised by its header alone.
        let plaintext = try makeRoot("plaintext")
        try Data("SQLite format 3\u{0}rest".utf8).write(to: plaintext.databaseURL)
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(dataRoot: plaintext, keyManager: manager), .plaintextStore)

        // Encrypted bytes with a key present.
        let encrypted = try makeRoot("encrypted")
        _ = try Database(path: encrypted.databaseURL.path, key: TestKeys.database(for: encrypted))
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(
                dataRoot: encrypted, keyManager: InMemoryKeyManager(key: Data(repeating: 1, count: 32))),
            .encryptedStore)

        // Encrypted bytes with no key: recovery, never a fresh store.
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(dataRoot: encrypted, keyManager: InMemoryKeyManager()),
            .encryptedWithoutKey)

        // A key item that can never be a key is as good as missing.
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(
                dataRoot: encrypted, keyManager: ScriptedKeyManager(damaged: true)),
            .encryptedWithoutKey)

        // A cancelled prompt says nothing about the key: it is not a missing key.
        let cancelling = PromptingKeyManager(key: Data(repeating: 1, count: 32))
        cancelling.cancelsPrompts = true
        XCTAssertThrowsError(
            try SecureStoreCoordinator.preflight(dataRoot: encrypted, keyManager: cancelling)) { error in
            XCTAssertEqual(error as? SecureStoreError, .keyUnavailable(errSecUserCanceled))
        }
    }

    func testPreflightRefusesAMissingDatabaseBesideStoredData() async throws {
        let manager = InMemoryKeyManager()

        // An attachment object with no database to account for it.
        let withAttachment = try makeRoot("attachment-only")
        let files = try EncryptedFileStore.testStore(at: withAttachment.attachmentsURL)
        _ = try await files.store(Data("report".utf8))
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(dataRoot: withAttachment, keyManager: manager),
            .databaseMissing)

        // So is a restore point.
        let withRestorePoint = try makeRoot("restore-point-only")
        try Data("sealed".utf8).write(
            to: withRestorePoint.restorePointsURL.appendingPathComponent("restore_1.mnrp"))
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(dataRoot: withRestorePoint, keyManager: manager),
            .databaseMissing)

        // Files that are not storage IDs or restore points do not count.
        let strangers = try makeRoot("strangers")
        try Data("x".utf8).write(to: strangers.attachmentsURL.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: strangers.restorePointsURL.appendingPathComponent("notes.txt"))
        XCTAssertEqual(
            try SecureStoreCoordinator.preflight(dataRoot: strangers, keyManager: manager), .empty)
    }

    @MainActor
    func testAuthenticateLeavesAMissingDatabaseAndItsFilesAlone() async throws {
        let root = try makeRoot("missing-db")
        let files = try EncryptedFileStore.testStore(at: root.attachmentsURL)
        let storageID = try await files.store(Data("report".utf8))
        let manager = InMemoryKeyManager()
        let coordinator = SecureStoreCoordinator(keyManager: manager, dataRoot: root)

        XCTAssertThrowsError(try coordinator.authenticate()) { error in
            XCTAssertEqual(error as? SecureStoreError, .databaseMissing)
        }
        XCTAssertFalse(coordinator.isReady)
        XCTAssertEqual(try manager.lookUpRootKey(), .absent, "no key may be created for it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.databaseURL.path),
                       "no empty database may be created beside the attachments")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.attachmentsURL.appendingPathComponent(storageID).path))
    }

    @MainActor
    func testAuthenticateRefusesAnEncryptedStoreWhoseKeyIsMissing() throws {
        let root = try makeRoot()
        _ = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        let coordinator = SecureStoreCoordinator(
            keyManager: InMemoryKeyManager(), dataRoot: root)
        do {
            _ = try coordinator.authenticate()
            XCTFail("must not start an empty store over encrypted data")
        } catch {
            XCTAssertEqual(error as? SecureStoreError, .missingKeyForExistingStore)
        }
        XCTAssertFalse(coordinator.isReady)
    }

    /// A cancelled Touch ID prompt, a refused password or a locked keychain
    /// leaves the coordinator locked for a retry, never in the missing-key
    /// state that offers recovery; and each attempt reads the key once.
    @MainActor
    func testAuthenticateTreatsACancelledReadAsLockedNotMissing() throws {
        let root = try makeRoot()
        _ = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        let keys = PromptingKeyManager(key: TestKeys.root(for: root))
        let coordinator = SecureStoreCoordinator(keyManager: keys, dataRoot: root)

        keys.cancelsPrompts = true
        XCTAssertThrowsError(try coordinator.authenticate()) { error in
            XCTAssertEqual(error as? SecureStoreError, .keyUnavailable(errSecUserCanceled))
        }
        XCTAssertEqual(coordinator.state, .locked, "a cancelled prompt is retryable, not a failure")
        XCTAssertEqual(keys.readCount, 1)

        keys.cancelsPrompts = false
        XCTAssertEqual(try coordinator.authenticate(), .encryptedStore)
        XCTAssertEqual(keys.readCount, 2, "a successful unlock must prompt once, not twice")
        XCTAssertEqual(try coordinator.requireDatabaseKey(), TestKeys.database(for: root))
    }

    @MainActor
    func testCoordinatorLocksAndWipesKeys() throws {
        let root = try makeRoot()
        let manager = InMemoryKeyManager()
        let coordinator = SecureStoreCoordinator(keyManager: manager, dataRoot: root)
        _ = try coordinator.authenticate()
        XCTAssertNoThrow(try coordinator.requireDatabaseKey())
        coordinator.lock()
        XCTAssertThrowsError(try coordinator.requireDatabaseKey()) { error in
            XCTAssertEqual(error as? SecureStoreError, .locked)
        }
        XCTAssertEqual(coordinator.state, .locked)
    }

    @MainActor
    func testCoordinatorDerivesIndependentSubkeys() throws {
        let root = try makeRoot()
        let coordinator = SecureStoreCoordinator(keyManager: InMemoryKeyManager(), dataRoot: root)
        _ = try coordinator.authenticate()
        let database = try coordinator.requireDatabaseKey()
        let attachment = try coordinator.requireAttachmentKey()
        let restore = try coordinator.requireRestoreKey()
        XCTAssertEqual(Set([database, attachment, restore]).count, 3,
                       "every store must use a distinct derived key")
    }

    // MARK: - Migration

    /// Builds a plaintext store the way the old build wrote it and converts it.
    func testMigrationEncryptsAPlaintextStoreEndToEnd() async throws {
        let root = try makeRoot()
        // Seed a plaintext database.
        let plaintext = try Database(path: root.databaseURL.path)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Migration"
        patient.profile.lastName = "Test"
        patient.profile.amka = "12047812347"
        try await plaintext.savePatient(patient)
        let note = Note(title: "note", content: "UNIQUE-MIGRATION-MARKER")
        try await plaintext.saveNote(note)
        try await plaintext.close()

        // A portable backup first, as the wizard requires, then the migration.
        let backupURL = tempDir.appendingPathComponent("pre-migration.mednotesbackup")
        let keyManager = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keyManager)
        let plaintextReader = try Database(path: root.databaseURL.path)
        let backupService = BackupService(
            db: plaintextReader,
            fileStore: nil, restorePointsRoot: root.restorePointsURL)
        _ = try await backupService.createEncryptedBackup(
            name: "Pre-encryption", to: backupURL, passphrase: "a long enough passphrase")
        // The app closes it before the swap, which moves the file under it.
        await plaintextReader.close()

        let report = try await migrator.migrate(
            backupDestination: backupURL, passphrase: "a long enough passphrase")
        XCTAssertEqual(report.patients, 1)
        XCTAssertEqual(report.notes, 1)
        await migrator.finishCleanup()

        // The live database is now encrypted and still holds the records.
        let bytes = try Data(contentsOf: root.databaseURL)
        XCTAssertFalse(bytes.prefix(15) == Data("SQLite format 3".utf8))
        XCTAssertNil(bytes.range(of: Data("UNIQUE-MIGRATION-MARKER".utf8)))

        let rootKey = try XCTUnwrap(keyManager.rootKey())
        let databaseKey = try StoreKeyContext.subkey(
            rootKey: rootKey, context: StoreKeyContext.database)
        let reopened = try Database(path: root.databaseURL.path, key: databaseKey)
        let loaded = try await reopened.loadPatient(id: patient.id)
        XCTAssertEqual(loaded?.profile.firstName, "Migration")
        let fkViolations = try await reopened.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
        try await reopened.close()

        // No plaintext artifacts survive, except the old Markdown mirror: it
        // is kept for review (`LegacyVaultTests`).
        for leftover in ["Plaintext.old.db", "Plaintext.old.db-wal", "Plaintext.old.db-shm", "Plaintext.old.Attachments"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.rootURL.appendingPathComponent(leftover).path), "\(leftover) must be gone")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.filesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StoreMigrator.journalURL(in: root).path))
    }

    func testMigrationRefusesAnUnverifiableBackup() async throws {
        let root = try makeRoot()
        let plaintext = try Database(path: root.databaseURL.path)
        try await plaintext.savePatient(Patient.newRecord())
        try await plaintext.close()

        let badBackup = tempDir.appendingPathComponent("bad.mednotesbackup")
        try Data("not an archive".utf8).write(to: badBackup)
        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())
        do {
            _ = try await migrator.migrate(
                backupDestination: badBackup, passphrase: "a long enough passphrase")
            XCTFail("migration must not start without a verified backup")
        } catch {
            // expected
        }
        // The original store is untouched and still plaintext.
        XCTAssertTrue(SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL))
    }

    func testInterruptedMigrationRestoresBothOriginals() async throws {
        for attachmentsSwapped in [false, true] {
            let root = try makeRoot("interrupted-\(attachmentsSwapped)")
            let db = try Database(path: root.databaseURL.path)
            let patient = Patient.newRecord()
            try await db.savePatient(patient)
            await db.close()
            let fm = FileManager.default
            let oldDB = root.rootURL.appendingPathComponent("Plaintext.old.db")
            let oldAttachments = root.rootURL.appendingPathComponent("Plaintext.old.Attachments")
            let original = root.attachmentsURL.appendingPathComponent("original")
            try Data("original".utf8).write(to: original)
            try fm.moveItem(at: root.databaseURL, to: oldDB)
            try Data("encrypted substitute".utf8).write(to: root.databaseURL)
            if attachmentsSwapped {
                try fm.moveItem(at: root.attachmentsURL, to: oldAttachments)
                try fm.createDirectory(at: root.attachmentsURL, withIntermediateDirectories: true)
            }
            let journal = StoreMigrator.Journal(phase: .swapping, schemaVersion: Schema.currentVersion,
                recordCounts: [:], attachmentCount: 0, startedAt: Date(), updatedAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(journal).write(to: StoreMigrator.journalURL(in: root))

            let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())
            try await migrator.recoverInterruptedMigration()
            XCTAssertTrue(SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL))
            XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
            XCTAssertFalse(fm.fileExists(atPath: StoreMigrator.journalURL(in: root).path))
            let reopened = try Database(path: root.databaseURL.path)
            let restored = try await reopened.loadPatient(id: patient.id)
            XCTAssertNotNil(restored)
            await reopened.close()
        }
    }

    func testMigrationCrashAtEachPhaseLeavesTheOriginalIntact() async throws {
        for phase in StoreMigrator.Phase.allCases {
            let root = try makeRoot("crash-\(phase.rawValue)")
            let plaintext = try Database(path: root.databaseURL.path)
            try await plaintext.savePatient(Patient.newRecord())
            try await plaintext.close()

            // Simulate the crash by writing the journal and stopping before the
            // swap: the original must remain openable and readable.
            let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())
            let journalURL = StoreMigrator.journalURL(in: root)
            let journal = StoreMigrator.Journal(
                phase: phase, schemaVersion: Schema.currentVersion,
                recordCounts: ["patients": 1], attachmentCount: 0,
                startedAt: Date(), updatedAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(journal).write(to: journalURL)
            // What launch runs; `rollbackStaging` alone never touches the database.
            try await migrator.recoverInterruptedMigration()
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path),
                           "recovery must clear the journal at \(phase.rawValue)")
            XCTAssertTrue(SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL),
                          "the original store must survive a crash at \(phase.rawValue)")
            let check = try Database(path: root.databaseURL.path)
            let count = try await check.counts()["patients"]
            XCTAssertEqual(count, 1)
            try await check.close()
        }
    }

    /// Encrypted data plus a lost key is recovery, not a fresh store: a
    /// portable backup installs under a brand-new device key.
    func testRecoveryRestoresAPortableBackupWithANewKey() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Recovered"
        patient.profile.lastName = "Patient"
        try await store.patients.save(patient)
        try await store.notes.save(Note(title: "n", content: "RECOVER-MARKER"))

        let archive = tempDir.appendingPathComponent("recover.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "Recovery", to: archive, passphrase: "a long enough passphrase")
        await store.close()

        // The key is gone and the store is unreadable; a fresh manager has none.
        let manager = InMemoryKeyManager()
        let recovery = StoreRecovery(dataRoot: root, keyManager: manager)
        let report = try await recovery.recover(from: archive, passphrase: "a long enough passphrase")
        XCTAssertEqual(report.attachmentCount, 0)

        let rootKey = try XCTUnwrap(manager.rootKey())
        XCTAssertEqual(report.rootKey, rootKey, "the report hands back the key it stored")
        let databaseKey = try StoreKeyContext.subkey(
            rootKey: rootKey, context: StoreKeyContext.database)
        let reopened = try Database(path: root.databaseURL.path, key: databaseKey)
        let loaded = try await reopened.loadAllPatients()
        XCTAssertEqual(loaded.first?.profile.firstName, "Recovered")
        let notes = try await reopened.loadAllNotes()
        XCTAssertEqual(notes.first?.content, "RECOVER-MARKER")
        try await reopened.close()

        // The unreadable old bytes are gone.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.rootURL.appendingPathComponent("Unreadable.db").path))
    }

    func testRecoveryRejectsTheWrongPassphrase() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.patients.save(Patient.newRecord())
        let archive = tempDir.appendingPathComponent("recover-bad.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "Recovery", to: archive, passphrase: "the correct passphrase")
        await store.close()

        let original = try Data(contentsOf: root.databaseURL)
        let manager = InMemoryKeyManager()
        let recovery = StoreRecovery(dataRoot: root, keyManager: manager)
        do {
            _ = try await recovery.recover(from: archive, passphrase: "a wrong passphrase")
            XCTFail("a wrong passphrase must not recover")
        } catch {
            XCTAssertTrue(error is StoreRecovery.RecoveryError, "\(error)")
        }
        // The encrypted original is still in place, untouched, and no key was
        // created before the passphrase was proven.
        XCTAssertEqual(try Data(contentsOf: root.databaseURL), original)
        XCTAssertNil(try manager.rootKey())
        assertNothingSetAside(root)
    }

    // MARK: - Recovery with a key that may still be there

    /// A stand-in for the Keychain item that can be damaged (present, but
    /// never a valid key) and can refuse the write of a new key.
    private final class ScriptedKeyManager: KeyManager, @unchecked Sendable {
        private let lock = NSLock()
        private var key: Data?
        private var damaged: Bool
        private let refusesWrites: Bool

        init(key: Data? = nil, damaged: Bool = false, refusesWrites: Bool = false) {
            self.key = key
            self.damaged = damaged
            self.refusesWrites = refusesWrites
        }

        var isDamaged: Bool { lock.lock(); defer { lock.unlock() }; return damaged }
        var storedKey: Data? { lock.lock(); defer { lock.unlock() }; return key }

        func rootKey() throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            if damaged { throw KeyManagerError.invalidKeyLength(31) }
            return key
        }

        func createRootKey() throws -> Data {
            if let existing = try rootKey() { return existing }
            let fresh = StoreKeyContext.newRootKey()
            try storeRootKey(fresh)
            return fresh
        }

        func storeRootKey(_ newKey: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if refusesWrites { throw KeyManagerError.keychainFailure(errSecIO) }
            guard key == nil, !damaged else { throw KeyManagerError.keychainFailure(errSecDuplicateItem) }
            key = newKey
        }

        func deleteRootKey() throws {
            lock.lock(); defer { lock.unlock() }
            key = nil
            damaged = false
        }
    }

    private let recoveryPassphrase = "a long enough passphrase"

    /// A store with one patient, a portable backup of it, and then one more
    /// note the backup does not have: restoring over it would lose that note.
    private func storeWithBackup(_ root: DataRoot) async throws -> URL {
        let store = try AppStore.testStore(dataRoot: root)
        try await store.patients.save(Patient.newRecord())
        let archive = tempDir.appendingPathComponent("\(UUID().uuidString).mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "Recovery", to: archive, passphrase: recoveryPassphrase)
        try await store.notes.save(Note(title: "after", content: "AFTER-BACKUP-MARKER"))
        await store.close()
        return archive
    }

    /// A copy of `archive` with one byte flipped in the middle of its records.
    private func corruptCopy(of archive: URL) throws -> URL {
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count / 2] ^= 0xFF
        let corrupt = tempDir.appendingPathComponent("\(UUID().uuidString)-corrupt.mednotesbackup")
        try bytes.write(to: corrupt)
        return corrupt
    }

    /// The store still opens under its original key and still has the note
    /// written after the backup.
    private func assertOriginalStoreIntact(
        _ root: DataRoot, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let db = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        let notes = try await db.loadAllNotes()
        XCTAssertEqual(notes.map(\.content), ["AFTER-BACKUP-MARKER"],
                       "the live store must not be replaced", file: file, line: line)
        await db.close()
    }

    private func assertNothingSetAside(
        _ root: DataRoot, file: StaticString = #filePath, line: UInt = #line
    ) {
        for name in ["Unreadable.db", "Unreadable.db-wal", "Unreadable.db-shm", "Unreadable.Attachments"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.rootURL.appendingPathComponent(name).path),
                "\(name) must not be left behind", file: file, line: line)
        }
    }

    /// The original data-loss path: a key that still reads must never be
    /// deleted, and a healthy store must never be replaced by an older
    /// backup, even with the right passphrase.
    func testRecoveryNeverReplacesAStoreWhoseKeyIsStillThere() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let manager = InMemoryKeyManager(key: TestKeys.root(for: root))

        do {
            _ = try await StoreRecovery(dataRoot: root, keyManager: manager)
                .recover(from: archive, passphrase: recoveryPassphrase)
            XCTFail("recovery must refuse while the device key is present")
        } catch StoreRecovery.RecoveryError.deviceKeyPresent {
            // expected
        }
        XCTAssertEqual(try manager.rootKey(), TestKeys.root(for: root), "the key must survive")
        assertNothingSetAside(root)
        try await assertOriginalStoreIntact(root)
    }

    /// An existing key survives a failed recovery whatever the failure: a
    /// wrong passphrase or a damaged archive, whether the key reads or its
    /// prompt was cancelled.
    func testRecoveryWithAnExistingKeyKeepsItAndTheStore() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let corrupt = try corruptCopy(of: archive)
        let original = try Data(contentsOf: root.databaseURL)
        let key = TestKeys.root(for: root)

        let attempts: [(label: String, url: URL, passphrase: String)] = [
            ("wrong passphrase", archive, "a wrong passphrase"),
            ("corrupt archive", corrupt, recoveryPassphrase),
        ]
        for attempt in attempts {
            let readable = PromptingKeyManager(key: key)
            let cancelling = PromptingKeyManager(key: key)
            cancelling.cancelsPrompts = true
            for manager in [readable, cancelling] {
                let recovery = StoreRecovery(dataRoot: root, keyManager: manager)
                do {
                    _ = try await recovery.recover(from: attempt.url, passphrase: attempt.passphrase)
                    XCTFail("\(attempt.label): must not recover")
                } catch StoreRecovery.RecoveryError.deviceKeyPresent {
                    XCTAssertFalse(manager.cancelsPrompts, "\(attempt.label)")
                } catch SecureStoreError.keyUnavailable(let status) {
                    XCTAssertTrue(manager.cancelsPrompts, "\(attempt.label)")
                    XCTAssertEqual(status, errSecUserCanceled)
                }
                XCTAssertEqual(manager.storedKey, key, "\(attempt.label): the key must survive")
                XCTAssertEqual(try Data(contentsOf: root.databaseURL), original,
                               "\(attempt.label): the store must be untouched")
                assertNothingSetAside(root)
            }
        }
        try await assertOriginalStoreIntact(root)
    }

    /// With the key really gone, a damaged archive is caught before anything
    /// moves or any key is created.
    func testRecoveryRejectsACorruptArchiveBeforeTouchingAnything() async throws {
        let root = try makeRoot()
        let corrupt = try corruptCopy(of: try await storeWithBackup(root))
        let original = try Data(contentsOf: root.databaseURL)
        let manager = InMemoryKeyManager()

        do {
            _ = try await StoreRecovery(dataRoot: root, keyManager: manager)
                .recover(from: corrupt, passphrase: recoveryPassphrase)
            XCTFail("a corrupt archive must not recover")
        } catch StoreRecovery.RecoveryError.archiveInvalid {
            // expected
        }
        XCTAssertNil(try manager.rootKey(), "no key may be created for a backup that failed")
        XCTAssertEqual(try Data(contentsOf: root.databaseURL), original)
        assertNothingSetAside(root)
    }

    /// A key item that exists but can never be a key is replaced, and only
    /// once the backup has proven itself.
    func testRecoveryReplacesADamagedKeyOnlyAfterTheBackupValidates() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let manager = ScriptedKeyManager(damaged: true)
        let recovery = StoreRecovery(dataRoot: root, keyManager: manager)

        do {
            _ = try await recovery.recover(from: archive, passphrase: "a wrong passphrase")
            XCTFail("a wrong passphrase must not recover")
        } catch StoreRecovery.RecoveryError.archiveInvalid {
            // expected
        }
        XCTAssertTrue(manager.isDamaged, "the damaged item must not be deleted before validation")

        let report = try await recovery.recover(from: archive, passphrase: recoveryPassphrase)
        XCTAssertFalse(manager.isDamaged)
        XCTAssertEqual(manager.storedKey, report.rootKey)
        let databaseKey = try StoreKeyContext.subkey(
            rootKey: report.rootKey, context: StoreKeyContext.database)
        let reopened = try Database(path: root.databaseURL.path, key: databaseKey)
        let patients = try await reopened.loadAllPatients()
        XCTAssertEqual(patients.count, 1)
        await reopened.close()
    }

    /// The key is stored last. If the Keychain refuses it, the old database,
    /// its WAL and the old attachments go back exactly as they were.
    func testRecoveryPutsTheOldStoreBackWhenTheKeyCannotBeStored() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let wal = URL(fileURLWithPath: root.databaseURL.path + "-wal")
        try Data("old wal".utf8).write(to: wal)
        let attachment = root.attachmentsURL.appendingPathComponent("old-attachment")
        try Data("old attachment".utf8).write(to: attachment)
        let original = try Data(contentsOf: root.databaseURL)
        let manager = ScriptedKeyManager(refusesWrites: true)

        do {
            _ = try await StoreRecovery(dataRoot: root, keyManager: manager)
                .recover(from: archive, passphrase: recoveryPassphrase)
            XCTFail("recovery must fail when its key cannot be stored")
        } catch StoreRecovery.RecoveryError.installFailed {
            // expected
        }
        XCTAssertNil(manager.storedKey)
        XCTAssertEqual(try Data(contentsOf: root.databaseURL), original)
        XCTAssertEqual(try Data(contentsOf: wal), Data("old wal".utf8))
        XCTAssertEqual(try Data(contentsOf: attachment), Data("old attachment".utf8))
        assertNothingSetAside(root)
    }

    // MARK: - Locking

    @MainActor
    func testLockingClosesTheStoreAndClearsDisplayedRecords() async throws {
        let root = try makeRoot()
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady)
        let store = try XCTUnwrap(session.store)
        var patient = Patient.newRecord()
        patient.profile.lastName = "Lockhart"
        try await store.patients.save(patient)
        await session.reloadPatients()
        guard !session.patients.isEmpty else {
            return XCTFail("precondition: the store must have a loaded patient")
        }

        // Everything that shows a record outside the lists: an open editor
        // (its selection), the search fields, the quick switcher, and the
        // sheets and alerts that AppKit draws above the curtain.
        session.selectedPatientId = patient.id
        session.searchText = "ward"
        session.patientSearchText = "Lockhart"
        session.todoSearchText = "lab"
        session.eventSearchText = "clinic"
        session.showSwitcher = true
        session.switcherText = "Lockhart"
        await session.updateSwitcherResults()
        XCTAssertFalse(session.switcherResults.isEmpty, "precondition: the switcher shows the patient")
        session.backupFlow = .backUp
        session.importFlow = AppSession.ImportFlow(folderURL: tempDir)
        session.destinationFlow = Self.destinationFlow()
        session.confirmDelete = true
        session.notice = "Backed up"
        session.errorMessage = "Something failed"

        await session.lockNow(reason: "test")
        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.store, "locking must close the store")
        XCTAssertTrue(session.patients.isEmpty, "locking must clear displayed records")
        XCTAssertTrue(session.notes.isEmpty)
        XCTAssertNil(session.selectedPatientId, "the editor must not stay mounted under the curtain")
        XCTAssertNil(session.selectedNoteId)
        XCTAssertNil(session.selectedTodoId)
        XCTAssertNil(session.selectedEventId)
        XCTAssertEqual([session.searchText, session.patientSearchText,
                        session.todoSearchText, session.eventSearchText], ["", "", "", ""],
                       "a search field often holds a patient's name")
        XCTAssertFalse(session.showSwitcher)
        XCTAssertEqual(session.switcherText, "")
        XCTAssertTrue(session.switcherResults.isEmpty)
        XCTAssertNil(session.backupFlow, "sheets sit above the curtain and must be dismissed")
        XCTAssertNil(session.importFlow)
        XCTAssertNil(session.destinationFlow)
        XCTAssertFalse(session.confirmDelete)
        XCTAssertNil(session.notice)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.canUseStore, "the menu commands must be disabled while locked")
        session.presentBackup()
        XCTAssertNil(session.backupFlow, "no sheet may open over a locked window")

        // The lock is audited before the connection closes; the trail is only
        // readable again on unlock.
        await session.unlock()
        let activity = await session.recentActivity()
        XCTAssertTrue(activity.contains { $0.action == "app_lock" })
        XCTAssertEqual(session.selectedPatientId, patient.id, "unlocking returns to the open record")
        XCTAssertEqual(session.patientSearchText, "", "the search is not restored")
    }

    @MainActor
    func testUnlockRecreatesTheStore() async throws {
        let root = try makeRoot()
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await session.store?.patients.save(Patient.newRecord())
        await session.lockNow(reason: "test")
        await session.unlock()
        XCTAssertFalse(session.isLocked)
        await session.reloadPatients()
        XCTAssertEqual(session.patients.count, 1)
    }

    @MainActor
    func testSyncIsRefusedWhileLocked() async throws {
        let root = try makeRoot()
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "precondition: the session must open its store")

        // A confirmed destination, so that "refused" can only be the lock.
        let store = try XCTUnwrap(session.store)
        for (bridge, id) in [(SyncBridgeType.calendar, "cal-lock"), (.reminders, "list-lock")] {
            _ = try await store.destinations.confirm(bridge: bridge, candidate: SyncDestinationCandidate(
                calendarIdentifier: id, calendarTitle: "MedNotes", sourceIdentifier: "src",
                sourceTitle: "iCloud", sourceType: "calDAV", isAppCreated: true, recordCount: 1,
                transmittedFields: ["title"], requiresCloudAcknowledgment: true))
        }
        let calendarOpen = await session.maySync(.calendar)
        let remindersOpen = await session.maySync(.reminders)
        XCTAssertTrue(calendarOpen, "precondition: unlocked, with a confirmed destination, sync is allowed")
        XCTAssertTrue(remindersOpen)

        await session.lockNow(reason: "test")
        let calendarMaySync = await session.maySync(.calendar)
        let remindersMaySync = await session.maySync(.reminders)
        XCTAssertFalse(calendarMaySync)
        XCTAssertFalse(remindersMaySync)
    }

    /// The app menu's Lock MedNotes (⌃⌘L): the request runs the same path as
    /// the idle timer and the system events, so the store closes and the trail
    /// names it. The command's own availability travels with it.
    @MainActor
    func testLockOnRequestLocksAndAuditsTheReason() async throws {
        let session = try await readySession(try makeRoot())
        XCTAssertTrue(session.canUseStore, "precondition: the command is available")

        await session.lockOnRequest()
        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.store, "the request must close the store")
        XCTAssertTrue(session.patients.isEmpty)
        XCTAssertFalse(session.canUseStore, "the command must disable once locked")

        await session.unlock()
        let activity = await session.recentActivity()
        XCTAssertTrue(
            activity.contains { $0.action == "app_lock" && $0.details == "reason=request" },
            "the audit trail must name the request")
        XCTAssertTrue(session.canUseStore, "unlocking must re-enable the command")
    }

    // MARK: - Privacy curtain

    /// Counts key reads and can refuse them. In the app every read of the root
    /// key is a Keychain query behind Touch ID, so an unchanged count means no
    /// prompt, and `cancelsPrompts` answers the way a cancelled prompt does.
    private final class PromptingKeyManager: KeyManager, @unchecked Sendable {
        private let inner: InMemoryKeyManager
        private let lock = NSLock()
        private var reads = 0
        private var cancelling = false

        init(key: Data?) { inner = InMemoryKeyManager(key: key) }

        /// The key as stored, read without a prompt.
        var storedKey: Data? { try? inner.rootKey() }

        var readCount: Int {
            lock.lock(); defer { lock.unlock() }
            return reads
        }

        var cancelsPrompts: Bool {
            get { lock.lock(); defer { lock.unlock() }; return cancelling }
            set { lock.lock(); cancelling = newValue; lock.unlock() }
        }

        private func prompt() throws {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if cancelling { throw KeyManagerError.keychainFailure(errSecUserCanceled) }
        }

        func rootKey() throws -> Data? {
            try prompt()
            return try inner.rootKey()
        }

        func createRootKey() throws -> Data {
            try prompt()
            return try inner.createRootKey()
        }

        // Adding an item asks for nothing; only reads are behind Touch ID.
        func storeRootKey(_ key: Data) throws { try inner.storeRootKey(key) }

        func deleteRootKey() throws { try inner.deleteRootKey() }
    }

    /// A session with an open store. It is locked again at teardown, which
    /// closes its connection before the root is deleted and stops its idle
    /// timer and EventKit observers from outliving the test.
    @MainActor
    private func readySession(_ root: DataRoot, keyManager: KeyManager? = nil) async throws -> AppSession {
        let session = AppSession(
            dataRoot: root, defaults: defaults,
            keyManager: keyManager ?? InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "precondition: the session must open its store")
        return session
    }

    /// Suspends until `condition` holds or `seconds` pass. It sleeps rather
    /// than spinning the run loop: a nested run loop inside a main-actor job
    /// never drains the main queue, so a `Task` started by a handler would not
    /// run until the wait gave up.
    @MainActor
    private func wait(until condition: () -> Bool, seconds: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The wiring the app's own session sets up at launch: switching away
    /// raises the curtain over the main window and coming back lowers it.
    @MainActor
    func testBecomingActiveLiftsTheInactiveCurtain() async throws {
        let session = try await readySession(try makeRoot())
        session.observeAppActivation()
        let host = OffscreenHost()
        defer {
            host.tearDown()
            // The posts also reached everything else in the test host that
            // follows activation; leave it matching the host's real state.
            if !NSApp.isActive {
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            }
        }
        _ = host.host(ContentView().environmentObject(session), width: 1000, height: 600)
        // Hosted in an inactive test host, the window covers itself at once.
        session.appDidBecomeActive()
        XCTAssertFalse(session.isObscured, "precondition: the curtain is down")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(session.isObscured, "resigning active must raise the curtain")

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertFalse(session.isObscured, "becoming active again must lower the curtain")
        XCTAssertFalse(session.isLocked, "a quick app switch must not lock the store")
    }

    /// AppKit can deliver resign and become-active back to back when the main
    /// thread was busy; a resign applied late would re-raise the curtain on
    /// an active app, which is the stuck curtain this suite exists for.
    @MainActor
    func testBackToBackResignAndBecomeActiveLeaveTheCurtainDown() async throws {
        let session = try await readySession(try makeRoot())
        session.observeAppActivation()
        let host = OffscreenHost()
        defer {
            host.tearDown()
            if !NSApp.isActive {
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            }
        }
        _ = host.host(ContentView().environmentObject(session), width: 1000, height: 600)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        // Give anything the handlers deferred a chance to run.
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(session.isObscured, "the later become-active must win")
    }

    /// Window › Activity and Settings stay open after the main window is
    /// closed (⌘W), and ContentView goes with it. Switching away must still
    /// cover the audit trail, in Mission Control, App Exposé, screenshots and
    /// screen sharing: nothing but the Activity window is hosted here.
    @MainActor
    func testSwitchingAwayCoversTheActivityWindowWithoutTheMainWindow() async throws {
        let session = try await readySession(try makeRoot())
        session.observeAppActivation()
        let host = OffscreenHost()
        defer {
            host.tearDown()
            if !NSApp.isActive {
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            }
        }
        let hosting = host.host(ActivityView().environmentObject(session).privacyCover(session),
                                width: 760, height: 480)
        // A window restored by a launch in the background is covered from the
        // start, as the main window is.
        if !NSApp.isActive {
            XCTAssertTrue(session.isObscured, "a window that appears while the app is inactive must be covered")
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            hosting.window?.appearance = NSAppearance(named: appearance)
            session.appDidBecomeActive()
            XCTAssertFalse(session.isObscured, "precondition: the Activity window is uncovered")
            let bare = try await Self.snapshot(hosting)

            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            XCTAssertTrue(session.isObscured, "switching away must cover the Activity window")
            // Nothing else changed, so what differs is the cover: with none
            // drawn, nothing does. The bitmap cannot show how much it hides.
            // `cacheDisplay` draws the material as a flat, unblurred fill,
            // which on a dark Mac is nearly the dark window's own colour, so
            // there only the lock, the title and Unlock tell (about 6% of the
            // window, against 56-58% while the Mac is in light mode).
            let covered = try await Self.snapshot(hosting)
            let changed = Self.fractionChanged(bare, covered)
            XCTAssertGreaterThan(changed, 0.02,
                                 "\(appearance.rawValue): the cover must be drawn over the Activity window, not only raised")

            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            XCTAssertFalse(session.isObscured, "coming back must uncover it")
        }
    }

    /// The hosting view's pixels once SwiftUI has applied the latest state.
    @MainActor
    private static func snapshot(_ view: NSView) async throws -> NSBitmapImageRep {
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The share of sampled pixels that differ visibly between two captures.
    private static func fractionChanged(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var samples = 0, changed = 0
        for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh), by: 6) {
            for x in stride(from: 0, to: min(a.pixelsWide, b.pixelsWide), by: 6) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                samples += 1
                let difference = max(abs(p.redComponent - q.redComponent),
                                     abs(p.greenComponent - q.greenComponent),
                                     abs(p.blueComponent - q.blueComponent))
                if difference > 0.02 { changed += 1 }
            }
        }
        return samples == 0 ? 0 : Double(changed) / Double(samples)
    }

    @MainActor
    func testUnlockWhileOnlyObscuredKeepsTheOpenStore() async throws {
        let root = try makeRoot()
        let keys = PromptingKeyManager(key: TestKeys.root(for: root))
        let session = try await readySession(root, keyManager: keys)
        let open = try XCTUnwrap(session.store)
        let readsBefore = keys.readCount

        session.appDidResignActive()
        XCTAssertTrue(session.isObscured)
        await session.unlock()

        XCTAssertFalse(session.isObscured, "Unlock must lift a curtain raised by an app switch")
        XCTAssertFalse(session.isLocked)
        XCTAssertEqual(keys.readCount, readsBefore, "lifting the curtain must not ask for Touch ID")
        XCTAssertTrue(session.store === open, "an unlocked store must not be replaced by a second one")
        // The original connection is still open, not closed behind the UI.
        _ = try await open.counts()
    }

    @MainActor
    func testUnlockWhileInactiveKeepsTheCurtainUntilTheAppIsActive() async throws {
        let session = try await readySession(try makeRoot())

        session.appDidResignActive()
        await session.lockNow(reason: "screen")
        XCTAssertTrue(session.isLocked)
        XCTAssertTrue(session.isObscured)

        // The user switched away while the unlock was still reloading.
        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertNotNil(session.store)
        XCTAssertTrue(session.isObscured, "records must stay covered while the app is inactive")

        session.appDidBecomeActive()
        XCTAssertFalse(session.isObscured, "coming back must lower the curtain once the store is unlocked")
    }

    @MainActor
    func testRetryAfterACancelledUnlockClearsTheStaleError() async throws {
        let root = try makeRoot()
        let keys = PromptingKeyManager(key: TestKeys.root(for: root))
        let session = try await readySession(root, keyManager: keys)
        XCTAssertEqual(keys.readCount, 1, "launch must ask for the key once")
        await session.lockNow(reason: "test")

        keys.cancelsPrompts = true
        await session.unlock()
        XCTAssertTrue(session.isLocked, "a cancelled unlock must leave the store locked")
        XCTAssertFalse(session.needsRecovery, "a cancelled prompt is not a missing key")
        XCTAssertNil(session.store)
        XCTAssertEqual(session.initError, SecureStoreError.keyUnavailable(errSecUserCanceled).localizedDescription)
        XCTAssertNotEqual(session.initError, SecureStoreError.missingKeyForExistingStore.localizedDescription)
        XCTAssertEqual(session.coordinator?.state, .locked)
        XCTAssertThrowsError(try session.coordinator?.requireDatabaseKey(),
                             "a cancelled unlock must not leave keys installed")
        XCTAssertEqual(keys.readCount, 2, "one unlock is one prompt")

        keys.cancelsPrompts = false
        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertNotNil(session.store)
        XCTAssertNil(session.initError, "a successful retry must clear the cancelled attempt's error")
        XCTAssertEqual(keys.readCount, 3, "the retry must prompt once, not twice")
        XCTAssertEqual(keys.storedKey, TestKeys.root(for: root), "the key must survive the cancelled attempt")
    }

    /// Cancelling Touch ID at launch used to land on "the device key is
    /// missing" and offer recovery. It must leave the store locked instead,
    /// and Unlock must reopen the existing store.
    @MainActor
    func testCancelledPromptAtLaunchLocksInsteadOfOfferingRecovery() async throws {
        let root = try makeRoot()
        let seeded = try AppStore.testStore(dataRoot: root)
        try await seeded.patients.save(Patient.newRecord())
        await seeded.close()

        let keys = PromptingKeyManager(key: TestKeys.root(for: root))
        keys.cancelsPrompts = true
        let session = AppSession(dataRoot: root, defaults: defaults, keyManager: keys)
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        await wait(until: { session.isLocked || session.needsRecovery || session.initError != nil },
                   seconds: 20)
        XCTAssertTrue(session.isLocked, "a cancelled prompt at launch must leave the store locked")
        XCTAssertFalse(session.needsRecovery, "a cancelled prompt must never offer recovery")
        XCTAssertEqual(session.initError, SecureStoreError.keyUnavailable(errSecUserCanceled).localizedDescription)
        XCTAssertNil(session.store)
        XCTAssertEqual(keys.readCount, 1)

        keys.cancelsPrompts = false
        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertNil(session.initError)
        XCTAssertEqual(keys.readCount, 2)
        await session.reloadPatients()
        XCTAssertEqual(session.patients.count, 1, "Unlock must open the existing store")
    }

    /// A key item that is really gone cannot be unlocked by retrying, so the
    /// curtain switches from Unlock to recovery. Every store command, Lock
    /// MedNotes included, is unavailable in that state: a lock there would
    /// leave the session both locked and needing recovery.
    @MainActor
    func testUnlockWhoseKeyItemIsGoneOffersRecovery() async throws {
        let root = try makeRoot()
        let keys = InMemoryKeyManager(key: TestKeys.root(for: root))
        let session = try await readySession(root, keyManager: keys)
        await session.lockNow(reason: "test")
        try keys.deleteRootKey()

        await session.unlock()
        XCTAssertTrue(session.needsRecovery)
        XCTAssertFalse(session.isLocked)
        XCTAssertNil(session.store)
        XCTAssertEqual(session.initError, SecureStoreError.missingKeyForExistingStore.localizedDescription)
        XCTAssertFalse(session.canUseStore, "a session needing recovery has no store to lock")

        await session.lockOnRequest()
        XCTAssertTrue(session.needsRecovery, "the request must not lock a recovering session")
        XCTAssertFalse(session.isLocked)
        XCTAssertNil(session.store)
    }

    /// The curtain is an overlay on ContentView's root stack, so it is only as
    /// big as what the window shows. With `initError` set the window shows the
    /// startup error view, which sizes to its text, and the curtain shrank to
    /// a box in the middle of the window with the error around and behind it.
    /// The last check fails if the curtain moves off the banners onto
    /// `content`, which the corners alone would not notice.
    @MainActor
    func testTheCurtainCoversTheWholeWindowOverAStartupError() async throws {
        // A cancelled Touch ID unlock: locked, with the reason in initError.
        let cancelledRoot = try makeRoot("cancelled")
        let cancelledKeys = PromptingKeyManager(key: TestKeys.root(for: cancelledRoot))
        let cancelled = try await readySession(cancelledRoot, keyManager: cancelledKeys)
        await cancelled.lockNow(reason: "test")
        cancelledKeys.cancelsPrompts = true
        await cancelled.unlock()

        // A key item that is gone: the recovery curtain.
        let missingRoot = try makeRoot("missing")
        let missingKeys = InMemoryKeyManager(key: TestKeys.root(for: missingRoot))
        let missing = try await readySession(missingRoot, keyManager: missingKeys)
        await missing.lockNow(reason: "test")
        try missingKeys.deleteRootKey()
        await missing.unlock()

        // A store that will not open at launch, covered while inactive.
        let brokenRoot = try makeRoot("broken")
        try Data(repeating: 0x5A, count: 8192).write(to: brokenRoot.databaseURL)
        let broken = AppSession(
            dataRoot: brokenRoot, defaults: defaults,
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: brokenRoot)))
        addTeardownBlock { @MainActor in
            await broken.lockNow(reason: "teardown")
        }
        await wait(until: { broken.initError != nil || broken.isReady }, seconds: 20)
        broken.appDidResignActive()

        let window = CGSize(width: 1280, height: 820)
        for (state, session) in [("cancelled unlock", cancelled), ("missing key", missing),
                                 ("startup failure", broken)] {
            XCTAssertNotNil(session.initError, "precondition (\(state)): the window shows the error view")
            XCTAssertTrue(session.showsPrivacyCurtain, "precondition (\(state)): the curtain is up")

            // What the curtain overlays must take the whole window.
            let size = NSHostingController(rootView: ContentView().environmentObject(session))
                .sizeThatFits(in: window)
            XCTAssertEqual(size, window, "\(state): ContentView must fill the window it is offered")

            // Hosted the way the WindowGroup hosts it, no corner may stay bare.
            let host = OffscreenHost()
            defer { host.tearDown() }
            let hosting = host.hostAsWindowContent(
                ContentView().environmentObject(session).frame(minWidth: 1000, minHeight: 600),
                width: window.width, height: window.height)
            XCTAssertEqual(hosting.bounds.size, window, "\(state): ContentView must keep the window at its size")
            let corners = OffscreenHost.cornerAlphas(hosting)
            XCTAssertEqual(corners.count, 4)
            XCTAssertTrue(corners.allSatisfy { $0 > 0.9 },
                          "\(state): the curtain must cover every corner of the window, got alphas \(corners)")
        }

        // The banners share the curtain's stack, so the curtain covers them
        // too: raised, it mutes the banner's orange; lowered, the orange shows.
        broken.integrityWarning = "test"
        let host = OffscreenHost()
        defer { host.tearDown() }
        let hosting = host.hostAsWindowContent(
            ContentView().environmentObject(broken).frame(minWidth: 1000, minHeight: 600),
            width: window.width, height: window.height)
        let inBanner = CGPoint(x: 8, y: 6)
        let covered = try XCTUnwrap(OffscreenHost.color(at: inBanner, in: hosting))
        broken.appDidBecomeActive()
        XCTAssertFalse(broken.showsPrivacyCurtain, "precondition: the curtain is down")
        try await Task.sleep(nanoseconds: 100_000_000)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bare = try XCTUnwrap(OffscreenHost.color(at: inBanner, in: hosting))
        let difference = max(abs(covered.redComponent - bare.redComponent),
                             abs(covered.greenComponent - bare.greenComponent),
                             abs(covered.blueComponent - bare.blueComponent))
        XCTAssertGreaterThan(difference, 0.15,
                             "the curtain must cover the banner: bare \(bare), under the curtain \(covered)")
    }

    /// `.accessibilityHidden` takes what the curtain covers out of the
    /// accessibility tree but not out of focus: the first responder under it
    /// stays the app's focused element, readable by any app with
    /// Accessibility access, and its parents lead back into the hidden tree.
    /// Raising the curtain parks focus in every window; lifting it gives focus
    /// back where it was, a text field's caret included.
    @MainActor
    func testRaisingTheCurtainTakesFocusOutOfEveryWindow() async throws {
        let (session, note) = try await sessionShowingANote()
        let host = OffscreenHost()
        defer { host.tearDown() }
        let main = try XCTUnwrap(host.host(ContentView().environmentObject(session),
                                           width: 1280, height: 820).window)
        // A second window under PrivacyCover, as Settings and Activity are.
        let other = try XCTUnwrap(host.host(
            TextField("Name", text: .constant("Zqprobe name")).privacyCover(session),
            width: 400, height: 200).window)
        // The inactive test host raised the curtain as the windows appeared.
        session.appDidBecomeActive()
        let body = try await noteBody(in: main, showing: note.content)
        XCTAssertTrue(main.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: 5, length: 2))
        let field = try XCTUnwrap(Self.textFields(in: other.contentView).first)
        XCTAssertTrue(other.makeFirstResponder(field))
        field.currentEditor()?.selectedRange = NSRange(location: 3, length: 0)

        session.appDidResignActive()
        XCTAssertTrue(main.firstResponder === main, "the note body must not keep focus under the curtain")
        XCTAssertTrue(other.firstResponder === other, "a covered window's field must not keep focus")

        session.appDidBecomeActive()
        XCTAssertTrue(main.firstResponder === body, "focus must come back to the note body")
        XCTAssertEqual(body.selectedRange(), NSRange(location: 5, length: 2))
        XCTAssertTrue((other.firstResponder as? NSTextView)?.delegate === field, "focus must come back to the field")
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 3, length: 0),
                       "the field must get its caret back, not select all its text")
    }

    /// Focus that arrives under the curtain is parked as well. In the running
    /// app a window that finishes loading while covered gives its search field
    /// focus, and SwiftUI hands a field its focus back after a lock. The focus
    /// the user had is the one that comes back.
    @MainActor
    func testFocusTakenUnderTheCurtainIsParkedToo() async throws {
        let (session, note) = try await sessionShowingANote()
        let host = OffscreenHost()
        defer { host.tearDown() }
        let main = try XCTUnwrap(host.host(ContentView().environmentObject(session),
                                           width: 1280, height: 820).window)
        session.appDidBecomeActive()
        let body = try await noteBody(in: main, showing: note.content)
        let search = try XCTUnwrap(Self.textFields(in: main.contentView).first {
            ($0.placeholderString ?? $0.placeholderAttributedString?.string ?? "").contains("Search")
        }, "the note list's search field")
        XCTAssertTrue(main.makeFirstResponder(search))
        session.appDidResignActive()

        XCTAssertTrue(main.makeFirstResponder(body))
        await wait(until: { main.firstResponder === main }, seconds: 2)
        XCTAssertTrue(main.firstResponder === main, "focus taken under the curtain must be parked again")

        session.appDidBecomeActive()
        XCTAssertTrue((main.firstResponder as? NSTextView)?.delegate === search,
                      "the focus the user had comes back, not the one taken under the curtain")
    }

    /// A lock parks focus before it tears the editors down, in a view it
    /// leaves in place too, and the unlock never hands focus to a view that is
    /// no longer in the window.
    @MainActor
    func testALockParksFocusAndTheUnlockSkipsAnUnmountedEditor() async throws {
        let (session, note) = try await sessionShowingANote()
        let host = OffscreenHost()
        defer { host.tearDown() }
        let main = try XCTUnwrap(host.host(ContentView().environmentObject(session),
                                           width: 1280, height: 820).window)
        let other = try XCTUnwrap(host.host(
            TextField("Name", text: .constant("Zqprobe name")).privacyCover(session),
            width: 400, height: 200).window)
        session.appDidBecomeActive()
        let body = try await noteBody(in: main, showing: note.content)
        XCTAssertTrue(main.makeFirstResponder(body))
        let field = try XCTUnwrap(Self.textFields(in: other.contentView).first)
        XCTAssertTrue(other.makeFirstResponder(field))

        await session.lockNow(reason: "test")
        XCTAssertTrue(main.firstResponder === main, "the note body must not keep focus under the curtain")
        XCTAssertTrue(other.firstResponder === other, "a field the lock leaves in place must not keep focus")

        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertFalse(main.firstResponder === body, "focus must not go back to an editor the lock unmounted")
        XCTAssertTrue((other.firstResponder as? NSTextView)?.delegate === field,
                      "a field the lock left in place gets its focus back")
    }

    /// A lock clears the search fields it covers; the query typed before it
    /// must not come back with the focus.
    @MainActor
    func testALockDropsTheTextTypedBeforeIt() async throws {
        let (session, _) = try await sessionShowingANote()
        let host = OffscreenHost()
        defer { host.tearDown() }
        let main = try XCTUnwrap(host.host(ContentView().environmentObject(session),
                                           width: 1280, height: 820).window)
        session.appDidBecomeActive()
        let search = try XCTUnwrap(Self.textFields(in: main.contentView).first {
            ($0.placeholderString ?? $0.placeholderAttributedString?.string ?? "").contains("Search")
        }, "the note list's search field")
        XCTAssertTrue(main.makeFirstResponder(search))
        try XCTUnwrap(search.currentEditor() as? NSTextView)
            .insertText("Zq", replacementRange: NSRange(location: NSNotFound, length: 0))

        await session.lockNow(reason: "test")
        await session.unlock()
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView, "the search field gets its focus back")
        XCTAssertEqual(editor.string, "", "the query the lock cleared must stay cleared")
    }

    /// Parking ends an edit, which commits it: a number field then shows "72,"
    /// as "72", and a "5" typed after switching back would make it 725. What
    /// was being typed comes back with the focus.
    @MainActor
    func testAnAppSwitchKeepsANumberBeingTyped() async throws {
        let session = try await readySession(try makeRoot())
        let model = WeightModel()
        let host = OffscreenHost()
        defer { host.tearDown() }
        let window = try XCTUnwrap(host.host(WeightField(model: model).privacyCover(session),
                                             width: 400, height: 200).window)
        session.appDidBecomeActive()
        let field = try XCTUnwrap(Self.textFields(in: window.contentView).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let typed = "72" + (Locale.current.decimalSeparator ?? ".")
        let noSelection = NSRange(location: NSNotFound, length: 0)
        try XCTUnwrap(field.currentEditor() as? NSTextView).insertText(typed, replacementRange: noSelection)

        session.appDidResignActive()
        // Long enough for SwiftUI to show the committed value.
        try await Task.sleep(nanoseconds: 200_000_000)
        session.appDidBecomeActive()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.string, typed, "the text being typed must come back as typed")
        editor.insertText("5", replacementRange: noSelection)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.weight, 72.5)
    }

    /// Migration and recovery load no records, and their passphrase fields
    /// sit in the curtain itself: parked, no store could be encrypted or
    /// recovered.
    @MainActor
    func testTheRecoveryPassphraseFieldKeepsItsFocus() async throws {
        let root = try makeRoot()
        let keys = InMemoryKeyManager(key: TestKeys.root(for: root))
        let session = try await readySession(root, keyManager: keys)
        await session.lockNow(reason: "test")
        try keys.deleteRootKey()
        await session.unlock()
        XCTAssertTrue(session.needsRecovery, "precondition: the recovery curtain")
        let host = OffscreenHost()
        defer { host.tearDown() }
        let main = try XCTUnwrap(host.host(ContentView().environmentObject(session),
                                           width: 1280, height: 820).window)
        session.appDidBecomeActive()
        let passphrase = try XCTUnwrap(Self.textFields(in: main.contentView).first { $0 is NSSecureTextField },
                                       "the recovery passphrase field")

        XCTAssertTrue(main.makeFirstResponder(passphrase))
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue((main.firstResponder as? NSTextView)?.delegate === passphrase,
                      "the passphrase field must keep its focus")
    }

    /// A window opened under the curtain reports itself and is parked too.
    @MainActor
    func testAWindowOpenedUnderTheCurtainIsParked() async throws {
        let session = try await readySession(try makeRoot())
        await session.lockNow(reason: "test")
        let host = OffscreenHost()
        defer { host.tearDown() }
        let window = try XCTUnwrap(host.host(
            TextField("Name", text: .constant("Zqprobe name")).privacyCover(session),
            width: 400, height: 200).window)
        let field = try XCTUnwrap(Self.textFields(in: window.contentView).first)

        XCTAssertTrue(window.makeFirstResponder(field))
        await wait(until: { window.firstResponder === window }, seconds: 2)
        XCTAssertTrue(window.firstResponder === window, "a window opened under the curtain must not keep focus")
    }

    /// A ready session showing one saved note, with no title focus pending.
    @MainActor
    private func sessionShowingANote() async throws -> (AppSession, Note) {
        let session = try await readySession(try makeRoot())
        session.selectedModule = .notes
        await session.newNote()
        let loaded = await session.loadSelectedNote()
        var note = try XCTUnwrap(loaded)
        note.title = "Ward round"
        note.content = "Seen on the ward."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        _ = session.consumeFocusRequest(for: note.id)
        session.select(note.id)
        return (session, note)
    }

    /// The note body's text view once it shows `content`; the note loads async.
    @MainActor
    private func noteBody(in window: NSWindow, showing content: String) async throws -> NSTextView {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let found = Self.textViews(in: window.contentView).first(where: { $0.string == content }) {
                return found
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(nil as NSTextView?, "the note body never showed \(content.debugDescription)")
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let textView = view as? NSTextView { return [textView] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }

    private final class WeightModel: ObservableObject {
        @Published var weight: Double?
    }

    /// A number field like the patient editor's weight.
    private struct WeightField: View {
        @ObservedObject var model: WeightModel

        var body: some View {
            TextField("Weight", value: $model.weight, format: .number)
        }
    }

    /// Recovery from the curtain opens the restored store without asking for
    /// the new key again, and leaves the user's backup file where it was.
    @MainActor
    func testRecoveryFromTheCurtainOpensTheStoreAndKeepsTheBackup() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let keys = PromptingKeyManager(key: nil)
        let session = AppSession(dataRoot: root, defaults: defaults, keyManager: keys)
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        await wait(until: { session.needsRecovery || session.isReady }, seconds: 20)
        XCTAssertTrue(session.needsRecovery, "precondition: the key is missing")
        let readsBefore = keys.readCount

        try await session.recoverFromBackup(at: archive, passphrase: recoveryPassphrase)
        XCTAssertFalse(session.needsRecovery)
        XCTAssertFalse(session.isLocked)
        XCTAssertNil(session.initError)
        XCTAssertNotNil(session.store)
        XCTAssertEqual(keys.readCount, readsBefore + 1,
                       "only the recovery's own check reads the key; opening must not prompt again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "the user's backup must not be deleted")
        await session.reloadPatients()
        XCTAssertEqual(session.patients.count, 1)
    }

    /// Authentication succeeds and installs the keys, then the store fails to
    /// open. The session stays locked, so it must not keep those keys.
    @MainActor
    func testUnlockThatCannotOpenTheStoreWipesTheKeys() async throws {
        let root = try makeRoot()
        let session = try await readySession(root)
        await session.lockNow(reason: "test")

        let original = root.databaseURL.appendingPathExtension("original")
        try FileManager.default.moveItem(at: root.databaseURL, to: original)
        try Data(repeating: 0x5A, count: 8192).write(to: root.databaseURL)
        await session.unlock()
        XCTAssertTrue(session.isLocked, "a store that will not open must leave the session locked")
        XCTAssertNil(session.store)
        XCTAssertThrowsError(try session.coordinator?.requireDatabaseKey(),
                             "keys installed by a successful authentication must be wiped again")

        try FileManager.default.removeItem(at: root.databaseURL)
        try FileManager.default.moveItem(at: original, to: root.databaseURL)
        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertNil(session.initError)
    }

    @MainActor
    func testAReadInFlightWhenTheLockStartsDoesNotRefillRecords() async throws {
        let session = try await readySession(try makeRoot())
        try await session.store?.patients.save(Patient.newRecord())

        let reload = Task { await session.reloadPatients() }
        await Task.yield()
        await session.lockNow(reason: "test")
        await reload.value

        XCTAssertTrue(session.isLocked)
        XCTAssertTrue(session.patients.isEmpty, "a reload that finishes after the lock must not repopulate it")
    }

    @MainActor
    func testSecondUnlockWhileTheFirstIsInFlightOpensNoSecondStore() async throws {
        let session = try await readySession(try makeRoot())
        await session.lockNow(reason: "test")

        let first = Task { await session.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while session.store == nil, Date() < deadline {
            await Task.yield()
        }
        let opened = try XCTUnwrap(session.store, "the first unlock must publish its store")
        XCTAssertTrue(session.isLocked, "precondition: the first unlock is still reloading")

        await session.unlock()
        XCTAssertTrue(session.store === opened, "a second press must not open another store")
        await first.value
        XCTAssertTrue(session.store === opened)
        XCTAssertFalse(session.isLocked)
    }

    @MainActor
    func testUnlockPressedWhileTheLockIsStillClosingKeepsTheNewStore() async throws {
        let session = try await readySession(try makeRoot())
        try await session.store?.patients.save(Patient.newRecord())
        await session.reloadPatients()

        let lock = Task { await session.lockNow(reason: "test") }
        let deadline = Date().addingTimeInterval(10)
        while !session.isLocked, Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.store, "the lock must detach the store before it awaits the close")
        XCTAssertTrue(session.patients.isEmpty, "the lock must clear records before it awaits the close")

        await session.unlock()
        await lock.value

        XCTAssertFalse(session.isLocked)
        let store = try XCTUnwrap(session.store, "the finishing lock must not drop the reopened store")
        _ = try await store.counts()
        XCTAssertEqual(session.patients.count, 1, "the finishing lock must not clear the reloaded records")
    }

    /// The screen locks while an unlock is still reloading behind the curtain.
    /// The session is locked at that moment, so the request must not be
    /// dropped: the unlock closes the store it just opened instead of
    /// uncovering it.
    @MainActor
    func testLockRequestedWhileAnUnlockIsReloadingWins() async throws {
        let session = try await readySession(try makeRoot())
        try await session.store?.patients.save(Patient.newRecord())
        await session.lockNow(reason: "test")

        let unlock = Task { await session.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while session.store == nil, Date() < deadline {
            await Task.yield()
        }
        let reopened = try XCTUnwrap(session.store, "the unlock must publish its store")
        XCTAssertTrue(session.isLocked, "precondition: the unlock is still reloading")

        await session.lockNow(reason: "screen-lock")
        await unlock.value

        XCTAssertTrue(session.isLocked, "a lock requested during the unlock must win")
        XCTAssertNil(session.store, "the reopened store must be detached again")
        XCTAssertTrue(session.patients.isEmpty, "records reloaded behind the curtain must be cleared")
        XCTAssertThrowsError(try session.coordinator?.requireDatabaseKey(),
                             "the keys the unlock installed must be wiped again")
        do {
            _ = try await reopened.counts()
            XCTFail("the reopened connection must be closed")
        } catch {
            // expected
        }

        // The request was consumed: the next unlock stays unlocked, and the
        // trail names the event that locked the session.
        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertNotNil(session.store)
        let activity = await session.recentActivity()
        XCTAssertTrue(activity.contains { $0.action == "app_lock" && $0.details == "reason=screen-lock" })
    }

    /// Each system event locks through the center it is posted on. Private
    /// centers stand in for NSWorkspace's and the distributed one: posting on
    /// the real ones would also lock the test host's own session.
    @MainActor
    func testEverySystemLockEventLocksTheStore() async throws {
        for event in AppSession.SystemLockEvent.all {
            let session = try await readySession(try makeRoot())
            let workspace = NotificationCenter()
            let distributed = NotificationCenter()
            session.observeSystemLockEvents(workspace: workspace, distributed: distributed)

            // The other center carries nothing for this event.
            (event.isDistributed ? workspace : distributed).post(name: event.name, object: nil)
            for _ in 0..<5 { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertFalse(session.isLocked, "\(event.reason) must only be observed where it is posted")

            (event.isDistributed ? distributed : workspace).post(name: event.name, object: nil)
            await wait { session.isLocked && session.store == nil }
            XCTAssertTrue(session.isLocked, "\(event.reason) must lock the store")
            XCTAssertNil(session.store, "\(event.reason) must close the store")

            // The lock writes its audit entry after the store is detached, so
            // poll: this also keeps the old connection from outliving the test.
            await session.unlock()
            var audited = false
            let deadline = Date().addingTimeInterval(5)
            while !audited, Date() < deadline {
                audited = await session.recentActivity().contains { $0.details == "reason=\(event.reason)" }
                if !audited { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            XCTAssertTrue(audited, "the audit trail must name \(event.reason)")
        }
    }

    /// AppKit suspends distributed notifications while the app is inactive,
    /// which is where MedNotes often is when the screen locks. The lock must
    /// arrive then, not when the user next comes back to the app. The name is
    /// one only this test posts, so no real session observes it.
    @MainActor
    func testADistributedLockEventArrivesWhileDeliveryIsSuspended() async throws {
        let session = try await readySession(try makeRoot())
        let center = DistributedNotificationCenter.default()
        let event = AppSession.SystemLockEvent(
            name: Notification.Name("com.johnteam.MedNotes.tests.lock-\(UUID().uuidString)"),
            reason: "test-distributed", isDistributed: true)
        session.observeSystemLockEvents([event], workspace: NotificationCenter(), distributed: center)

        let wasSuspended = center.suspended
        center.suspended = true
        defer { center.suspended = wasSuspended }
        // Not `deliverImmediately`: that would override a coalescing
        // observer and prove nothing.
        center.postNotificationName(event.name, object: nil, userInfo: nil, deliverImmediately: false)
        await wait(until: { session.isLocked && session.store == nil }, seconds: 10)
        XCTAssertTrue(session.isLocked, "a lock event must arrive while distributed delivery is suspended")
    }

    @MainActor
    func testPreviewStoreKeyIsAValidDeviceKey() throws {
        XCTAssertEqual(AppSession.previewStoreKey.count, 32)
        let coordinator = SecureStoreCoordinator(
            keyManager: InMemoryKeyManager(key: AppSession.previewStoreKey), dataRoot: try makeRoot())
        _ = try coordinator.authenticate()
        XCTAssertNoThrow(try coordinator.requireDatabaseKey())
    }

    // MARK: - Sync destination state

    func testDestinationWritesOnlyAfterConsentAndGoesStaleAfterRestore() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let candidate = SyncDestinationCandidate(
            calendarIdentifier: "cal-1", calendarTitle: "MedNotes",
            sourceIdentifier: "src-1", sourceTitle: "iCloud", sourceType: "calDAV",
            isAppCreated: true, recordCount: 3, transmittedFields: ["title"],
            requiresCloudAcknowledgment: true)

        // No destination: no writes.
        let none = try await store.destinations.destination(for: .calendar)
        XCTAssertFalse(SyncDestinationCore.mayWrite(none))

        let confirmed = try await store.destinations.confirm(bridge: .calendar, candidate: candidate)
        XCTAssertTrue(confirmed.mayReceiveWrites)
        XCTAssertNotNil(confirmed.consentAt)

        // A restore suspends it.
        try await store.db.suspendSyncDestinations()
        let stale = try await store.destinations.destination(for: .calendar)
        XCTAssertEqual(stale?.state, .needsReconnection)
        XCTAssertFalse(SyncDestinationCore.mayWrite(stale))
    }

    /// Rechoosing a destination updates the row in place. The row's id is what
    /// the EventKit markers and the object map point at, so the value returned
    /// by a second confirmation must stay the same.
    func testReconfirmingADestinationKeepsItsIdentity() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let firstCandidate = SyncDestinationCandidate(
            calendarIdentifier: "cal-1", calendarTitle: "MedNotes",
            sourceIdentifier: "src-1", sourceTitle: "iCloud", sourceType: "calDAV",
            isAppCreated: true, recordCount: 0, transmittedFields: [],
            requiresCloudAcknowledgment: true)
        let secondCandidate = SyncDestinationCandidate(
            calendarIdentifier: "cal-2", calendarTitle: "MedNotes 2",
            sourceIdentifier: "src-2", sourceTitle: "iCloud", sourceType: "calDAV",
            isAppCreated: false, recordCount: 0, transmittedFields: [],
            requiresCloudAcknowledgment: true)

        let first = try await store.destinations.confirm(bridge: .calendar, candidate: firstCandidate)
        let second = try await store.destinations.confirm(bridge: .calendar, candidate: secondCandidate)
        XCTAssertEqual(first.id, second.id, "reconfirmation allocated a new destination id")
        let stored = try await store.destinations.destination(for: .calendar)
        XCTAssertEqual(stored?.id, first.id)
        XCTAssertEqual(stored?.calendarIdentifier, "cal-2")
    }

    func testDestinationWithADifferentIdentifierIsNotMatchedByTitle() {
        let destination = SyncDestination(
            bridgeType: .calendar, calendarIdentifier: "cal-A", calendarTitle: "MedNotes",
            sourceIdentifier: "src-A", sourceTitle: "iCloud", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
        // A calendar with the same title but a different identifier is not it.
        XCTAssertFalse(SyncDestinationCore.destinationIsCurrent(
            destination, existingCalendarIdentifiers: ["cal-B"],
            existingSourceIdentifiers: ["src-A"]))
        XCTAssertFalse(SyncDestinationCore.destinationIsCurrent(
            destination, existingCalendarIdentifiers: ["cal-A"],
            existingSourceIdentifiers: ["src-B"]))
        XCTAssertTrue(SyncDestinationCore.destinationIsCurrent(
            destination, existingCalendarIdentifiers: ["cal-A"],
            existingSourceIdentifiers: ["src-A"]))
    }

    func testLegacyMappingsPreselectOnlyAUniqueCandidate() {
        let a = SyncDestinationCandidate(
            calendarIdentifier: "cal-A", calendarTitle: "A", sourceIdentifier: "s",
            sourceTitle: "S", sourceType: "calDAV", isAppCreated: false,
            recordCount: 0, transmittedFields: [], requiresCloudAcknowledgment: true)
        let b = SyncDestinationCandidate(
            calendarIdentifier: "cal-B", calendarTitle: "B", sourceIdentifier: "s",
            sourceTitle: "S", sourceType: "calDAV", isAppCreated: false,
            recordCount: 0, transmittedFields: [], requiresCloudAcknowledgment: true)
        let unique = [SyncDestinationStore.ObjectMapping(
            localID: "n1", remoteIdentifier: "cal-A", marker: "MN-0123456789abcdef")]
        XCTAssertEqual(
            SyncDestinationCore.preselectLegacyCandidate(mappings: unique, candidates: [a, b]),
            a)
        let ambiguous = unique + [SyncDestinationStore.ObjectMapping(
            localID: "n2", remoteIdentifier: "cal-B", marker: "MN-0123456789abcdef")]
        XCTAssertNil(SyncDestinationCore.preselectLegacyCandidate(
            mappings: ambiguous, candidates: [a, b]),
            "multiple legacy candidates must open the chooser")
        XCTAssertNil(SyncDestinationCore.preselectLegacyCandidate(mappings: [], candidates: [a, b]))
    }

    func testOwnershipRequiresDestinationAndMarker() {
        let destination = SyncDestination(
            bridgeType: .calendar, calendarIdentifier: "cal-A", calendarTitle: "MedNotes",
            sourceIdentifier: "src", sourceTitle: "S", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
        XCTAssertTrue(SyncDestinationCore.ownsRemoteObject(
            marker: destination.id.uuidString, destination: destination, inDestination: true))
        XCTAssertTrue(SyncDestinationCore.ownsRemoteObject(
            marker: "MN-0123456789abcdef", destination: destination, inDestination: true))
        XCTAssertFalse(SyncDestinationCore.ownsRemoteObject(
            marker: nil, destination: destination, inDestination: true),
            "an untagged object is not MedNotes-owned, whatever its title")
        XCTAssertFalse(SyncDestinationCore.ownsRemoteObject(
            marker: "MN-0123456789abcdef", destination: destination, inDestination: false),
            "an object outside the destination is never touched")
    }

    // MARK: - Log redaction

    func testSecurityLogOpaqueIDsDoNotRevealPaths() {
        let url = URL(fileURLWithPath: "/Users/someone/Patients/Γεώργιος Παπαδόπουλος.pdf")
        let id = SecurityLog.opaqueID(for: url)
        XCTAssertFalse(id.contains("Γεώργιος"))
        XCTAssertFalse(id.contains("/Users"))
        XCTAssertEqual(id.count, 16)
        XCTAssertEqual(SecurityLog.opaqueID(for: url), id, "opaque ids are stable")
    }

    // MARK: - Idle lock

    @MainActor private var idle: TimeInterval { SecureStoreCoordinator.idleInterval }
    /// Where `insertText` puts text when given no range: at the caret.
    private let atCaret = NSRange(location: NSNotFound, length: 0)

    /// A moment after everything that already counted, such as the store opening.
    private func settledMoment() async throws -> Date {
        try await Task.sleep(nanoseconds: 50_000_000)
        return Date()
    }

    /// Counts the session's input as in an active app, until the test ends.
    @MainActor
    private func observeInput(_ session: AppSession) {
        session.observeUserInput(isAppActive: { true })
        addTeardownBlock { @MainActor in session.stopObservingUserInput() }
    }

    /// A session showing a note in ContentView, in a window keys can be typed
    /// into, with the body focused and the caret at its end.
    @MainActor
    private func typingIntoANote() async throws -> (AppSession, TypingWindow, NSTextView) {
        let (session, note) = try await sessionShowingANote()
        let host = OffscreenHost()
        addTeardownBlock { @MainActor in host.tearDown() }
        let window = try host.hostForTyping(ContentView().environmentObject(session))
        // The inactive test host raised the curtain as the window appeared,
        // and the curtain keeps focus out of the window.
        session.appDidBecomeActive()
        let body = try await noteBody(in: window, showing: note.content)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        return (session, window, body)
    }

    /// A trackpad scroll as it begins, for no window. Built, never posted.
    private static func scroll() throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: -4, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    /// A button press and release for no window, at a point off every screen.
    private static func click(_ down: NSEvent.EventType, _ up: NSEvent.EventType) throws -> [NSEvent] {
        try [down, up].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: -30000, y: -30000), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == down ? 1 : 0))
        }
    }

    /// The reported bug: a doctor typing a long note without touching the
    /// pointer was locked out after five minutes. The key goes through
    /// `NSApplication.sendEvent` into the note body, and it is the event
    /// monitor that counts it: the text observer leaves typed text alone.
    @MainActor
    func testTypingPostponesTheIdleLock() async throws {
        let (session, window, body) = try await typingIntoANote()
        observeInput(session)
        let typed = try await settledMoment()
        try window.type("k")
        XCTAssertTrue(body.string.hasSuffix("k"), "the monitor must pass the key on to the note body")
        XCTAssertGreaterThanOrEqual(session.lastInteraction, typed, "typing must postpone the idle lock")
        await session.lockIfIdle(now: session.lastInteraction.addingTimeInterval(idle - 1))
        XCTAssertFalse(session.isLocked, "a key typed 4:59 ago keeps the store open")
        await session.lockIfIdle(now: session.lastInteraction.addingTimeInterval(idle))
        XCTAssertTrue(session.isLocked, "five minutes after the last key, the idle lock still comes")
        XCTAssertNil(session.store)
    }

    /// A held key repeats for as long as it is held, and a book or a cat on
    /// the keyboard holds one with nobody there, filling the note as it goes.
    /// Only the press counts; neither the repeats nor the text they type do.
    @MainActor
    func testAHeldKeyDoesNotKeepTheStoreOpen() async throws {
        let (session, window, body) = try await typingIntoANote()
        observeInput(session)
        try window.deliver(.keyDown, "r")
        let held = try await settledMoment()
        for _ in 0..<3 { try window.deliver(.keyDown, "r", isARepeat: true) }
        try window.deliver(.keyUp, "r")
        XCTAssertTrue(body.string.hasSuffix("rrrr"), "precondition: the repeats reached the body and posted text changes")
        XCTAssertLessThan(session.lastInteraction, held, "a held key must not postpone the idle lock")
        await session.lockIfIdle(now: held.addingTimeInterval(idle))
        XCTAssertTrue(session.isLocked, "five minutes after the press it locks, key still held")
    }

    /// Dictation inserts each phrase through the text input system with no
    /// key event, as the emoji picker and Voice Control do; `insertText` is
    /// that path. Only the focused text view counts.
    @MainActor
    func testDictatedTextPostponesTheIdleLock() async throws {
        let (session, window, body) = try await typingIntoANote()
        observeInput(session)
        // As in the app, the last key was released before dictating.
        try window.deliver(.keyUp, "k")
        var before = try await settledMoment()
        body.insertText(" Dictated.", replacementRange: atCaret)
        XCTAssertTrue(body.string.hasSuffix(" Dictated."), "precondition: the text reached the note body")
        XCTAssertGreaterThanOrEqual(session.lastInteraction, before, "dictated text must postpone the idle lock")
        XCTAssertTrue(window.makeFirstResponder(nil))
        before = try await settledMoment()
        body.insertText(" Unfocused.", replacementRange: atCaret)
        XCTAssertLessThan(session.lastInteraction, before, "text in a view nobody is typing in does not count")
    }

    /// A microphone left on keeps transcribing whoever talks nearby, and
    /// macOS keeps dictating while anyone does. Dictated text keeps the store
    /// open only for a while after someone last touched the Mac, and only a
    /// touch starts that allowance over.
    @MainActor
    func testDictationAloneKeepsTheStoreOpenOnlyForAWhile() async throws {
        let (session, window, body) = try await typingIntoANote()
        observeInput(session)
        try window.type("k")
        let touched = session.lastInteraction
        let allowance = AppSession.dictationAllowance

        let stillDictating = touched.addingTimeInterval(allowance - 1)
        session.clock = { stillDictating }
        body.insertText(" Still dictating.", replacementRange: atCaret)
        XCTAssertEqual(session.lastInteraction, stillDictating, "dictation within the allowance keeps the store open")

        let walkedAway = touched.addingTimeInterval(allowance + 1)
        session.clock = { walkedAway }
        body.insertText(" Someone else talking.", replacementRange: atCaret)
        XCTAssertTrue(body.string.hasSuffix(" Someone else talking."), "precondition: the text reached the note body")
        XCTAssertEqual(session.lastInteraction, stillDictating, "an open microphone must not keep the store open for ever")

        try window.type("j")
        XCTAssertEqual(session.lastInteraction, walkedAway, "precondition: the key counted")
        let backAgain = walkedAway.addingTimeInterval(60)
        session.clock = { backAgain }
        body.insertText(" Back.", replacementRange: atCaret)
        XCTAssertEqual(session.lastInteraction, backAgain, "a key press must start the allowance over")
    }

    /// The app's own session follows the system: its lock events, the app's
    /// activation and the user's input. That wiring is in `init`, which the
    /// test host's own session never reaches, so a test session asks for it.
    /// Input counts only while MedNotes is active there too.
    @MainActor
    func testTheAppsOwnSessionFollowsTheSystem() async throws {
        let plain = try await readySession(try makeRoot())
        XCTAssertFalse(plain.isFollowingSystem, "a test's session must not follow the tester's Mac")

        let root = try makeRoot("follows")
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)),
                                 followsSystem: true)
        addTeardownBlock { @MainActor in
            session.stopObservingUserInput()
            await session.lockNow(reason: "teardown")
        }
        XCTAssertTrue(session.isFollowingSystem, "system lock events, activation and input must all be observed")
        await wait(until: { session.isReady }, seconds: 20)
        XCTAssertTrue(session.isReady, "precondition: the store opened")

        try XCTSkipIf(NSApp.isActive, "the test host is active; the gate cannot be seen closed")
        let before = try await settledMoment()
        NSApp.sendEvent(try Self.scroll())
        XCTAssertLessThan(session.lastInteraction, before, "input must count only while MedNotes is active")
    }

    private final class DraftModel: ObservableObject {
        @Published var title = "Clinic"
        @Published var details = "Bring the referral."
    }

    /// An event editor's two kinds of text, as `EventEditorForm` has.
    private struct DraftFields: View {
        @ObservedObject var model: DraftModel

        var body: some View {
            VStack {
                TextField("Title", text: $model.title)
                TextEditor(text: $model.details)
            }
        }
    }

    /// Text the app sets itself is nobody using MedNotes. The calendar sync
    /// reloads the open event, and SwiftUI pushes the new title into the field
    /// being edited, which posts from the field editor. A template or reload
    /// pushed into a TextEditor posts nothing; this pins it in case SwiftUI
    /// starts posting. Dictation into a field goes uncounted with the push:
    /// the notification cannot tell them apart.
    @MainActor
    func testTextTheAppSetsDoesNotPostponeTheIdleLock() async throws {
        let session = try await readySession(try makeRoot())
        observeInput(session)
        let model = DraftModel()
        let host = OffscreenHost()
        addTeardownBlock { @MainActor in host.tearDown() }
        let window = try host.hostForTyping(DraftFields(model: model), width: 480, height: 320)
        let details = try XCTUnwrap(Self.textViews(in: window.contentView).first { !$0.isFieldEditor })
        let title = try XCTUnwrap(Self.textFields(in: window.contentView).first { $0.isEditable })
        var posts = 0
        let counter = NotificationCenter.default.publisher(for: NSText.didChangeNotification)
            .sink { _ in posts += 1 }
        defer { counter.cancel() }

        XCTAssertTrue(window.makeFirstResponder(title))
        let fieldEditor = try XCTUnwrap(title.currentEditor() as? NSTextView)
        var before = try await settledMoment()
        model.title = "Moved in Calendar"
        await wait(until: { fieldEditor.string == "Moved in Calendar" }, seconds: 2)
        XCTAssertGreaterThan(posts, 0, "precondition: the push into the field being edited posts")
        XCTAssertLessThan(session.lastInteraction, before, "a sync pushed into a focused field is nobody typing")
        before = try await settledMoment()
        fieldEditor.insertText(" x", replacementRange: atCaret)
        XCTAssertLessThan(session.lastInteraction, before, "a field editor's text never counts; its keys do")

        XCTAssertTrue(window.makeFirstResponder(details))
        posts = 0
        before = try await settledMoment()
        model.details = "From a template"
        await wait(until: { details.string == "From a template" }, seconds: 2)
        XCTAssertEqual(details.string, "From a template", "precondition: the push reached the editor")
        XCTAssertEqual(posts, 0, "a TextEditor push must post nothing, or templates and sync reloads would count")
        XCTAssertLessThan(session.lastInteraction, before)
    }

    /// Nothing counts while another app is in front. AppKit still hands an
    /// inactive MedNotes keys, scrolls and text changes, and the pointer may
    /// cross its covered window. This is the real `NSApp.isActive`.
    @MainActor
    func testInputWhileAnotherAppIsActiveDoesNotCount() async throws {
        try XCTSkipIf(NSApp.isActive, "the test host is active; the gate cannot be seen closed")
        let (session, window, body) = try await typingIntoANote()
        session.observeUserInput()
        addTeardownBlock { @MainActor in session.stopObservingUserInput() }
        var before = try await settledMoment()
        try window.type("i")
        XCTAssertTrue(body.string.hasSuffix("i"), "precondition: the key reached the note body")
        XCTAssertLessThan(session.lastInteraction, before, "a key")
        before = try await settledMoment()
        body.insertText(" x", replacementRange: atCaret)
        XCTAssertLessThan(session.lastInteraction, before, "dictated text")
        before = try await settledMoment()
        NSApp.sendEvent(try Self.scroll())
        XCTAssertLessThan(session.lastInteraction, before, "a scroll")
        before = try await settledMoment()
        session.noteInteraction()
        XCTAssertLessThan(session.lastInteraction, before, "the pointer crossing a covered window")
    }

    /// Opening the store (at launch or on unlock) and coming back to MedNotes
    /// start the idle minutes over whatever AppKit reports: gated like input,
    /// a store opened behind a slow Touch ID prompt or a long migration, or
    /// unlocked in the background, would lock again at the next check.
    @MainActor
    func testOpeningTheStoreAndComingBackRestartTheIdleClock() async throws {
        try XCTSkipIf(NSApp.isActive, "the test host is active; the gate cannot be seen closed")
        let root = try makeRoot()
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        // The launch opens the store in a task that has not run yet.
        let created = Date()
        await wait(until: { session.isReady }, seconds: 20)
        XCTAssertTrue(session.isReady, "precondition: the store opened")
        XCTAssertGreaterThan(session.lastInteraction, created, "opening the store at launch must restart the idle minutes")

        let center = NotificationCenter()
        session.observeAppActivation(center)
        await session.lockNow(reason: "test")
        var before = try await settledMoment()
        await session.unlock()
        XCTAssertFalse(session.isLocked, "precondition: the store reopened")
        XCTAssertGreaterThanOrEqual(session.lastInteraction, before, "unlocking must restart the idle minutes")
        before = try await settledMoment()
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertGreaterThanOrEqual(session.lastInteraction, before, "coming back must restart the idle minutes")
    }

    /// Clicks and scrolls count, which also covers reading a long record by
    /// trackpad with the pointer still. `NSApp.sendEvent` runs the monitors
    /// before it returns. With window 0 and a point off every screen AppKit
    /// delivers these nowhere afterwards: no click lands, nothing beeps, the
    /// host stays inactive. No swallowing monitor: monitors run in no fixed
    /// order.
    @MainActor
    func testClicksAndScrollsPostponeTheIdleLock() async throws {
        let session = try await readySession(try makeRoot())
        observeInput(session)
        let inputs: [(String, [NSEvent])] = [
            ("scroll", [try Self.scroll()]),
            ("click", try Self.click(.leftMouseDown, .leftMouseUp)),
            ("right click", try Self.click(.rightMouseDown, .rightMouseUp)),
            ("middle click", try Self.click(.otherMouseDown, .otherMouseUp)),
        ]
        for (name, events) in inputs {
            let before = try await settledMoment()
            NSApp.sendEvent(events[0])
            // Counted on the press: a context menu's tracking loop takes the release.
            XCTAssertGreaterThanOrEqual(session.lastInteraction, before, "a \(name) must postpone the idle lock")
            events.dropFirst().forEach(NSApp.sendEvent)
        }
        // The gate stays open, so only a removed monitor explains this.
        session.stopObservingUserInput()
        let before = try await settledMoment()
        NSApp.sendEvent(try Self.scroll())
        XCTAssertLessThan(session.lastInteraction, before, "stopping must remove the event monitor")
    }

    // MARK: - Lock teardown

    private static func destinationFlow() -> AppSession.DestinationFlow {
        AppSession.DestinationFlow(bridge: .calendar, wizard: SyncDestinationWizard(
            bridge: .calendar, sources: [], existing: [], recordSummary: "", transmittedFields: [],
            createInSource: { _ in throw CancellationError() },
            confirm: { _ in throw CancellationError() },
            onCancel: {}))
    }

    /// Asks for a lock on the first key read after `arm()`: the read that
    /// the migration and recovery make once they have started, so the lock
    /// lands while they await.
    private final class LockOnReadKeyManager: KeyManager, @unchecked Sendable {
        private let inner: InMemoryKeyManager
        private let lock = NSLock()
        private var onRead: (() -> Void)?

        init(key: Data?) { inner = InMemoryKeyManager(key: key) }

        func arm(_ action: @escaping () -> Void) {
            lock.lock(); onRead = action; lock.unlock()
        }

        private func fire() {
            lock.lock()
            let action = onRead
            onRead = nil
            lock.unlock()
            action?()
        }

        func rootKey() throws -> Data? {
            fire()
            return try inner.rootKey()
        }

        func createRootKey() throws -> Data {
            fire()
            return try inner.createRootKey()
        }

        func storeRootKey(_ key: Data) throws { try inner.storeRootKey(key) }
        func deleteRootKey() throws { try inner.deleteRootKey() }
    }

    /// An off-screen window the note body can take first responder in, as it
    /// does in the app. Borderless: AppKit moves a titled window at x -20000
    /// onto a screen.
    @MainActor
    private func hostWindow<V: View>(_ view: V) -> NSWindow {
        let size = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = size
        let window = NSWindow(
            contentRect: size.offsetBy(dx: -20000, dy: -20000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                       "the test window must stay off every screen")
        return window
    }

    @MainActor
    private func textView(in window: NSWindow, showing content: String) async throws -> NSTextView {
        func textViews(in view: NSView?) -> [NSTextView] {
            guard let view else { return [] }
            if let textView = view as? NSTextView { return [textView] }
            return view.subviews.flatMap { textViews(in: $0) }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let found = textViews(in: window.contentView).first(where: { $0.string == content }) {
                return found
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(nil as NSTextView?, "the editor never showed \(content.debugDescription)")
    }

    /// An idle lock in the middle of typing used to unmount the editor with
    /// the store already gone, so its save on the way out found nothing to
    /// save into and the typing was lost. The lock now saves it first, and
    /// unlocking reopens the note.
    @MainActor
    func testLockingSavesTheNoteBeingTypedAndUnlockReopensIt() async throws {
        let root = try makeRoot()
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        await wait(until: { session.isReady }, seconds: 20)
        session.selectedModule = .notes
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Ward round"
        note.content = "Seen on the ward."
        let saved = await session.save(note)
        XCTAssertTrue(saved)

        let window = hostWindow(ContentView().environmentObject(session))
        let body = try await textView(in: window, showing: note.content)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        body.insertText(" Typed before the lock.", replacementRange: NSRange(location: NSNotFound, length: 0))

        await session.lockNow(reason: "idle")
        XCTAssertNil(session.selectedNoteId, "the editor must not stay mounted under the curtain")
        // Read while still locked: the editor's own save on the way out finds
        // no store now, so only the lock can have written this. (After an
        // unlock that save could land late and hide a lock that saved nothing.)
        let file = try Database.testDatabase(path: root.databaseURL.path, root: root)
        let onDisk = try await file.loadAllNotes().first { $0.id == note.id }
        await file.close()
        XCTAssertEqual(onDisk?.content, note.content + " Typed before the lock.")

        await session.unlock()
        XCTAssertEqual(session.selectedNoteId, note.id, "unlocking reopens the note")
    }

    /// A lock marks the editors it saved so they do not save again on the way
    /// out. The mark must not outlive that editor: the note reopened by the
    /// unlock is a new editor, and what is typed into it has to be saved when
    /// the user leaves it, here by switching module.
    @MainActor
    func testTypingAfterAnUnlockIsSavedWhenTheEditorIsLeft() async throws {
        let root = try makeRoot()
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        await wait(until: { session.isReady }, seconds: 20)
        session.selectedModule = .notes
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Ward round"
        note.content = "Seen on the ward."
        let saved = await session.save(note)
        XCTAssertTrue(saved)

        let window = hostWindow(ContentView().environmentObject(session))
        let first = try await textView(in: window, showing: note.content)
        XCTAssertTrue(window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: (first.string as NSString).length, length: 0))
        first.insertText(" Before the lock.", replacementRange: NSRange(location: NSNotFound, length: 0))
        await session.lockNow(reason: "idle")
        await session.unlock()
        XCTAssertEqual(session.selectedNoteId, note.id, "precondition: the note reopened")

        let afterLock = note.content + " Before the lock."
        let second = try await textView(in: window, showing: afterLock)
        XCTAssertTrue(window.makeFirstResponder(second))
        second.setSelectedRange(NSRange(location: (second.string as NSString).length, length: 0))
        second.insertText(" After the unlock.", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.selectedModule = .todos

        let expected = afterLock + " After the unlock."
        var stored: Note?
        for _ in 0..<200 where stored?.content != expected {
            try await Task.sleep(nanoseconds: 50_000_000)
            stored = try await session.store?.notes.load(id: note.id)
        }
        XCTAssertEqual(stored?.content, expected, "leaving the reopened editor must save what was typed in it")
    }

    /// The lock applies the editors' own rule to every kind of record: edits
    /// are saved, and a new record nobody touched is dropped, not left behind
    /// as a "New Event" row.
    @MainActor
    func testLockingSavesEditedDraftsAndDropsUntouchedNewRecords() async throws {
        let session = try await readySession(try makeRoot())
        await session.newPatient()
        let newPatient = await session.loadSelectedPatient()
        var patient = try XCTUnwrap(newPatient)
        patient.profile.firstName = "Draft"
        await session.newTodo()
        let newTodo = await session.loadSelectedTodo()
        var todo = try XCTUnwrap(newTodo)
        todo.title = "Call the lab"
        await session.newEvent()
        let newEvent = await session.loadSelectedEvent()
        let event = try XCTUnwrap(newEvent)
        await session.newNote()
        let newNote = await session.loadSelectedNote()
        let note = try XCTUnwrap(newNote)

        let editors = [UUID(), UUID(), UUID(), UUID()]
        session.registerOpenEditor(editors[0]) { .patient(patient, edited: true, knownFileIDs: Set(patient.files.map(\.id))) }
        session.registerOpenEditor(editors[1]) { .todo(todo, edited: true) }
        session.registerOpenEditor(editors[2]) { .event(event, edited: false) }
        session.registerOpenEditor(editors[3]) { .note(note, edited: false) }
        await session.lockNow(reason: "test")
        editors.forEach { session.unregisterOpenEditor($0) }
        await session.unlock()

        let store = try XCTUnwrap(session.store)
        let storedPatient = try await store.patients.load(id: patient.id)
        XCTAssertEqual(storedPatient?.profile.firstName, "Draft")
        let storedTodo = try await store.todos.load(id: todo.id)
        XCTAssertEqual(storedTodo?.title, "Call the lab")
        let storedEvent = try await store.events.load(id: event.id)
        XCTAssertNil(storedEvent, "an untouched new event is discarded")
        let storedNote = try await store.notes.load(id: note.id)
        XCTAssertNil(storedNote, "an untouched new note is discarded")
        XCTAssertEqual(session.selectedPatientId, patient.id)
        XCTAssertEqual(session.selectedTodoId, todo.id)
        XCTAssertNil(session.selectedEventId, "a discarded record is not reopened")
        XCTAssertNil(session.selectedNoteId)
    }

    @MainActor
    func testLockingStalePatientDraftPreservesNewAttachment() async throws {
        let session = try await readySession(try makeRoot())
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        var stale = try XCTUnwrap(loaded)
        let known = Set(stale.files.map(\.id))
        var current = stale
        let attachment = PatientFile(name: "new.txt", type: .other, data: Data("NEW".utf8))
        current.files.append(attachment)
        let store = try XCTUnwrap(session.store)
        try await store.patients.save(current, knownFileIDs: known)
        stale.profile.firstName = "Edited"
        let token = UUID()
        session.registerOpenEditor(token) { .patient(stale, edited: true, knownFileIDs: known) }
        await session.lockNow(reason: "test")
        session.unregisterOpenEditor(token)
        await session.unlock()
        let reopened = try XCTUnwrap(session.store)
        let saved = try await reopened.patients.load(id: stale.id)
        XCTAssertTrue(saved?.files.contains { $0.id == attachment.id } == true)
        let data = try await reopened.patients.loadFileData(patientId: stale.id, fileId: attachment.id)
        XCTAssertEqual(data, Data("NEW".utf8))
    }

    @MainActor
    func testClosingForQuitSavesTheOpenDraftAndClosesTheStore() async throws {
        let session = try await readySession(try makeRoot())
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Ward round"
        note.content = "Typed before the quit."
        let token = UUID()
        session.registerOpenEditor(token) { .note(note, edited: true) }

        await session.closeForQuit()

        XCTAssertNil(session.store, "quitting closes the store like a lock")
        XCTAssertTrue(session.isLocked)
        session.unregisterOpenEditor(token)
        await session.unlock()
        let reopened = try XCTUnwrap(session.store)
        let stored = try await reopened.notes.load(id: note.id)
        XCTAssertEqual(stored?.content, "Typed before the quit.")
        let lock = try await reopened.audit.latest(action: "app_lock")
        XCTAssertTrue(lock?.details.contains("reason=quit") == true)
    }

    @MainActor
    func testClosingForQuitWithNothingOpenIsHarmless() async throws {
        let session = try await readySession(try makeRoot())
        await session.lockNow(reason: "test")
        await session.closeForQuit()
        XCTAssertNil(session.store)
        XCTAssertTrue(session.isLocked)
    }

    @MainActor
    func testRestoreSavesTheOpenDraftFirstAndSettlesItsEditor() async throws {
        let session = try await readySession(try makeRoot())
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Plan"
        note.content = "Backed up text."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        let store = try XCTUnwrap(session.store)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).mednotesbackup")
        defer { try? FileManager.default.removeItem(at: archive) }
        let passphrase = "a long enough passphrase"
        _ = try await store.backups.createEncryptedBackup(name: "before", to: archive, passphrase: passphrase)

        // Typed after the backup, not saved: the editor still holds it.
        var draft = note
        draft.content = "Typed after the backup."
        let token = UUID()
        session.registerOpenEditor(token) { .note(draft, edited: true) }

        try await session.performRestore(from: archive, passphrase: passphrase)

        let restored = try await XCTUnwrap(session.store).notes.load(id: note.id)
        XCTAssertEqual(restored?.content, "Backed up text.", "the backup's version is what the restore leaves")
        XCTAssertFalse(session.unregisterOpenEditor(token),
                       "the session saved this draft itself, so the editor must not save it again")
    }

    @MainActor
    func testRestoreChangesNothingWhenAnOpenDraftCannotBeSaved() async throws {
        let session = try await readySession(try makeRoot())
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Plan"
        note.content = "Current text."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        let store = try XCTUnwrap(session.store)
        var existing = Patient.newRecord()
        existing.profile.amka = "12345678901"
        try await store.patients.save(existing)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).mednotesbackup")
        defer { try? FileManager.default.removeItem(at: archive) }
        let passphrase = "a long enough passphrase"
        _ = try await store.backups.createEncryptedBackup(name: "before", to: archive, passphrase: passphrase)
        var edited = note
        edited.content = "Edited since the backup."
        try await store.notes.save(edited)

        // A second patient with the same AMKA cannot be saved.
        var clash = Patient.newRecord()
        clash.profile.amka = "12345678901"
        let token = UUID()
        session.registerOpenEditor(token) { .patient(clash, edited: true, knownFileIDs: []) }

        do {
            try await session.performRestore(from: archive, passphrase: passphrase)
            XCTFail("a draft that cannot be saved must stop the restore")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be saved"))
        }

        let current = try await XCTUnwrap(session.store).notes.load(id: note.id)
        XCTAssertEqual(current?.content, "Edited since the backup.", "nothing was restored")
        XCTAssertTrue(session.unregisterOpenEditor(token), "the editor keeps its draft to fix")
    }

    /// Holds the lock a test lands in the middle of a restore, so the test can
    /// wait for the lock to finish (save, audit, close) before it looks at disk.
    private final class LockTaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    /// A crash after the restored database is in place and before the
    /// attachments are swapped used to leave a database that opens and
    /// references none of the old attachments. The sweep that runs as the store
    /// opens then deleted every one of them. The launch now undoes the install
    /// first.
    @MainActor
    func testALaunchAfterACutOffInstallKeepsTheOriginalAttachments() async throws {
        let root = try makeRoot()
        let seeded = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "scan.txt", type: .other, data: Data("KEEP ME".utf8))]
        try await seeded.patients.save(patient)
        await seeded.close()
        // Old enough for the sweep to take, as a real store's files are.
        let longAgo = Date().addingTimeInterval(-7200)
        let objects = try FileManager.default.contentsOfDirectory(atPath: root.attachmentsURL.path)
        XCTAssertFalse(objects.isEmpty, "precondition: the store holds an attachment")
        for name in objects {
            try FileManager.default.setAttributes(
                [.modificationDate: longAgo],
                ofItemAtPath: root.attachmentsURL.appendingPathComponent(name).path)
        }
        // The install's state at the cut: the original database is in the
        // rollback folder, and an empty database that opens fine is live.
        let folder = root.rootURL.appendingPathComponent(
            "\(RestoreRecovery.rollbackPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RestoreRecovery.writeJournal(.databaseReplaced, in: folder)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: root.databaseURL.path + suffix) {
            try FileManager.default.moveItem(
                atPath: root.databaseURL.path + suffix,
                toPath: folder.appendingPathComponent("mednotes.db" + suffix).path)
        }
        let incoming = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        await incoming.close()

        let session = try await readySession(root)

        let store = try XCTUnwrap(session.store)
        let loaded = try await store.patients.load(id: patient.id)
        XCTAssertNotNil(loaded, "the original database is back")
        let file = try XCTUnwrap(loaded?.files.first)
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: file.id)
        XCTAssertEqual(bytes, Data("KEEP ME".utf8), "the sweep must not have taken the attachment")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.rootURL.path)
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix(RestoreRecovery.rollbackPrefix) })
    }

    /// An idle lock can land during a long restore. The restore stops at the
    /// last point it can, before any live file moves; the lock waits for it,
    /// then saves and closes. Nothing is left half installed and no connection
    /// is reopened after the lock.
    @MainActor
    func testALockDuringARestoreStopsItBeforeAnyLiveFileMoves() async throws {
        let session = try await readySession(try makeRoot())
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Plan"
        note.content = "In the backup."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        let store = try XCTUnwrap(session.store)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).mednotesbackup")
        defer { try? FileManager.default.removeItem(at: archive) }
        let passphrase = "a long enough passphrase"
        _ = try await store.backups.createEncryptedBackup(name: "before", to: archive, passphrase: passphrase)
        note.content = "Edited since the backup."
        let edited = await session.save(note)
        XCTAssertTrue(edited)
        let root = try XCTUnwrap(session.dataRoot)

        // The lock lands once everything is staged, as late as it can.
        let lock = LockTaskBox()
        await store.backups.setBeforeInstallForTesting { [session, lock] in
            await MainActor.run { lock.task = Task { await session.lockNow(reason: "idle") } }
            while await !MainActor.run(body: { session.isLocked }) { await Task.yield() }
        }
        try await session.performRestore(from: archive, passphrase: passphrase)
        await lock.task?.value

        XCTAssertNil(session.store, "the lock closed the store")
        XCTAssertTrue(session.isLocked)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.rootURL.path)
        XCTAssertTrue(names.allSatisfy {
            !$0.hasPrefix(RestoreRecovery.rollbackPrefix) && !$0.hasPrefix(RestoreRecovery.discardPrefix)
        }, "no install was started: \(names)")
        // Wholly the old state: the restore did not run.
        let file = try Database.testDatabase(path: root.databaseURL.path, root: root)
        let onDisk = try await file.loadAllNotes().first { $0.id == note.id }
        await file.close()
        XCTAssertEqual(onDisk?.content, "Edited since the backup.")
        XCTAssertNotNil(session.errorMessage, "the user is told the restore did not finish")
    }

    /// The other end of the same window: the lock lands after the point where a
    /// restore can be cancelled, so the swap runs to its end. The edits that were
    /// open were saved before the restore began (they are in its safety copy),
    /// and the lock must not write them again into the data that just replaced
    /// them.
    @MainActor
    func testALockAfterTheSwapDoesNotWriteTheOpenDraftsIntoTheRestoredData() async throws {
        let session = try await readySession(try makeRoot())
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Plan"
        note.content = "In the backup."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        let store = try XCTUnwrap(session.store)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).mednotesbackup")
        defer { try? FileManager.default.removeItem(at: archive) }
        let passphrase = "a long enough passphrase"
        _ = try await store.backups.createEncryptedBackup(name: "before", to: archive, passphrase: passphrase)
        let root = try XCTUnwrap(session.dataRoot)

        // Typed after the backup and still open in its editor.
        var draft = note
        draft.content = "Unsaved draft."
        let token = UUID()
        session.registerOpenEditor(token) { .note(draft, edited: true) }

        let lock = LockTaskBox()
        await store.backups.setAfterSwapForTesting { [session, lock] in
            await MainActor.run { lock.task = Task { await session.lockNow(reason: "idle") } }
            while await !MainActor.run(body: { session.isLocked }) { await Task.yield() }
        }
        try await session.performRestore(from: archive, passphrase: passphrase)
        // The lock saves, audits and closes after the restore returns.
        await lock.task?.value

        XCTAssertNil(session.store, "the lock closed the store")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.rootURL.path)
        XCTAssertTrue(names.allSatisfy {
            !$0.hasPrefix(RestoreRecovery.rollbackPrefix) && !$0.hasPrefix(RestoreRecovery.discardPrefix)
        }, "the install finished and cleaned up: \(names)")
        let file = try Database.testDatabase(path: root.databaseURL.path, root: root)
        let onDisk = try await file.loadAllNotes().first { $0.id == note.id }
        let trail = try await file.recentAuditLogs(limit: 50)
        await file.close()
        XCTAssertEqual(onDisk?.content, "In the backup.",
                       "the restored data must not be overwritten by the draft that was open")
        XCTAssertTrue(trail.contains { $0.action == "backup_restore" },
                      "a restore that finished is on the audit trail even when a lock landed during it")
        XCTAssertFalse(session.unregisterOpenEditor(token),
                       "the editor was settled, so it must not save its draft again either")
    }

    /// `open -g`, a hidden login item or a click elsewhere during startup
    /// never resigns active, so the curtain has to start from the window.
    @MainActor
    func testABackgroundLaunchOpensBehindTheCurtain() async throws {
        let root = try makeRoot()
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        session.windowDidAppear(appIsActive: false)
        XCTAssertFalse(session.isObscured, "nothing shows yet; the curtain waits for the records")
        await wait(until: { session.isReady }, seconds: 20)
        XCTAssertTrue(session.isObscured, "records must not show in an app that has never been active")

        session.appDidBecomeActive()
        XCTAssertFalse(session.isObscured)
    }

    /// The window appears a moment before an ordinary launch activates the
    /// app. Becoming active before the records load must leave no curtain to
    /// flash; a window that appears while inactive later is covered at once.
    @MainActor
    func testAForegroundLaunchNeverRaisesTheCurtain() async throws {
        let root = try makeRoot()
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        session.windowDidAppear(appIsActive: false)
        session.appDidBecomeActive()
        await wait(until: { session.isReady }, seconds: 20)
        XCTAssertFalse(session.isObscured)

        session.windowDidAppear(appIsActive: true)
        XCTAssertFalse(session.isObscured)
        session.windowDidAppear(appIsActive: false)
        XCTAssertTrue(session.isObscured)
    }

    /// A lock (the screen locking while Touch ID was up) that comes before
    /// launch has opened the store wins: the store it opened is closed again.
    @MainActor
    func testALockBeforeLaunchOpensTheStoreKeepsItClosed() async throws {
        let root = try makeRoot()
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        await session.lockNow(reason: "screen-lock")
        await wait(until: { session.coordinator != nil }, seconds: 20)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(session.isLocked)
        XCTAssertFalse(session.isReady)
        XCTAssertNil(session.store, "a locked session must not hold a live store")
        XCTAssertThrowsError(try session.coordinator?.requireDatabaseKey(), "nor its keys")

        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertTrue(session.isReady)
        XCTAssertNotNil(session.store)
    }

    /// A lock that lands while the migration converts the store must not
    /// leave a locked session holding the converted store, its keys and its
    /// records. The conversion itself completes; Unlock opens the result.
    @MainActor
    func testALockDuringTheMigrationLeavesTheConvertedStoreLocked() async throws {
        let root = try makeRoot()
        let plaintext = try Database(path: root.databaseURL.path)
        var patient = Patient.newRecord()
        patient.profile.lastName = "Migrated"
        try await plaintext.savePatient(patient)
        await plaintext.close()

        let keys = LockOnReadKeyManager(key: nil)
        let session = AppSession(dataRoot: root, defaults: defaults, keyManager: keys)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        await wait(until: { session.isMigrating }, seconds: 20)
        XCTAssertTrue(session.isMigrating, "precondition: a plaintext store starts the migration")
        let backup = tempDir.appendingPathComponent("pre-migration.mednotesbackup")
        try await session.migrationBackup(to: backup, passphrase: recoveryPassphrase)

        keys.arm { Task { @MainActor in await session.lockNow(reason: "display-sleep") } }
        try await session.runMigration(backupURL: backup, passphrase: recoveryPassphrase)

        XCTAssertFalse(session.isMigrating)
        XCTAssertTrue(session.isLocked)
        XCTAssertFalse(session.isReady)
        XCTAssertNil(session.store, "the converted store must be closed again")
        XCTAssertThrowsError(try session.coordinator?.requireDatabaseKey(), "and its keys wiped")
        XCTAssertTrue(session.patients.isEmpty)
        XCTAssertFalse(SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL),
                       "the conversion itself completes")

        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertEqual(session.patients.map(\.profile.lastName), ["Migrated"])
    }

    /// The same for key recovery: a lock during it leaves the recovered
    /// store closed, and plain Unlock (not recovery) opens it.
    @MainActor
    func testALockDuringRecoveryLeavesTheRecoveredStoreLocked() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let keys = LockOnReadKeyManager(key: nil)
        let session = AppSession(dataRoot: root, defaults: defaults, keyManager: keys)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        await wait(until: { session.needsRecovery || session.isReady }, seconds: 20)
        XCTAssertTrue(session.needsRecovery, "precondition: the key is missing")

        keys.arm { Task { @MainActor in await session.lockNow(reason: "screen-lock") } }
        try await session.recoverFromBackup(at: archive, passphrase: recoveryPassphrase)

        XCTAssertTrue(session.isLocked)
        XCTAssertFalse(session.needsRecovery, "the key exists now; the curtain offers Unlock")
        XCTAssertNil(session.store, "the recovered store must be closed again")
        XCTAssertThrowsError(try session.coordinator?.requireDatabaseKey(), "and its keys wiped")

        await session.unlock()
        XCTAssertFalse(session.isLocked)
        XCTAssertEqual(session.patients.count, 1)
    }

    /// Only a lock that arrives while recovery runs counts. One from before
    /// (the curtain was up when the screen locked) was answered by the user
    /// who then chose the backup and typed its passphrase.
    @MainActor
    func testARecoveryStartedAfterALockOpensTheStore() async throws {
        let root = try makeRoot()
        let archive = try await storeWithBackup(root)
        let session = AppSession(dataRoot: root, defaults: defaults,
                                 keyManager: InMemoryKeyManager(key: nil))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        await wait(until: { session.needsRecovery || session.isReady }, seconds: 20)
        XCTAssertTrue(session.needsRecovery, "precondition: the key is missing")
        await session.lockNow(reason: "screen-lock")
        XCTAssertTrue(session.isLocked)

        try await session.recoverFromBackup(at: archive, passphrase: recoveryPassphrase)
        XCTAssertFalse(session.isLocked)
        XCTAssertFalse(session.needsRecovery)
        XCTAssertNotNil(session.store)
        XCTAssertTrue(session.isReady)
    }

    /// The XCTest host is the app itself. Its own session must not open the
    /// user's store in Application Support or read their Keychain item.
    @MainActor
    func testTheTestHostsOwnSessionOpensNothing() async throws {
        XCTAssertTrue(AppSession.isTestHost)
        let session = AppSession(defaults: .standard)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(session.dataRoot, "Application Support must not be resolved")
        XCTAssertNil(session.coordinator, "the Keychain must not be read")
        XCTAssertFalse(session.isReady)
    }
}
