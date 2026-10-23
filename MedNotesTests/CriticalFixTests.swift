import XCTest
@testable import MedNotes

/// Review-only regression tests. These assert the intended behavior and are
/// expected to fail against the unmodified source reviewed on 2026-10-22.
final class CriticalFixTests: XCTestCase {
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
        let name = try await source.backups.createEncryptedRestorePoint(name: "Review point")
        await source.close()

        let file = root.restorePointsURL.appendingPathComponent(name)
        // The public literal that used to seal every point opens nothing now.
        XCTAssertThrowsError(try BackupArchiveV2.inspect(
            at: file, passphrase: "MedNotesRestorePointMedNotesRestorePoint"))
        // Neither does another device's key, nor the database or attachment key.
        for wrong in [Data(repeating: 7, count: 32), TestKeys.database(for: root),
                      TestKeys.attachment(for: root)] {
            XCTAssertThrowsError(try BackupArchiveV2.inspect(at: file, sealing: .deviceKey(wrong)))
        }
        // The device restore key reads it, and the inner snapshot still holds the note.
        let opened = try BackupArchiveV2.openReader(
            at: file, sealing: .deviceKey(TestKeys.restorePoint(for: root)))
        defer { try? opened.reader.handle.close() }
        let snapshot = root.rootURL.appendingPathComponent("extracted.db")
        _ = try await ArchiveExtraction.extract(
            opened: opened, snapshotURL: snapshot,
            store: try EncryptedFileStore(
                root: root.rootURL.appendingPathComponent("scratch-att"), key: Data(repeating: 1, count: 32)))
        let extracted = try Database(path: snapshot.path, key: opened.archiveKey)
        let loaded = try await extracted.loadNote(id: note.id)
        await extracted.close()
        XCTAssertEqual(loaded?.content, note.content)
    }

    func testLegacyRestorePointIsResealedUnderTheDeviceKey() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Legacy point", content: "LEGACY_POINT_MARKER")
        try await store.notes.save(note)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "a.txt", type: .other, data: Data("AAAA".utf8)),
                         PatientFile(name: "empty.txt", type: .other, data: Data())]
        try await store.patients.save(patient)
        // Write a point the way the old build did: sealed under the public passphrase.
        let url = root.restorePointsURL.appendingPathComponent("restore_legacy.mnrp")
        let db = await store.db
        let records = try await db.allAttachmentRecords().map { row in
            BackupArchiveV2.AttachmentRecord(
                fileID: row.fileID, patientID: row.patientID, name: row.name, type: row.type,
                storageID: row.storageID, plaintextLength: row.plaintextLength, digest: row.digest,
                uploadDate: row.uploadDate, notes: row.notes, tags: row.tags)
        }
        let fileStore = await store.fileStore
        let counts = try await db.counts()
        try await BackupArchiveV2.seal(
            manifest: BackupArchiveV2.Manifest(
                name: "Old point", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                schemaVersion: Schema.currentVersion, counts: counts, attachmentCount: records.count),
            databaseSnapshot: { key in
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("legacy-\(UUID().uuidString).db")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await db.vacuumInto(path: tmp.path, key: key)
                return try Data(contentsOf: tmp)
            },
            attachments: records,
            attachmentReader: { try await fileStore.read(storageID: $0.storageID) },
            passphrase: BackupService.legacyRestorePointPassphrase, to: url)
        XCTAssertEqual(BackupArchiveV2.profile(at: url), 1)

        let converted = await store.backups.upgradeLegacyRestorePoints()
        XCTAssertEqual(converted, 1)
        XCTAssertEqual(BackupArchiveV2.profile(at: url), BackupArchiveV2.deviceKeyProfile)
        XCTAssertThrowsError(try BackupArchiveV2.inspect(
            at: url, passphrase: BackupService.legacyRestorePointPassphrase))
        let inspection = try BackupArchiveV2.inspect(
            at: url, sealing: .deviceKey(TestKeys.restorePoint(for: root)))
        XCTAssertEqual(inspection.manifest.name, "Old point")
        XCTAssertEqual(inspection.manifest.attachmentCount, 2)
        // The upgraded point is still a complete archive: it holds the database
        // and both attachments, readable only with the device key.
        let opened = try BackupArchiveV2.openReader(
            at: url, sealing: .deviceKey(TestKeys.restorePoint(for: root)))
        defer { try? opened.reader.handle.close() }
        let scratch = root.rootURL.appendingPathComponent("upgraded-check", isDirectory: true)
        let extracted = try await ArchiveExtraction.extract(
            opened: opened, snapshotURL: root.rootURL.appendingPathComponent("upgraded.db"),
            store: try EncryptedFileStore(root: scratch, key: Data(repeating: 9, count: 32)))
        XCTAssertEqual(extracted.attachments.count, 2)
        let restoredDB = try Database(
            path: root.rootURL.appendingPathComponent("upgraded.db").path, key: opened.archiveKey)
        let marker = try await restoredDB.loadNote(id: note.id)
        XCTAssertEqual(marker?.content, "LEGACY_POINT_MARKER")
        await restoredDB.close()
        let again = await store.backups.upgradeLegacyRestorePoints()
        XCTAssertEqual(again, 0, "an upgraded point is not converted twice")
        await store.close()
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
            attachmentKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.attachments),
            restorePointKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.restorePoints))
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

    /// A target store holding a patient with two attachments and a note.
    private func populatedTarget() async throws -> (AppStore, DataRoot, Patient, Note) {
        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        let original = patientWithTwoFiles()
        try await target.patients.save(original)
        let keeper = Note(title: "Must survive failed restore", content: "ORIGINAL_LIVE_NOTE")
        try await target.notes.save(keeper)
        return (target, targetRoot, original, keeper)
    }

    private func assertOriginalIntact(
        _ target: AppStore, _ original: Patient, _ keeper: Note,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let note = try await target.notes.load(id: keeper.id)
        XCTAssertEqual(note?.content, keeper.content, "Failed restore lost the live note", file: file, line: line)
        let patient = try await target.patients.load(id: original.id)
        XCTAssertNotNil(patient, "Failed restore lost the live patient", file: file, line: line)
        for item in original.files {
            let bytes = try await target.patients.loadFileData(patientId: original.id, fileId: item.id)
            XCTAssertEqual(bytes, item.data, "Failed restore lost \(item.name)", file: file, line: line)
        }
    }

    func testFailedInstallKeepsOriginalDataWithTwoAttachments() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        var incoming = Patient.newRecord()
        incoming.files = [PatientFile(name: "incoming.txt", type: .other, data: Data("INCOMING".utf8))]
        try await source.patients.save(incoming)
        let archive = sourceRoot.rootURL.appendingPathComponent("incoming.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(to: archive, passphrase: passphrase)

        let (target, targetRoot, original, keeper) = try await populatedTarget()
        struct Boom: Error {}
        await target.backups.setInstallFaultForTesting { throw Boom() }
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot))
            XCTFail("the injected install fault must fail the restore")
        } catch BackupError.restoreFailed {}
        try await assertOriginalIntact(target, original, keeper)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: targetRoot.rootURL.path)
            .filter { $0.hasPrefix("RestoreRollback-") }
        XCTAssertTrue(leftovers.isEmpty, "a clean rollback leaves no rollback folder")
        await source.close()
        await target.close()
    }

    func testRestoreOfArchiveWithWrongDigestIsRejectedBeforeAnythingChanges() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        var incoming = Patient.newRecord()
        incoming.files = [PatientFile(name: "incoming.txt", type: .other, data: Data("INCOMING".utf8))]
        try await source.patients.save(incoming)
        var record = try await source.db.allAttachmentRecords().first.map { row in
            BackupArchiveV2.AttachmentRecord(
                fileID: row.fileID, patientID: row.patientID, name: row.name, type: row.type,
                storageID: row.storageID, plaintextLength: row.plaintextLength, digest: row.digest,
                uploadDate: row.uploadDate, notes: row.notes, tags: row.tags)
        }!
        record.digest = String(repeating: "0", count: 64)
        let archive = sourceRoot.rootURL.appendingPathComponent("forged.mednotesbackup")
        let db = await source.db
        try await BackupArchiveV2.seal(
            manifest: BackupArchiveV2.Manifest(
                name: "forged", createdAt: Date(), schemaVersion: Schema.currentVersion,
                counts: [:], attachmentCount: 1),
            databaseSnapshot: { key in
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("forged-\(UUID().uuidString).db")
                defer { try? FileManager.default.removeItem(at: url) }
                try await db.vacuumInto(path: url.path, key: key)
                return try Data(contentsOf: url)
            },
            attachments: [record],
            attachmentReader: { _ in Data("INCOMING".utf8) },
            passphrase: passphrase, to: archive)

        let (target, targetRoot, original, keeper) = try await populatedTarget()
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot))
            XCTFail("an attachment whose digest disagrees must be rejected")
        } catch {}
        try await assertOriginalIntact(target, original, keeper)
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
final class CriticalFixImportTests: XCTestCase {
    func testLegacyImportPreservesInlineAttachment() async throws {
        let root = try DataRoot.temporary()
        let folder = try DataRoot.temporary()
        let suiteName = "MedNotesTests.CriticalFixImport"
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

final class AttachmentVersionTests: XCTestCase {
    /// Two drafts of one patient: the first replaces the attachment, the second
    /// (older) changes only the name. Saving the older draft must be refused
    /// instead of repointing the row at a deleted object and sweeping the
    /// current one.
    func testStaleDraftCannotDestroyAReplacedAttachment() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "scan.txt", type: .other, data: Data("ONE".utf8))]
        try await store.patients.save(patient)
        let firstLoaded = try await store.patients.load(id: patient.id)
        var first = try XCTUnwrap(firstLoaded)
        let olderLoaded = try await store.patients.load(id: patient.id)
        var older = try XCTUnwrap(olderLoaded)

