import XCTest
@testable import MedNotes

/// What the encryption migration and the legacy restore carry over, what they
/// check, and how they fail.
final class MigrationFixTests: XCTestCase {
    private var roots: [DataRoot] = []
    private let passphrase = "a long enough passphrase"

    override func tearDownWithError() throws {
        #if DEBUG
        StoreMigrator.failJournalWriteForTesting = nil
        #endif
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    // MARK: - Helpers

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    /// The pre-migration backup the wizard insists on.
    private func backup(of root: DataRoot) async throws -> URL {
        let url = root.rootURL.appendingPathComponent("pre-migration.mednotesbackup")
        let db = try Database(path: root.databaseURL.path)
        let service = BackupService(
            db: db, fileStore: nil, restorePointsRoot: root.restorePointsURL,
            legacyFilesRoot: root.filesURL)
        _ = try await service.createEncryptedBackup(name: "Pre-encryption", to: url, passphrase: passphrase)
        await db.close()
        return url
    }

    private func openMigrated(_ root: DataRoot, key: Data) throws -> Database {
        try Database(
            path: root.databaseURL.path,
            key: try StoreKeyContext.subkey(rootKey: key, context: StoreKeyContext.database))
    }

    private func isPlaintext(_ root: DataRoot) -> Bool {
        SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL)
    }

    // MARK: - Templates

    func testMigrationCarriesCustomTemplatesAndEditedShippedOnes() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        try await plain.saveNote(Note(title: "n", content: "body"))
        let custom = NoteTemplate(id: NoteTemplate.customIDPrefix + "kept", name: "Ward round",
                                  kind: .custom, content: "CUSTOM-TEMPLATE-BODY")
        try await plain.saveTemplate(custom)
        var edited = try XCTUnwrap(TemplateService.builtIns.first { $0.id == "tpl-soap" })
        edited.content = "EDITED-SOAP-BODY"
        try await plain.saveTemplate(edited)
        await plain.close()

