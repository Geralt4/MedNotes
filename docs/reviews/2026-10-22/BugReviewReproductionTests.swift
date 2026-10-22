import XCTest
@testable import MedNotes

/// Review-only regression tests. These assert the intended behavior and are
/// expected to fail against the unmodified source reviewed on 2026-10-22.
final class BugReviewReproductionTests: XCTestCase {
    private var roots: [DataRoot] = []
    private let passphrase = "review backup passphrase 2026"

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    private func patientWithTwoFiles() -> Patient {
        var patient = Patient.newRecord()
        patient.profile.firstName = "Synthetic review patient"
        patient.files = [
            PatientFile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        name: "first.txt", type: .other, data: Data("AAAA".utf8)),
            PatientFile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        name: "second.txt", type: .other, data: Data("BBBB".utf8))
        ]
        return patient
    }

    func testRestorePointMustRequireDeviceSecret() async throws {
        let root = try makeRoot()
        let source = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Synthetic review marker", content: "REVIEW_SECRET_92741")
        try await source.notes.save(note)
        let name = try await source.backups.createEncryptedRestorePoint(
            name: "Review point", attachmentKey: TestKeys.attachment(for: root))
        await source.close()

        // Only the .mnrp file and a string literal are used below. No root,
        // database, attachment, or restore-point key is supplied to the reader.
        let file = root.restorePointsURL.appendingPathComponent(name)
        let publicLiteral = "MedNotesRestorePointMedNotesRestorePoint"
        let opened = try BackupArchiveV2.openReader(at: file, passphrase: publicLiteral)
        defer { try? opened.reader.handle.close() }
        let snapshot = root.rootURL.appendingPathComponent("extracted.db")
        _ = FileManager.default.createFile(atPath: snapshot.path, contents: nil)
        let handle = try FileHandle(forWritingTo: snapshot)
        _ = try await BackupArchiveV2.read(opened: opened) { item in
            if case .databaseChunk(let bytes) = item { try handle.write(contentsOf: bytes) }
        }
        try handle.close()
        let extracted = try Database(path: snapshot.path, key: opened.archiveKey)
        let leaked = try await extracted.loadNote(id: note.id)
        await extracted.close()
        XCTAssertNil(leaked, "Restore point disclosed note without any device secret: \(leaked?.content ?? "nil")")
    }

    func testPortableBackupRestoresTwoDistinctAttachments() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        let patient = patientWithTwoFiles()
        try await source.patients.save(patient)
        let archive = sourceRoot.rootURL.appendingPathComponent("two.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(to: archive, passphrase: passphrase)

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
            for file in patient.files {
                let restored = try await target.patients.loadFileData(patientId: patient.id, fileId: file.id)
                XCTAssertEqual(restored, file.data)
            }
        } catch {
            XCTFail("App-created backup with two attachments cannot restore: \(error.localizedDescription)")
        }
        await source.close()
        await target.close()
    }

    func testMissingKeyRecoveryPreservesBothAttachments() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        let patient = patientWithTwoFiles()
        try await source.patients.save(patient)
        let archive = sourceRoot.rootURL.appendingPathComponent("recover.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(to: archive, passphrase: passphrase)

        let targetRoot = try makeRoot()
        let manager = InMemoryKeyManager()
        let report = try await StoreRecovery(dataRoot: targetRoot, keyManager: manager)
            .recover(from: archive, passphrase: passphrase)
        XCTAssertEqual(report.attachmentCount, 2)
        let recovered = try AppStore(
            dataRoot: targetRoot,
            databaseKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.database),
            attachmentKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.attachments))
        let saved = try await recovered.patients.load(id: patient.id)
        for original in patient.files {
            let metadata = try XCTUnwrap(saved?.files.first { $0.id == original.id })
            let storageID = try XCTUnwrap(metadata.storageID)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: targetRoot.attachmentsURL.appendingPathComponent(storageID).path),
                "Recovery returned success, but \(original.name) is missing")
            if let bytes = try? await recovered.patients.loadFileData(patientId: patient.id, fileId: original.id) {
                XCTAssertEqual(bytes, original.data)
            }
        }
        await source.close()
        await recovered.close()
    }

    func testPortableBackupRestoresEmptyAttachment() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "empty.txt", type: .other, data: Data())]
        try await source.patients.save(patient)
        let archive = sourceRoot.rootURL.appendingPathComponent("empty.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(to: archive, passphrase: passphrase)
        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
        } catch {
            XCTFail("App-created backup containing an empty attachment cannot restore: \(error.localizedDescription)")
        }
        await source.close()
        await target.close()
    }

    func testFailedRestoreKeepsOriginalDataWhenRollbackHasTwoAttachments() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        var incoming = Patient.newRecord()
        incoming.files = [PatientFile(name: "empty.txt", type: .other, data: Data())]
        try await source.patients.save(incoming)
        let archive = sourceRoot.rootURL.appendingPathComponent("incoming.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(to: archive, passphrase: passphrase)

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        let original = patientWithTwoFiles()
        try await target.patients.save(original)
        let keeper = Note(title: "Must survive failed restore", content: "ORIGINAL_LIVE_NOTE")
        try await target.notes.save(keeper)
        var rejected = false
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot))
        } catch { rejected = true }
        XCTAssertTrue(rejected, "Precondition: the empty-attachment restore is rejected")
        let stillThere = try await target.notes.load(id: keeper.id)
        let patientStillThere = try await target.patients.load(id: original.id)
        XCTAssertEqual(stillThere?.content, keeper.content,
                       "Failed restore also failed rollback and removed the original live note")
        XCTAssertNotNil(patientStillThere, "Failed restore removed the original live patient")
        await source.close()
        await target.close()
    }

    func testRejectedPatientSaveKeepsPreviousAttachmentBytes() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var occupied = Patient.newRecord()
        occupied.profile.amka = "11111111111"
        try await store.patients.save(occupied)
        var patient = Patient.newRecord()
        patient.profile.amka = "22222222222"
        patient.files = [PatientFile(name: "scan.txt", type: .other, data: Data("ORIGINAL".utf8))]
        try await store.patients.save(patient)
        let loaded = try await store.patients.load(id: patient.id)
        var draft = try XCTUnwrap(loaded)
        draft.profile.amka = occupied.profile.amka
        draft.files[0].data = Data("REPLACED".utf8)
        var rejected = false
        do { try await store.patients.save(draft) } catch { rejected = true }
        XCTAssertTrue(rejected, "Precondition: duplicate AMKA must reject the database write")
        let unchanged = try await store.patients.load(id: patient.id)
        XCTAssertEqual(unchanged?.profile.amka, "22222222222")
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(String(data: bytes ?? Data(), encoding: .utf8), "ORIGINAL",
                       "Rejected save overwrote the committed attachment")
        await store.close()
    }

    func testPreMigrationBackupCanActuallyRestore() async throws {
        let sourceRoot = try makeRoot()
        let plain = try Database(path: sourceRoot.databaseURL.path)
        let note = Note(title: "Pre-migration", content: "Synthetic historical note")
        try await plain.saveNote(note)
        let service = BackupService(db: plain, fileStore: nil, restorePointsRoot: sourceRoot.restorePointsURL)
        let archive = sourceRoot.rootURL.appendingPathComponent("migration.mednotesbackup")
        _ = try await service.createEncryptedBackup(to: archive, passphrase: passphrase)
        // This is the only verification migrationBackup currently performs.
        XCTAssertNoThrow(try BackupArchiveV2.inspect(at: archive, passphrase: passphrase))
        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
            let restored = try await target.notes.load(id: note.id)
            XCTAssertEqual(restored?.content, note.content)
        } catch {
            XCTFail("Mandatory pre-migration backup passes inspection but cannot restore: \(error.localizedDescription)")
        }
        await plain.close()
        await target.close()
    }
}