        first.files[0].data = Data("TWO".utf8)
        try await store.patients.save(first)
        let current = try await store.db.attachmentStorageID(patientId: patient.id, fileId: patient.files[0].id)

        older.profile.firstName = "Renamed"
        do {
            try await store.patients.save(older)
            XCTFail("a draft holding a superseded attachment reference must not save")
        } catch is StaleAttachmentError {}

        let after = try await store.db.attachmentStorageID(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(after, current)
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(bytes, Data("TWO".utf8))
        let objects = try FileManager.default.contentsOfDirectory(atPath: root.attachmentsURL.path)
        XCTAssertEqual(objects, [try XCTUnwrap(current)])
        await store.close()
    }

    /// Same, when the first draft removed the file and added another.
    func testStaleDraftCannotDestroyAnAttachmentAddedInPlaceOfOne() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "old.txt", type: .other, data: Data("OLD".utf8))]
        try await store.patients.save(patient)
        let firstLoaded = try await store.patients.load(id: patient.id)
        var first = try XCTUnwrap(firstLoaded)
        let olderLoaded = try await store.patients.load(id: patient.id)
        var older = try XCTUnwrap(olderLoaded)

        let replacement = PatientFile(name: "new.txt", type: .other, data: Data("NEW".utf8))
        first.files = [replacement]
        try await store.patients.save(first)

        older.profile.firstName = "Renamed"
        do {
            try await store.patients.save(older)
            XCTFail("a draft referencing a removed attachment must not save")
        } catch is StaleAttachmentError {}

        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: replacement.id)
        XCTAssertEqual(bytes, Data("NEW".utf8))
        await store.close()
    }

    /// The first draft adds a file; the older draft still lists only the first
    /// file. Saving it with the ids it was loaded with must not delete the new
    /// file.
    func testStaleDraftCannotDeleteAFileItNeverSaw() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "scan.txt", type: .other, data: Data("ONE".utf8))]
        try await store.patients.save(patient)
        let firstLoaded = try await store.patients.load(id: patient.id)
        var first = try XCTUnwrap(firstLoaded)
        let olderLoaded = try await store.patients.load(id: patient.id)
        var older = try XCTUnwrap(olderLoaded)
        let known = Set(older.files.map(\.id))

        let added = PatientFile(name: "second.txt", type: .other, data: Data("TWO".utf8))
        first.files.append(added)
        try await store.patients.save(first, knownFileIDs: known)

        older.profile.firstName = "Renamed"
        do {
            try await store.patients.save(older, knownFileIDs: known)
            XCTFail("a draft that never saw a stored file must not delete it")
        } catch is StaleAttachmentError {}
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: added.id)
        XCTAssertEqual(bytes, Data("TWO".utf8))

        // A deliberate removal of a file the draft was loaded with still works.
        let freshLoaded = try await store.patients.load(id: patient.id)
        var fresh = try XCTUnwrap(freshLoaded)
        let freshKnown = Set(fresh.files.map(\.id))
        fresh.files.removeAll { $0.id == added.id }
        try await store.patients.save(fresh, knownFileIDs: freshKnown)
        let remaining = try await store.patients.load(id: patient.id)
        XCTAssertEqual(remaining?.files.count, 1)
        await store.close()
    }

    func testSuccessfulReplacementRemovesThePreviousObject() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "scan.txt", type: .other, data: Data("ONE".utf8))]
        try await store.patients.save(patient)
        let firstID = try await store.db.attachmentStorageID(patientId: patient.id, fileId: patient.files[0].id)
        let loaded = try await store.patients.load(id: patient.id)
        var draft = try XCTUnwrap(loaded)
        draft.files[0].data = Data("TWO".utf8)
        try await store.patients.save(draft)
        let secondID = try await store.db.attachmentStorageID(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertNotEqual(firstID, secondID)
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(bytes, Data("TWO".utf8))
        let objects = try FileManager.default.contentsOfDirectory(atPath: root.attachmentsURL.path)
        XCTAssertEqual(objects, [try XCTUnwrap(secondID)], "the superseded object must be gone")
        await store.close()
    }

    func testOrphanSweepRemovesOnlyUnreferencedObjects() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "keep.txt", type: .other, data: Data("KEEP".utf8))]
        try await store.patients.save(patient)
        let orphan = try await store.fileStore.store(Data("ORPHAN".utf8))
        let staging = root.attachmentsURL.appendingPathComponent("\(UUID().uuidString.lowercased()).staging-x")
        try Data("partial".utf8).write(to: staging)
        let stranger = root.attachmentsURL.appendingPathComponent("notes.txt")
        try Data("not ours".utf8).write(to: stranger)

        // Fresh files are left for an hour, so an orphan only counts once it is old.
        let youngSweep = await store.sweepOrphanedAttachments()
        XCTAssertEqual(youngSweep, 0, "nothing younger than the minimum age is removed")
        let longAgo = Date().addingTimeInterval(-7200)
        for url in [root.attachmentsURL.appendingPathComponent(orphan), staging, stranger] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }
        let removed = await store.sweepOrphanedAttachments()
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.attachmentsURL.appendingPathComponent(orphan).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(bytes, Data("KEEP".utf8))
        await store.close()
    }
}