        let archive = try await backup(of: root)
        let keys = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keys)
        _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
        await migrator.finishCleanup()

        let migrated = try openMigrated(root, key: try XCTUnwrap(keys.rootKey()))
        let templates = try await migrated.customTemplates()
        XCTAssertEqual(templates.first { $0.id == custom.id }?.content, "CUSTOM-TEMPLATE-BODY")
        XCTAssertEqual(templates.first { $0.id == "tpl-soap" }?.content, "EDITED-SOAP-BODY")
        await migrated.close()
    }

    func testLegacyRestoreCarriesCustomTemplates() async throws {
        let sourceRoot = try makeRoot()
        let plain = try Database(path: sourceRoot.databaseURL.path)
        try await plain.saveNote(Note(title: "n", content: "body"))
        let custom = NoteTemplate(id: NoteTemplate.customIDPrefix + "restored", name: "Handover",
                                  kind: .custom, content: "RESTORED-TEMPLATE-BODY")
        try await plain.saveTemplate(custom)
        let service = BackupService(
            db: plain, fileStore: nil, restorePointsRoot: sourceRoot.restorePointsURL,
            legacyFilesRoot: sourceRoot.filesURL)
        let archive = sourceRoot.rootURL.appendingPathComponent("legacy.mednotesbackup")
        _ = try await service.createEncryptedBackup(to: archive, passphrase: passphrase)
        await plain.close()

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
        let templates = try await target.db.customTemplates()
        XCTAssertEqual(templates.first { $0.id == custom.id }?.content, "RESTORED-TEMPLATE-BODY")
        await target.close()
    }

    // MARK: - Verification

    /// A row the source cannot decode is not copied. The old check compared
    /// the copy with itself and passed; it now holds the copy to the source.
    func testMigrationFailsWhenARecordIsLostInTheCopy() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        try await plain.saveNote(Note(title: "good", content: "body"))
        await plain.close()
        let conn = try SQLConnection(path: root.databaseURL.path)
        try conn.exec("INSERT INTO notes (id, title) VALUES ('not-a-uuid', 'undecodable')")
        conn.close()

        let archive = try await backup(of: root)
        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())
        do {
            _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
            XCTFail("a lost record must fail validation")
        } catch let error as StoreMigrator.MigrationError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("expected a validation failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("notes"), "the shortfall names the table: \(detail)")
        }
        XCTAssertTrue(isPlaintext(root), "the original store is untouched")
    }

    func testUnlimitedAuditReadReturnsEveryRow() async throws {
        let db = try Database(path: try makeRoot().databaseURL.path)
        for index in 0..<150 {
            try await db.logAudit(AuditLogEntry(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                action: "a\(index)", entityType: "t", entityId: "e"))
        }
        let all = try await db.recentAuditLogs(limit: -1)
        let capped = try await db.recentAuditLogs(limit: 100)
        XCTAssertEqual(all.count, 150)
        XCTAssertEqual(capped.count, 100)
        await db.close()
    }

    // MARK: - A file the plaintext store lost

    func testMigrationDropsADanglingAttachmentRecordAndReportsIt() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        var patient = Patient.newRecord()
        let present = PatientFile(name: "present.txt", type: .other, data: nil)
        let missing = PatientFile(name: "missing.txt", type: .other, data: nil)
        patient.files = [present, missing]
        try await plain.savePatient(patient)
        await plain.close()
        let dir = root.filesURL.appendingPathComponent(patient.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("PRESENT-BYTES".utf8).write(to: dir.appendingPathComponent(present.id.uuidString))

        let archive = try await backup(of: root)
        let keys = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keys)
        let report = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
        await migrator.finishCleanup()

        XCTAssertEqual(report.attachments, 1)
        XCTAssertEqual(report.missingAttachments, ["missing.txt"], "the user is told the file's name")
        let migrated = try openMigrated(root, key: try XCTUnwrap(keys.rootKey()))
        let rows = try await migrated.loadPatientFiles(patientId: patient.id)
        XCTAssertEqual(rows.map(\.id), [present.id], "only the file that exists is carried over")
        await migrated.close()
    }

    func testADroppedOnlyAttachmentDoesNotComeBackFromTheLegacyCopy() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "missing.txt", type: .other, data: nil)]
        try await plain.savePatient(patient)
        await plain.close()

        let archive = try await backup(of: root)
        let keys = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keys)
        let report = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
        await migrator.finishCleanup()

        XCTAssertEqual(report.missingAttachments, ["missing.txt"])
        let migrated = try openMigrated(root, key: try XCTUnwrap(keys.rootKey()))
        let loaded = try await migrated.loadPatient(id: patient.id)
        XCTAssertEqual(try XCTUnwrap(loaded).files, [],
                       "the file that was dropped must not reappear from the patient's own copy of its list")
        await migrated.close()
    }

    func testMigrationRefusesAStoreThatIsNotPlaintext() async throws {
        // A missing store used to be created empty by the reader and "migrated",
        // after which the swap discarded `Plaintext.old.db`, the only original.
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        await plain.close()
        let archive = try await backup(of: root)
        try FileManager.default.removeItem(at: root.databaseURL)
        let leftover = root.rootURL.appendingPathComponent("Plaintext.old.db")
        try Data("ORIGINAL".utf8).write(to: leftover)

        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())
        do {
            _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
            XCTFail("there is nothing to migrate")
        } catch StoreMigrator.MigrationError.stagingFailed {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: leftover), Data("ORIGINAL".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.databaseURL.path),
                       "no empty store may be created in its place")
    }

    // MARK: - Cleanup that cannot finish

    /// A folder with something in it that cannot be deleted: the folder's own
    /// permissions stop its contents being removed.
    private func makeUndeletableLegacyFiles(in root: DataRoot) throws -> URL {
        let stuck = root.filesURL.appendingPathComponent("patient", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data("LEGACY".utf8).write(to: stuck.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuck.path)
        return stuck
    }

    private func release(_ stuck: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuck.path)
    }

    private func writeJournal(_ phase: StoreMigrator.Phase, in root: DataRoot) throws {
        let journal = StoreMigrator.Journal(
            phase: phase, schemaVersion: Schema.currentVersion, recordCounts: [:],
            attachmentCount: 0, startedAt: Date(), updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: StoreMigrator.journalURL(in: root))
    }

    func testCleanupReportsWhatItCannotDeleteAndTriesAgainLater() async throws {
        let root = try makeRoot()
        let oldDatabase = root.rootURL.appendingPathComponent("Plaintext.old.db")
        try Data("OLD".utf8).write(to: oldDatabase)
        let stuck = try makeUndeletableLegacyFiles(in: root)
        defer { release(stuck) }
        try writeJournal(.complete, in: root)
        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())

        let leftovers = await migrator.finishCleanup()

        XCTAssertEqual(leftovers, [root.filesURL.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDatabase.path),
                       "one stuck item does not keep the others")
        XCTAssertTrue(FileManager.default.fileExists(atPath: StoreMigrator.journalURL(in: root).path),
                      "the journal stays, so the next launch tries again")

        release(stuck)
        let again = await migrator.finishCleanup()
        XCTAssertEqual(again, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.filesURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreMigrator.journalURL(in: root).path))
    }

    func testLaunchRecoveryDoesNotThrowOverAnItemItCannotDelete() async throws {
        let root = try makeRoot()
        let stuck = try makeUndeletableLegacyFiles(in: root)
        defer { release(stuck) }
        try writeJournal(.complete, in: root)
        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())

        let leftovers = try await migrator.recoverInterruptedMigration()

        XCTAssertEqual(leftovers, [root.filesURL.lastPathComponent])
    }

    func testAJournalLessLeftoverThatCannotBeDeletedIsRetriedAtTheNextLaunch() async throws {
        let root = try makeRoot()
        // What a finished migration whose journal was dropped leaves: an
        // encrypted database (not a plaintext header) beside the plaintext copy.
        try Data(repeating: 0xA5, count: 4096).write(to: root.databaseURL)
        try Data("OLD".utf8).write(to: root.rootURL.appendingPathComponent("Plaintext.old.db"))
        let stuck = try makeUndeletableLegacyFiles(in: root)
        defer { release(stuck) }
        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())

        let first = try await migrator.recoverInterruptedMigration()
        XCTAssertEqual(first, [root.filesURL.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: StoreMigrator.journalURL(in: root).path),
                      "with the old copy gone nothing else would bring the next launch back")

        release(stuck)
        let second = try await migrator.recoverInterruptedMigration()
        XCTAssertEqual(second, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.filesURL.path))
    }

    @MainActor
    func testTheStoreOpensAndSaysSoWhenAFinishedMigrationLeftSomethingUndeletable() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        try await plain.saveNote(Note(title: "n", content: "kept"))
        await plain.close()
        let archive = try await backup(of: root)
        let keys = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keys)
        _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
        // Nothing has cleaned up yet (the journal says `.complete`), and one
        // item will not go.
        let stuck = try makeUndeletableLegacyFiles(in: root)
        defer { release(stuck) }

        let defaultsName = "MedNotesTests.MigrationFix"
        defer { TestDefaults.clear(defaultsName) }
        let session = AppSession(
            dataRoot: root, defaults: TestDefaults.suite(defaultsName), keyManager: keys)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(session.initError, "an item that cannot be deleted must not keep the store from opening")
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.notice?.contains(root.filesURL.lastPathComponent) == true,
                      "the user is told what is left: \(session.notice ?? "nil")")
    }

    // MARK: - The last journal write

    #if DEBUG
    func testAFailedFinalJournalWriteDoesNotRollTheMigrationBack() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        try await plain.saveNote(Note(title: "n", content: "MIGRATED-NOTE"))
        await plain.close()
        let archive = try await backup(of: root)
        let legacyFile = root.filesURL.appendingPathComponent("patient/file")
        try FileManager.default.createDirectory(
            at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("LEGACY-PLAINTEXT".utf8).write(to: legacyFile)
        let oldDatabase = root.rootURL.appendingPathComponent("Plaintext.old.db")

        let keys = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keys)
        StoreMigrator.failJournalWriteForTesting = { $0 == .complete }
        _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
        StoreMigrator.failJournalWriteForTesting = nil

        XCTAssertFalse(isPlaintext(root), "both swaps are done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: StoreMigrator.journalURL(in: root).path),
                       "a stale `.swapping` journal would let recovery undo the migration")
        // The caller's cleanup has not run (say the app ended first). The
        // plaintext copy is still there, and launch-time recovery, which finds
        // no journal, must remove it rather than leave it for ever.
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDatabase.path))
        try await migrator.recoverInterruptedMigration()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDatabase.path), "plaintext copy removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.filesURL.path), "legacy files removed")
        XCTAssertFalse(isPlaintext(root), "launch-time recovery leaves the migrated store alone")
        let migrated = try openMigrated(root, key: try XCTUnwrap(keys.rootKey()))
        let notes = try await migrated.loadAllNotes()
        XCTAssertEqual(notes.map(\.content), ["MIGRATED-NOTE"])
        await migrated.close()
    }
    #endif

    #if DEBUG
    func testTheJournalHoldsPhasesAndCountsAndNoPatientText() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Zqmarker"
        patient.profile.lastName = "Wxmarker"
        try await plain.savePatient(patient)
        try await plain.saveNote(Note(title: "Vqmarker", content: "Uqmarker body"))
        await plain.close()
        let archive = try await backup(of: root)

        let migrator = StoreMigrator(dataRoot: root, keyManager: InMemoryKeyManager())
        let none = try await migrator.readJournal()
        XCTAssertNil(none, "no journal before a migration starts")
        // Stop the migration at validation, so the journal is what an
        // interruption would leave.
        StoreMigrator.failJournalWriteForTesting = { $0 == .validating }
        do {
            _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase)
            XCTFail("the injected journal fault must stop the migration")
        } catch {}
        StoreMigrator.failJournalWriteForTesting = nil

        // Recovery needs a journal that reads back, not just a file.
        let journal = try await migrator.readJournal()
        XCTAssertNotNil(journal, "an interrupted migration leaves a readable journal")
        let text = try String(contentsOf: StoreMigrator.journalURL(in: root), encoding: .utf8)
        for marker in ["Zqmarker", "Wxmarker", "Vqmarker", "Uqmarker"] {
            XCTAssertFalse(text.contains(marker), "the journal must not carry patient or note text")
        }
    }
    #endif

    // MARK: - One Keychain read

    private final class CountingKeyManager: KeyManager, @unchecked Sendable {
        private let inner = InMemoryKeyManager()
        private let lock = NSLock()
        private var creates = 0
        private var reads = 0
        var createCalls: Int { lock.lock(); defer { lock.unlock() }; return creates }
        var readCalls: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func rootKey() throws -> Data? {
            lock.lock(); reads += 1; lock.unlock()
            return try inner.rootKey()
        }
        func createRootKey() throws -> Data {
            lock.lock(); creates += 1; lock.unlock()
            return try inner.createRootKey()
        }
        func storeRootKey(_ key: Data) throws { try inner.storeRootKey(key) }
        func deleteRootKey() throws { try inner.deleteRootKey() }
    }

    func testMigrationUsesTheKeyItIsGivenInsteadOfAskingAgain() async throws {
        let root = try makeRoot()
        let plain = try Database(path: root.databaseURL.path)
        try await plain.saveNote(Note(title: "n", content: "body"))
        await plain.close()
        let archive = try await backup(of: root)

        let manager = CountingKeyManager()
        let key = try manager.createRootKey()
        XCTAssertEqual(manager.createCalls, 1)
        let migrator = StoreMigrator(dataRoot: root, keyManager: manager)
        _ = try await migrator.migrate(backupDestination: archive, passphrase: passphrase, rootKey: key)
        XCTAssertEqual(manager.createCalls, 1, "no second key is made")
        XCTAssertEqual(manager.readCalls, 0, "a read of the Keychain is a second user-presence prompt")
        await migrator.finishCleanup()

        let migrated = try openMigrated(root, key: key)
        let count = try await migrated.counts()["notes"]
        XCTAssertEqual(count, 1)
        await migrated.close()
    }

    // MARK: - The coordinator

    private struct ShortKeyManager: KeyManager {
        func rootKey() throws -> Data? { nil }
        func createRootKey() throws -> Data { Data(repeating: 1, count: 16) }
        func storeRootKey(_ key: Data) throws {}
        func deleteRootKey() throws {}
    }

    @MainActor
    func testAKeyErrorOutsideTheStoreErrorsLeavesTheCoordinatorLockedWithAMessage() throws {
        let root = try makeRoot()
        let coordinator = SecureStoreCoordinator(keyManager: ShortKeyManager(), dataRoot: root)
        XCTAssertThrowsError(try coordinator.authenticate())
        XCTAssertEqual(coordinator.state, .locked, "not stuck in .unlocking")
        XCTAssertNotNil(coordinator.lastError)
    }
}