@MainActor
final class BugReviewImportReproductionTests: XCTestCase {
    func testLegacyImportPreservesInlineAttachment() async throws {
        let root = try DataRoot.temporary()
        let folder = try DataRoot.temporary()
        let suiteName = "MedNotesTests.BugReviewImport"
        let defaults = TestDefaults.suite(suiteName)
        defer {
            TestDefaults.clear(suiteName)
            try? FileManager.default.removeItem(at: root.rootURL)
            try? FileManager.default.removeItem(at: folder.rootURL)
        }
        let patientsFolder = folder.rootURL.appendingPathComponent("Patients")
        try FileManager.default.createDirectory(at: patientsFolder, withIntermediateDirectories: true)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Synthetic legacy patient"
        patient.files = [PatientFile(name: "legacy.txt", type: .other, data: Data("LEGACY_FILE_BYTES".utf8))]
        try encodeJSONData(patient).write(to: patientsFolder.appendingPathComponent("patient.json"))

        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertTrue(session.isReady)
        try await session.performImport(from: folder.rootURL)
        await session.lockNow(reason: "review")

        let reopened = try AppStore.testStore(dataRoot: root)
        let loaded = try await reopened.patients.load(id: patient.id)
        XCTAssertEqual(loaded?.files.count, 1)
        XCTAssertNotNil(loaded?.files.first?.storageID, "Successful legacy import never stored/encrypted inline bytes")
        let bytes = try await reopened.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(bytes, patient.files[0].data, "Successful legacy import lost its attachment bytes")
        await reopened.close()
    }
}