final class PreMigrationBackupTests: XCTestCase {
    private var roots: [DataRoot] = []
    private let passphrase = "premigration passphrase 2026"

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    /// A plaintext store with a note and one patient whose attachment still
    /// lives under `Files/`, the way the old build wrote it.
    private func plaintextStore(in root: DataRoot) async throws -> (Database, Note, Patient) {
        let plain = try Database(path: root.databaseURL.path)
        let note = Note(title: "Pre-migration", content: "PRE_MIGRATION_MARKER")
        try await plain.saveNote(note)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "legacy.txt", type: .other, data: nil)]
        try await plain.savePatient(patient)
        let dir = root.filesURL.appendingPathComponent(patient.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("LEGACY_FILE_BYTES".utf8).write(to: dir.appendingPathComponent(patient.files[0].id.uuidString))
        return (plain, note, patient)
    }

    func testPreMigrationBackupCarriesPlaintextStoreAttachments() async throws {
        let sourceRoot = try makeRoot()
        let (plain, note, patient) = try await plaintextStore(in: sourceRoot)
        let service = BackupService(
            db: plain, fileStore: nil, restorePointsRoot: sourceRoot.restorePointsURL,
            legacyFilesRoot: sourceRoot.filesURL)
        let archive = sourceRoot.rootURL.appendingPathComponent("pre.mednotesbackup")
        _ = try await service.createEncryptedBackup(to: archive, passphrase: passphrase)
        let verified = try await BackupService.verifyFullRestore(of: archive, passphrase: passphrase)
        XCTAssertEqual(verified.counts["notes"], 1)

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
        let restoredNote = try await target.notes.load(id: note.id)
        XCTAssertEqual(restoredNote?.content, note.content)
        let bytes = try await target.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(bytes, Data("LEGACY_FILE_BYTES".utf8))
        // The live plaintext store was not changed by making the backup.
        let untouched = try await plain.attachmentsNeedingEncryption()
        XCTAssertEqual(untouched.count, 1)
        await plain.close()
        await target.close()
    }

    func testBackupWithAPlaintextInnerSnapshotStillRestores() async throws {
        // What an already-written pre-migration backup looks like: the
        // database inside the archive is a plaintext SQLite file.
        let sourceRoot = try makeRoot()
        let plain = try Database(path: sourceRoot.databaseURL.path)
        let note = Note(title: "Old", content: "OLD_PREMIGRATION_BACKUP")
        try await plain.saveNote(note)
        try await plain.checkpoint()
        let bytes = try Data(contentsOf: sourceRoot.databaseURL)
        let archive = sourceRoot.rootURL.appendingPathComponent("old.mednotesbackup")
        try await BackupArchiveV2.seal(
            manifest: BackupArchiveV2.Manifest(
                name: "Old", createdAt: Date(), schemaVersion: Schema.currentVersion,
                counts: ["notes": 1], attachmentCount: 0),
            databaseSnapshot: { _ in bytes }, attachments: [],
            attachmentReader: { _ in Data() }, passphrase: passphrase, to: archive)

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
        let restored = try await target.notes.load(id: note.id)
        XCTAssertEqual(restored?.content, note.content)
        await plain.close()
        await target.close()
    }

    /// A real plaintext store has an audit trail (the services write one).
    /// Migration used to take its expected counts before copying those rows,
    /// then compare them against the copied table, so any used store failed
    /// validation with `audit_logs: N rows, expected 0`.
    func testMigrationKeepsAStoreWithAuditHistory() async throws {
        let root = try makeRoot()
        let plaintext = try Database(path: root.databaseURL.path)
        let audit = AuditService(db: plaintext)
        let patients = PatientService(db: plaintext, audit: audit)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Audited"
        patient.profile.lastName = "Patient"
        try await patients.save(patient)
        let auditRows = try await plaintext.counts()["audit_logs"] ?? 0
        XCTAssertGreaterThan(auditRows, 0)
        await plaintext.close()

        let backupURL = root.rootURL.appendingPathComponent("pre-migration.mednotesbackup")
        let backupDB = try Database(path: root.databaseURL.path)
        let backup = BackupService(
            db: backupDB, fileStore: nil, restorePointsRoot: root.restorePointsURL)
        _ = try await backup.createEncryptedBackup(
            name: "Pre-encryption", to: backupURL, passphrase: passphrase)
        await backupDB.close()

        let keyManager = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keyManager)
        let report = try await migrator.migrate(
            backupDestination: backupURL, passphrase: passphrase)
        XCTAssertEqual(report.patients, 1)
        try await migrator.finishCleanup()

        let rootKey = try XCTUnwrap(keyManager.rootKey())
        let databaseKey = try StoreKeyContext.subkey(
            rootKey: rootKey, context: StoreKeyContext.database)
        let reopened = try Database(path: root.databaseURL.path, key: databaseKey)
        let counts = try await reopened.counts()
        XCTAssertEqual(counts["patients"], 1)
        XCTAssertEqual(counts["audit_logs"], auditRows)
        await reopened.close()
    }

    /// Missing-key recovery installs a restored database directly, without
    /// `BackupService.installStaged`'s post-restore suspension. It must not
    /// leave a confirmed destination ready to receive writes.
    func testRecoverySuspendsSyncDestinations() async throws {
        let root = try makeRoot()
        let source = try AppStore.testStore(dataRoot: root)
        let candidate = SyncDestinationCandidate(
            calendarIdentifier: "cal-recovery", calendarTitle: "MedNotes",
            sourceIdentifier: "src", sourceTitle: "iCloud", sourceType: "calDAV",
            isAppCreated: true, recordCount: 1, transmittedFields: ["title"],
            requiresCloudAcknowledgment: true)
        _ = try await source.destinations.confirm(bridge: .calendar, candidate: candidate)
        let archive = root.rootURL.appendingPathComponent("recovery.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(
            name: "Recovery", to: archive, passphrase: passphrase)
        await source.close()

        let manager = InMemoryKeyManager()
        _ = try await StoreRecovery(dataRoot: root, keyManager: manager)
            .recover(from: archive, passphrase: passphrase)
        let rootKey = try XCTUnwrap(manager.rootKey())
        let databaseKey = try StoreKeyContext.subkey(
            rootKey: rootKey, context: StoreKeyContext.database)
        let reopened = try Database(path: root.databaseURL.path, key: databaseKey)
        let destination = try await reopened.syncDestination(bridge: .calendar)
        XCTAssertEqual(destination?.state, SyncDestination.ConnectionState.needsReconnection)
        XCTAssertNil(destination?.confirmedAt)
        XCTAssertFalse(SyncDestinationCore.mayWrite(destination))
        await reopened.close()
    }
}

final class LegacyImportAttachmentTests: XCTestCase {
    private func folder(with patients: [Patient]) throws -> (DataRoot, URL) {
        let folder = try DataRoot.temporary()
        let dir = folder.rootURL.appendingPathComponent("Patients")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for patient in patients {
            try encodeJSONData(patient).write(to: dir.appendingPathComponent("\(patient.id).json"))
        }
        return (folder, folder.rootURL)
    }

    func testImportStoresInlineBytesAndAReimportWithoutBytesKeepsThem() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "a.txt", type: .other, data: Data("FIRST".utf8))]
        let (folderRoot, url) = try folder(with: [patient])
        defer { try? FileManager.default.removeItem(at: folderRoot.rootURL) }
        let fileStore = await store.fileStore
        let db = await store.db
        _ = try await JSONImporter(directoryURL: url).importAll(into: db, fileStore: fileStore)
        let firstID = try await db.attachmentStorageID(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertNotNil(firstID)

        // The same record again, this time without the bytes: it must keep the stored content.
        var stripped = patient
        stripped.files[0].data = nil
        let (second, secondURL) = try folder(with: [stripped])
        defer { try? FileManager.default.removeItem(at: second.rootURL) }
        let report = try await JSONImporter(directoryURL: secondURL).importAll(into: db, fileStore: fileStore)
        XCTAssertTrue(report.warnings.isEmpty)
        let bytes = try await store.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(bytes, Data("FIRST".utf8))

        // Re-importing different bytes replaces the object and removes the old one.
        var changed = patient
        changed.files[0].data = Data("SECOND".utf8)
        let (third, thirdURL) = try folder(with: [changed])
        defer { try? FileManager.default.removeItem(at: third.rootURL) }
        _ = try await JSONImporter(directoryURL: thirdURL).importAll(into: db, fileStore: fileStore)
        let objects = try FileManager.default.contentsOfDirectory(atPath: root.attachmentsURL.path)
        XCTAssertEqual(objects.count, 1)
        let latest = try await store.patients.loadFileData(patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(latest, Data("SECOND".utf8))
        await store.close()
    }

    func testFailedImportLeavesNoStagedCiphertext() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        var occupied = Patient.newRecord()
        occupied.profile.amka = "11111111111"
        try await store.patients.save(occupied)
        var clash = Patient.newRecord()
        clash.profile.amka = "11111111111"
        clash.files = [PatientFile(name: "x.txt", type: .other, data: Data("X".utf8))]
        let (folderRoot, url) = try folder(with: [clash])
        defer { try? FileManager.default.removeItem(at: folderRoot.rootURL) }
        let fileStore = await store.fileStore
        let db = await store.db
        do {
            _ = try await JSONImporter(directoryURL: url).importAll(into: db, fileStore: fileStore)
            XCTFail("a duplicate AMKA must reject the batch")
        } catch {}
        let objects = try FileManager.default.contentsOfDirectory(atPath: root.attachmentsURL.path)
        XCTAssertTrue(objects.isEmpty, "the staged ciphertext must be removed: \(objects)")
        await store.close()
    }

}
