import XCTest
@testable import MedNotes

final class BackendFixTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-fixes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeDB(_ name: String = "live.db") throws -> Database {
        try Database.testDatabase(path: tempDir.appendingPathComponent(name).path)
    }

    /// A store that refuses to insert the patient named "B", so an import dies
    /// after it has written "A". (A shared AMKA no longer does: the importer
    /// leaves the second patient out.)
    private func makeDBRejectingPatientB() async throws -> Database {
        let path = tempDir.appendingPathComponent("rejecting.db").path
        let seed = try Database.testDatabase(path: path)
        await seed.close()
        let raw = try SQLConnection(path: path, key: TestKeys.database(forPath: path))
        try raw.exec("""
            CREATE TRIGGER reject_b BEFORE INSERT ON patients WHEN NEW.first_name = 'B'
            BEGIN SELECT RAISE(ABORT, 'rejected'); END
            """)
        raw.close()
        return try Database.testDatabase(path: path)
    }

    private func samplePatient(name: String = "Test", amka: String = "12345678901") -> Patient {
        var profile = PatientProfile(
            firstName: name,
            lastName: "Patient",
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -40, to: Date())!,
            gender: .male,
            amka: amka,
            phone: "6900000000",
            email: "\(name.lowercased())@example.com")
        profile.address = Address(street: "Main 1", city: "Athens", postalCode: "12345",
                                  region: "Attica", country: "Greece")
        return Patient(profile: profile)
    }

    // MARK: - Fix 1: restore is validated before it swaps

    func testRestoreRejectsTamperedArchiveAndLeavesStoreIntact() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("restore-root", isDirectory: true))
        let store = try AppStore.testStore(dataRoot: root)
        try await store.patients.save(samplePatient(name: "Before", amka: "11111111111"))

        let file = tempDir.appendingPathComponent("snapshot.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "snapshot", to: file, passphrase: "a long enough passphrase")
        try await store.patients.save(samplePatient(name: "After", amka: "22222222222"))

        var bytes = try Data(contentsOf: file)
        bytes[BackupArchiveV2.headerLength + 8] ^= 0x01
        try bytes.write(to: file)

        do {
            _ = try await store.backups.restore(
                fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
                databaseKey: TestKeys.database(for: root),
                attachmentKey: TestKeys.attachment(for: root),
                createRestorePoint: false)
            XCTFail("a tampered archive must not restore")
        } catch {
            XCTAssertNotNil(error as? BackupArchiveV2.ArchiveError,
                            "it is the archive's own check that refuses it, not a wrong argument: \(error)")
        }
        let patients = try await store.patients.loadAll()
        XCTAssertEqual(patients.count, 2, "a failed restore must leave the live store untouched")
        let integrity = try await store.db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
        let fkViolations = try await store.db.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
    }

    // MARK: - Fix 2: inspecting an archive must not modify it

    func testInspectDoesNotModifyArchive() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("inspect-root", isDirectory: true))
        let store = try AppStore.testStore(dataRoot: root)
        try await store.patients.save(samplePatient())

        let file = tempDir.appendingPathComponent("inspect.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "snapshot", to: file, passphrase: "a long enough passphrase")

        let before = try Data(contentsOf: file)
        let beforeMtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        _ = try await store.backups.inspectEncryptedBackup(at: file, passphrase: "a long enough passphrase")

        let after = try Data(contentsOf: file)
        let afterMtime = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "inspect must not change archive bytes")
        XCTAssertEqual(beforeMtime, afterMtime, "inspect must not touch the archive file")
    }

    // MARK: - Fix 3: note mentioning a missing patient must not violate FKs

    func testNoteMentioningMissingPatientImportsSafely() async throws {
        let db = try makeDB()
        var note = Note(title: "orphan mention", content: "mentions a ghost")
        note.mentionedPatients = [UUID()]

        try await db.saveNote(note)

        let loaded = try await db.loadNote(id: note.id)
        XCTAssertNotNil(loaded)
        let links = try await db.noteLinkCount(noteId: note.id)
        XCTAssertEqual(links, 0)
        let fkViolations = try await db.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
    }

    func testImportNotesWithEmptyKnownPatients() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("Notes", isDirectory: true),
            withIntermediateDirectories: true)
        var note = Note(title: "n", content: "c")
        note.mentionedPatients = [UUID()]
        let data = try encodeJSONData(note)
        try data.write(to: sourceDir.appendingPathComponent("Notes/n.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)

        XCTAssertEqual(report.notesImported, 1)
        let links = try await db.noteLinkCount(noteId: note.id)
        XCTAssertEqual(links, 0)
        XCTAssertTrue(
            report.warnings.contains { $0.contains(String(note.mentionedPatients[0].uuidString.prefix(8))) },
            "expected orphan mention warning, got: \(report.warnings)")
        let fkViolations = try await db.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
    }

    func testImportUnlinksTodoAndClearsPatientName() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("Todos", isDirectory: true),
            withIntermediateDirectories: true)
        let missing = UUID()
        let todo = TodoItem(
            title: "orphan link",
            patientName: "Ghost Patient",
            patientId: missing)
        try encodeJSONData(todo).write(to: sourceDir.appendingPathComponent("Todos/t.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)

        XCTAssertEqual(report.todosImported, 1)
        let loaded = try await db.loadTodo(id: todo.id)
        XCTAssertNil(loaded?.patientId)
        XCTAssertNil(loaded?.patientName, "unlinked import must drop the denormalized name")
        XCTAssertTrue(
            report.warnings.contains { $0.contains(String(missing.uuidString.prefix(8))) },
            "expected orphan warning, got: \(report.warnings)")
    }

    // MARK: - Fix 4: decode failures are reported, not silently dropped

    func testGarbageJSONIsSkippedAndReported() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        for sub in ["Patients", "Notes", "Todos", "CalendarEvents"] {
            try FileManager.default.createDirectory(
                at: sourceDir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try Data("this is not json".utf8).write(
            to: sourceDir.appendingPathComponent("Todos/broken.json"))
        try Data("{\"id\": \"not-a-uuid\"}".utf8).write(
            to: sourceDir.appendingPathComponent("CalendarEvents/broken.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)

        XCTAssertEqual(report.filesSkipped, 2)
        XCTAssertEqual(report.errors.count, 2)
        XCTAssertTrue(report.errors.contains { $0.contains("broken.json") })
        let counts = try await db.counts()
        XCTAssertEqual(counts["todo_items"], 0)
        XCTAssertEqual(counts["calendar_events"], 0)
    }

    // MARK: - Fix 5: empty AMKA is not unique

    func testTwoPatientsWithEmptyAMKABothSave() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient(name: "One", amka: ""))
        try await db.savePatient(samplePatient(name: "Two", amka: ""))
        let count = try await db.loadAllPatients().count
        XCTAssertEqual(count, 2)
    }

    func testDuplicateNonEmptyAMKAFails() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient(name: "One", amka: "12345678901"))
        do {
            try await db.savePatient(samplePatient(name: "Two", amka: "12345678901"))
            XCTFail("duplicate non-empty AMKA must be rejected")
        } catch {
            XCTAssertTrue(true)
        }
        let count = try await db.loadAllPatients().count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Fix 6: listBackups finds folders regardless of trailing slash

    func testListRestorePointsIgnoresStrayFiles() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("list-root", isDirectory: true))
        let store = try AppStore.testStore(dataRoot: root)
        try await store.patients.save(samplePatient())

        _ = try await store.backups.createEncryptedRestorePoint(
            name: "snapshot")

        let stray = root.restorePointsURL.appendingPathComponent("not_a_point.txt")
        try Data("x".utf8).write(to: stray)

        let infos = try await store.backups.listRestorePoints()
        XCTAssertEqual(infos.count, 1, "only .mnrp files are restore points")
    }

    // MARK: - Fix 7: import is atomic

    func testImportRollsBackOnDBFailure() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        for sub in ["Patients", "Notes", "Todos", "CalendarEvents"] {
            try FileManager.default.createDirectory(
                at: sourceDir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try encodeJSONData(samplePatient(name: "A", amka: "11111111111")).write(
            to: sourceDir.appendingPathComponent("Patients/a.json"))
        try encodeJSONData(samplePatient(name: "B", amka: "22222222222")).write(
            to: sourceDir.appendingPathComponent("Patients/b.json"))

        let db = try await makeDBRejectingPatientB()
        let importer = JSONImporter(directoryURL: sourceDir)
        do {
            _ = try await importer.importAll(into: db)
            XCTFail("a failed insert must fail the import")
        } catch {
            XCTAssertTrue(true)
        }

        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 0, "failed import must roll back entirely")
        XCTAssertEqual(counts["notes"], 0)
        XCTAssertEqual(counts["todo_items"], 0)
        XCTAssertEqual(counts["calendar_events"], 0)
    }

    // MARK: - Fix 8: patient files go to disk, not into the DB

    func testPatientFilesEncryptToTheAttachmentStore() async throws {
        let attachments = tempDir.appendingPathComponent("Attachments", isDirectory: true)
        let db = try makeDB()
        let audit = AuditService(db: db)
        let store = try EncryptedFileStore.testStore(at: attachments)
        let service = PatientService(db: db, audit: audit, filesRoot: nil, fileStore: store)

        let payload = Data("medical record bytes".utf8)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "scan.pdf", type: .pdf, data: payload)]

        try await service.save(patient)

        let loaded = try await service.load(id: patient.id)
        XCTAssertEqual(loaded?.files.count, 1)
        XCTAssertNil(loaded?.files.first?.data, "file bytes must not be stored in the DB")
        let storageID = try XCTUnwrap(loaded?.files.first?.storageID)
        XCTAssertTrue(EncryptedFileStore.isSafeStorageID(storageID))
        XCTAssertNotEqual(storageID.lowercased(), patient.files[0].id.uuidString.lowercased(),
                          "the on-disk id must not be the model id")

        // Nothing readable beside the store.
        let entries = try FileManager.default.contentsOfDirectory(atPath: attachments.path)
        XCTAssertEqual(entries, [storageID])
        let ciphertext = try Data(contentsOf: attachments.appendingPathComponent(storageID))
        XCTAssertFalse(ciphertext.contains(payload), "attachment bytes must not be readable on disk")

        let roundTrip = try await service.loadFileData(
            patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(roundTrip, payload)
    }

    // MARK: - Leftover 1: deleting a patient removes its encrypted attachments

    func testDeletePatientRemovesEncryptedAttachments() async throws {
        let attachments = tempDir.appendingPathComponent("Attachments", isDirectory: true)
        let db = try makeDB()
        let audit = AuditService(db: db)
        let store = try EncryptedFileStore.testStore(at: attachments)
        let service = PatientService(db: db, audit: audit, filesRoot: nil, fileStore: store)

        var patient = samplePatient()
        patient.files = [PatientFile(name: "a.pdf", type: .pdf, data: Data("a".utf8))]
        try await service.save(patient)
        let saved = try await service.load(id: patient.id)
        let storageID = try XCTUnwrap(saved?.files.first?.storageID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: attachments.appendingPathComponent(storageID).path))

        try await service.delete(id: patient.id)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: attachments.appendingPathComponent(storageID).path),
            "the encrypted attachment must be removed on delete")
        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 0)
    }

    func testRemovingAFileFromAPatientLeavesTheRest() async throws {
        let attachments = tempDir.appendingPathComponent("Attachments", isDirectory: true)
        let db = try makeDB()
        let audit = AuditService(db: db)
        let store = try EncryptedFileStore.testStore(at: attachments)
        let service = PatientService(db: db, audit: audit, filesRoot: nil, fileStore: store)

        var patient = samplePatient()
        let fileA = PatientFile(name: "a.pdf", type: .pdf, data: Data("a".utf8))
        let fileB = PatientFile(name: "b.pdf", type: .pdf, data: Data("b".utf8))
        patient.files = [fileA, fileB]
        try await service.save(patient)
        let saved = try await service.load(id: patient.id)
        let storageA = try XCTUnwrap(saved?.files.first { $0.id == fileA.id }?.storageID)

        var updated = try XCTUnwrap(saved)
        updated.files = updated.files.filter { $0.id == fileA.id }
        try await service.save(updated)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: attachments.appendingPathComponent(storageA).path))
        let roundTrip = try await service.loadFileData(patientId: patient.id, fileId: fileA.id)
        XCTAssertEqual(roundTrip, Data("a".utf8))
    }

    // MARK: - Leftover 2: restored schema is validated

    func testRestoreSchemaValidationRejectsUnexpectedView() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient())
        try await db.validateExpectedSchema()
        try await db.conn.exec("CREATE VIEW evil_view AS SELECT id FROM patients")
        do {
            try await db.validateExpectedSchema()
            XCTFail("an unexpected view must be rejected")
        } catch {
            guard case BackupError.unexpectedSchema = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 1, "patients table must survive validation")
    }

    func testRestoreSchemaValidationRejectsForgedFTSTriggers() async throws {
        let db = try makeDB()
        try await db.conn.exec("CREATE TRIGGER audit_probe_fts_insert AFTER INSERT ON notes BEGIN DELETE FROM patients; END")
        do {
            try await db.validateExpectedSchema()
            XCTFail("a trigger with an FTS suffix must not be trusted")
        } catch BackupError.unexpectedSchema { }
        try await db.conn.exec("DROP TRIGGER audit_probe_fts_insert")
        try await db.conn.exec("DROP TRIGGER notes_fts_insert")
        try await db.conn.exec("CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN DELETE FROM patients; END")
        do {
            try await db.validateExpectedSchema()
            XCTFail("a forged known trigger must not be trusted")
        } catch BackupError.unexpectedSchema { }
    }

    // MARK: - Leftover 3: import preserves timestamps, services stamp now

    func testImportPreservesOriginalTimestamps() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("Notes", isDirectory: true),
            withIntermediateDirectories: true)

        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(title: "old", content: "historical", createdAt: fixed, updatedAt: fixed)
        try encodeJSONData(note).write(to: sourceDir.appendingPathComponent("Notes/n.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)
        XCTAssertEqual(report.notesImported, 1)

        let loaded = try await db.loadNote(id: note.id)
        XCTAssertEqual(loaded?.createdAt, fixed)
        XCTAssertEqual(loaded?.updatedAt, fixed)
    }

    func testServiceSaveStampsCurrentTime() async throws {
        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = NoteService(db: db, audit: audit)

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let note = Note(title: "n", content: "c", createdAt: old, updatedAt: old)
        try await service.save(note)

        let loaded = try await db.loadNote(id: note.id)
        XCTAssertEqual(loaded?.createdAt, old, "createdAt must be preserved")
        XCTAssertGreaterThan(loaded?.updatedAt ?? .distantPast, old,
                             "service save must stamp a fresh updatedAt")
    }

    // MARK: - Hardening 1: audit failures surface

    func testAuditLogWrittenAfterServiceSave() async throws {
        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit)

        let patient = samplePatient()
        try await service.save(patient)

        let logs = try await audit.recentLogs()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.action, "patient_save")
        XCTAssertEqual(logs.first?.entityId, patient.id.uuidString)
    }

    func testAuditRejectsEmptyFields() async throws {
        let db = try makeDB()
        let audit = AuditService(db: db)

        do {
            try await audit.log(action: "", entityType: "patient", entityId: UUID().uuidString)
            XCTFail("empty action must be rejected")
        } catch {
            XCTAssertTrue(true)
        }
        let logs = try await audit.recentLogs()
        XCTAssertTrue(logs.isEmpty)
    }

    // MARK: - Hardening 2: loadPatient prefers patient_files

    func testLoadPatientPrefersPatientFilesTable() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        let payload = Data("scan bytes".utf8)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "scan.pdf", type: .pdf, data: payload)]
        try await service.save(patient)

        let loaded = try await service.load(id: patient.id)
        XCTAssertEqual(loaded?.files.count, 1)
        XCTAssertEqual(loaded?.files.first?.name, "scan.pdf")
        XCTAssertNil(loaded?.files.first?.data, "bytes must not be in the model")

        let roundTrip = try await service.loadFileData(
            patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(roundTrip, payload)
    }

    /// Renamed: savePatient always writes patient_files rows, so decodePatient
    /// takes the table branch here and this never reached the files_json
    /// fallback its old name claimed to cover. See the test below for that.
    func testLoadPatientReadsFilesFromPatientFilesTable() async throws {
        let db = try makeDB()
        var patient = samplePatient()
        patient.files = [PatientFile(name: "legacy.pdf", type: .pdf, data: nil)]
        try await db.savePatient(patient)

        let loaded = try await db.loadPatient(id: patient.id)
        XCTAssertEqual(loaded?.files.count, 1)
        XCTAssertEqual(loaded?.files.first?.name, "legacy.pdf")
    }

    /// The real fallback: a legacy row whose files_json is populated but which
    /// has no patient_files rows. Only reachable for databases written by an
    /// older build, so it has to be staged by deleting the junction rows.
    func testLoadPatientFallsBackToFilesJSONWhenTableIsEmpty() async throws {
        let dbPath = tempDir.appendingPathComponent("fallback.db").path
        let db = try Database.testDatabase(path: dbPath)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "legacy.pdf", type: .pdf, data: nil)]
        try await db.savePatient(patient)
        try await db.checkpoint()

        // Strip the junction rows, leaving only files_json behind.
        let side = try SQLConnection.testConnection(path: dbPath)
        try side.exec("DELETE FROM patient_files")
        side.close()

        let rows = try await db.loadPatientFiles(patientId: patient.id)
        XCTAssertTrue(rows.isEmpty, "precondition: table branch must be unavailable")

        let loaded = try await db.loadPatient(id: patient.id)
        XCTAssertEqual(loaded?.files.count, 1, "must fall back to files_json")
        XCTAssertEqual(loaded?.files.first?.name, "legacy.pdf")
        XCTAssertEqual(loaded?.files.first?.id, patient.files[0].id)
    }

    func testFileUpsertMovesPatientIdOnReuse() async throws {
        let db = try makeDB()
        let fileId = UUID()
        var first = samplePatient(name: "One", amka: "11111111111")
        first.files = [PatientFile(id: fileId, name: "a.pdf", type: .pdf)]
        try await db.savePatient(first)

        var second = samplePatient(name: "Two", amka: "22222222222")
        second.files = [PatientFile(id: fileId, name: "b.pdf", type: .pdf)]
        try await db.savePatient(second)

        let rel = try await db.loadFileRelativePath(patientId: second.id, fileId: fileId)
        XCTAssertEqual(rel, "\(second.id.uuidString)/\(fileId.uuidString)")
        let stale = try await db.loadFileRelativePath(patientId: first.id, fileId: fileId)
        XCTAssertNil(stale, "reused file id must leave the original patient")
    }

    // MARK: - Hardening 3: import decodes first, writes in one sync transaction

    func testImportBatchIsAtomic() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        for sub in ["Patients", "Notes", "Todos", "CalendarEvents"] {
            try FileManager.default.createDirectory(
                at: sourceDir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try encodeJSONData(samplePatient(name: "A", amka: "11111111111")).write(
            to: sourceDir.appendingPathComponent("Patients/a.json"))
        try encodeJSONData(samplePatient(name: "B", amka: "22222222222")).write(
            to: sourceDir.appendingPathComponent("Patients/b.json"))

        let db = try await makeDBRejectingPatientB()
        let importer = JSONImporter(directoryURL: sourceDir)
        do {
            _ = try await importer.importAll(into: db)
            XCTFail("a failed insert must fail the import")
        } catch {
            XCTAssertTrue(true)
        }

        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 0, "failed import must roll back entirely")
        XCTAssertEqual(counts["notes"], 0)
        XCTAssertEqual(counts["todo_items"], 0)
        XCTAssertEqual(counts["calendar_events"], 0)
    }

    func testImportBatchCommitsValidSiblings() async throws {
        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        for sub in ["Patients", "Notes", "Todos", "CalendarEvents"] {
            try FileManager.default.createDirectory(
                at: sourceDir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try encodeJSONData(samplePatient(name: "A", amka: "11111111111")).write(
            to: sourceDir.appendingPathComponent("Patients/a.json"))
        try Data("garbage".utf8).write(
            to: sourceDir.appendingPathComponent("Patients/broken.json"))
        try encodeJSONData(Note(title: "n", content: "c")).write(
            to: sourceDir.appendingPathComponent("Notes/n.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)

        XCTAssertEqual(report.patientsImported, 1)
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(report.filesSkipped, 1)
        XCTAssertEqual(report.errors.count, 1)

        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 1)
        XCTAssertEqual(counts["notes"], 1)
    }

    // MARK: - Leftover 1: backup/restore includes encrypted attachments

    func testBackupRestoreIncludesAttachments() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("attachments-root", isDirectory: true))
        let store = try AppStore.testStore(dataRoot: root)

        let payload = Data("original bytes".utf8)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "scan.pdf", type: .pdf, data: payload)]
        try await store.patients.save(patient)
        let originalFile = patient.files[0]

        let file = tempDir.appendingPathComponent("with-files.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "snapshot", to: file, passphrase: "a long enough passphrase")

        let changed = Data("changed bytes".utf8)
        patient.files = [PatientFile(id: originalFile.id, name: "scan.pdf", type: .pdf, data: changed)]
        try await store.patients.save(patient)
        let afterChange = try await store.patients.loadFileData(
            patientId: patient.id, fileId: originalFile.id)
        XCTAssertEqual(afterChange, changed)

        _ = try await store.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: root),
            attachmentKey: TestKeys.attachment(for: root),
            createRestorePoint: false)

        let restored = try await store.patients.loadFileData(
            patientId: patient.id, fileId: originalFile.id)
        XCTAssertEqual(restored, payload, "restore must bring back original file bytes")
    }

    func testResavingLoadedPatientKeepsFilesOnDisk() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        let payload = Data("scan bytes".utf8)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "scan.pdf", type: .pdf, data: payload)]
        try await service.save(patient)
        let fileId = patient.files[0].id

        // Round-trip through the store, as the detail editor does.
        let reloaded = try await service.load(id: patient.id)
        var loaded = try XCTUnwrap(reloaded)
        XCTAssertEqual(loaded.files.count, 1)
        XCTAssertNil(loaded.files.first?.data, "loaded metadata carries no bytes")

        loaded.profile.phone = "6912345678"
        try await service.save(loaded)

        let stillThere = try await service.loadFileData(patientId: patient.id, fileId: fileId)
        XCTAssertEqual(stillThere, payload, "editing a patient must not delete its files")
        let onDisk = filesRoot
            .appendingPathComponent(patient.id.uuidString)
            .appendingPathComponent(fileId.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))

        let rows = try await db.loadPatientFiles(patientId: patient.id)
        XCTAssertEqual(rows.map(\.id), [fileId])
        XCTAssertEqual(rows.first?.fileSize, payload.count, "file_size must survive a metadata-only save")
    }

    /// Saves fan out across several actors (Database, LinkingService) with
    /// suspension points between them, so concurrent writes interleave.
    /// The store must stay internally consistent: no duplicate rows, no FK
    /// violations, no corrupted index.
    func testConcurrentSavesKeepStoreConsistent() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        let store = try AppStore.testStore(dataRoot: root)

        let notes = (0..<12).map { Note(title: "Note \($0)", content: "body \($0)") }
        let patients = (0..<8).map { i -> Patient in
            var p = samplePatient(name: "P\(i)", amka: String(format: "%011d", 10_000_000_000 + i))
            p.profile.lastName = "Concurrent\(i)"
            return p
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for note in notes {
                group.addTask { try await store.notes.save(note) }
            }
            for patient in patients {
                group.addTask { try await store.patients.save(patient) }
            }
            try await group.waitForAll()
        }

        let counts = try await store.counts()
        XCTAssertEqual(counts["notes"], notes.count, "every note must be written exactly once")
        XCTAssertEqual(counts["patients"], patients.count)

        let integrity = try await store.integrity()
        XCTAssertEqual(integrity, "ok")
        let violations = try await store.foreignKeyViolations()
        XCTAssertEqual(violations, 0)

        // No plaintext mirror is written anywhere any more.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.vaultURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.filesURL.path))
    }

    // MARK: - Leftover 2: file_size is stored

    func testFileSizeStoredOnServiceSave() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        let payload = Data("exactly twenty bytes!!".utf8)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "a.pdf", type: .pdf, data: payload)]
        try await service.save(patient)

        let loaded = try await service.load(id: patient.id)
        XCTAssertEqual(loaded?.files.first?.fileSize, payload.count)
    }

    // MARK: - Leftover 3: failed save does not delete live files

    func testFailedSaveDoesNotDeleteLiveFiles() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        let payload = Data("keep me".utf8)
        var patient = samplePatient()
        patient.files = [PatientFile(name: "a.pdf", type: .pdf, data: payload)]
        try await service.save(patient)
        let fileA = patient.files[0]

        var second = samplePatient(name: "Other", amka: patient.profile.amka)
        second.files = [PatientFile(name: "b.pdf", type: .pdf, data: Data("b".utf8))]

        do {
            try await service.save(second)
            XCTFail("duplicate AMKA must fail")
        } catch {
            XCTAssertTrue(true)
        }

        let patientDir = filesRoot.appendingPathComponent(patient.id.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: patientDir.appendingPathComponent(fileA.id.uuidString).path),
            "original file must survive a failed save")
    }

    func testPromoteRollsBackEarlierFilesWhenLaterMoveFails() throws {
        let dir = tempDir.appendingPathComponent("promote", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest1 = dir.appendingPathComponent("a")
        let dest2 = dir.appendingPathComponent("b")
        try Data("old-a".utf8).write(to: dest1)
        try Data("old-b".utf8).write(to: dest2)
        let tmp1 = dir.appendingPathComponent("a.staging")
        let tmp2 = dir.appendingPathComponent("missing.staging")
        try Data("new-a".utf8).write(to: tmp1)

        XCTAssertThrowsError(try FilePromote.apply([(tmp1, dest1), (tmp2, dest2)]))
        XCTAssertEqual(try Data(contentsOf: dest1), Data("old-a".utf8))
        XCTAssertEqual(try Data(contentsOf: dest2), Data("old-b".utf8))
    }

    func testPromoteRollbackRestoresAfterSuccessfulApply() throws {
        let dir = tempDir.appendingPathComponent("promote-ok", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("a")
        try Data("old-a".utf8).write(to: dest)
        let tmp = dir.appendingPathComponent("a.staging")
        try Data("new-a".utf8).write(to: tmp)

        let txn = try FilePromote.apply([(tmp, dest)])
        XCTAssertEqual(try Data(contentsOf: dest), Data("new-a".utf8))
        txn.rollback()
        XCTAssertEqual(try Data(contentsOf: dest), Data("old-a".utf8))
    }

    func testFailedUpdateDoesNotOverwriteLiveFileBytes() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        try await service.save(samplePatient(name: "Other", amka: "99999999999"))

        let original = Data("keep original bytes".utf8)
        var patient = samplePatient(name: "One", amka: "11111111111")
        let file = PatientFile(name: "a.pdf", type: .pdf, data: original)
        patient.files = [file]
        try await service.save(patient)

        patient.profile.amka = "99999999999"
        patient.files = [PatientFile(id: file.id, name: "a.pdf", type: .pdf, data: Data("replaced".utf8))]
        do {
            try await service.save(patient)
            XCTFail("duplicate AMKA must fail")
        } catch {
            XCTAssertTrue(true)
        }

        let onDisk = try await service.loadFileData(patientId: patient.id, fileId: file.id)
        XCTAssertEqual(onDisk, original, "failed update must not replace live file bytes")
    }

    // MARK: - Leftover 4: delete propagates file errors

    func testDeletePatientWithFilesRemovesFolder() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        var patient = samplePatient()
        patient.files = [PatientFile(name: "a.pdf", type: .pdf, data: Data("a".utf8))]
        try await service.save(patient)

        let patientDir = filesRoot.appendingPathComponent(patient.id.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patientDir.path))

        try await service.delete(id: patient.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: patientDir.path))
        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 0)
    }

    // MARK: - Startup: legacy full AMKA index must migrate without error

    func testLegacyAMKAIndexMigratesOnOpen() async throws {
        let dbPath = tempDir.appendingPathComponent("legacy.db").path
        let legacy = try SQLConnection.testConnection(path: dbPath)
        for statement in Schema.v1 {
            try legacy.exec(statement)
        }
        try legacy.exec("DROP INDEX idx_patients_amka")
        try legacy.exec("CREATE UNIQUE INDEX idx_patients_amka ON patients(amka)")
        legacy.close()

        let db = try Database.testDatabase(path: dbPath)
        let indexSQL = try await db.indexSQL(named: "idx_patients_amka")
        XCTAssertTrue(indexSQL?.contains("WHERE amka != ''") ?? false,
                      "legacy index must be migrated to the partial form")
        let integrity = try await db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

    func testLegacyPatientsFTSAddsFathersNameOnOpen() async throws {
        let dbPath = tempDir.appendingPathComponent("legacy-fts.db").path
        var named = samplePatient(name: "Nikos", amka: "11111111111")
        named.profile.fathersName = "Γεώργιος"
        let seeded = try Database.testDatabase(path: dbPath)
        try await seeded.savePatient(named)
        await seeded.close()

        let legacy = try SQLConnection.testConnection(path: dbPath)
        try legacy.exec("DROP TRIGGER IF EXISTS patients_fts_insert")
        try legacy.exec("DROP TRIGGER IF EXISTS patients_fts_delete")
        try legacy.exec("DROP TRIGGER IF EXISTS patients_fts_update")
        try legacy.exec("DROP TABLE IF EXISTS patients_fts")
        try legacy.exec("""
            CREATE VIRTUAL TABLE patients_fts USING fts5(
                id UNINDEXED, first_name, last_name, full_name, phone, email, amka
            )
            """)
        try legacy.exec("""
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka)
            SELECT rowid, id, first_name, last_name, first_name || ' ' || last_name, phone, email, amka
            FROM patients
            """)
        legacy.close()

        let db = try Database.testDatabase(path: dbPath)
        let hits = try await db.searchPatients("γεώργιος")
        XCTAssertEqual(hits.map(\.profile.firstName), ["Nikos"])
        let integrity = try await db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

    func testServiceSaveUnlinksMissingPatient() async throws {
        let db = try makeDB()
        let audit = AuditService(db: db)
        let todos = TodoService(db: db, audit: audit)
        let events = CalendarEventService(db: db, audit: audit)

        let todo = TodoItem(title: "orphan", patientId: UUID())
        try await todos.save(todo)
        let loadedTodo = try await todos.load(id: todo.id)
        XCTAssertNil(loadedTodo?.patientId)

        let event = CalendarEvent(title: "orphan", patientId: UUID())
        try await events.save(event)
        let loadedEvent = try await events.load(id: event.id)
        XCTAssertNil(loadedEvent?.patientId)
        let fkViolations = try await db.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
    }

    func testPatientSearchExcludesArchived() async throws {
        let db = try makeDB()
        var live = samplePatient(name: "Nikos", amka: "11111111111")
        live.profile.lastName = "Live"
        var archived = samplePatient(name: "Nikos", amka: "22222222222")
        archived.profile.lastName = "Archived"
        archived.isArchived = true
        try await db.savePatient(live)
        try await db.savePatient(archived)

        let hits = try await db.searchPatients("Nikos")
        XCTAssertEqual(hits.map(\.profile.lastName), ["Live"])

        let all = try await db.searchPatients("Nikos", includeArchived: true)
        XCTAssertEqual(Set(all.map(\.profile.lastName)), Set(["Live", "Archived"]))
    }

    /// Saving a patient must not turn a finished course into a discontinued
    /// one, which is what decoding the stored record used to do.
    func testSavingAPatientDoesNotRewriteALapsedMedication() async throws {
        let db = try makeDB()
        let past = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var patient = samplePatient(name: "Course", amka: "66666666666")
        patient.medical.medications = [Medication(name: "Amoxicillin", endDate: past, isActive: true)]
        patient.hospitalizations = [Hospitalization(
            admissionDate: past, dischargeDate: past, status: .admitted)]
        try await db.savePatient(patient)

        // Load, save again as any edit would, and load once more.
        let loadedOnce = try await db.loadPatient(id: patient.id)
        let once = try XCTUnwrap(loadedOnce)
        try await db.savePatient(once)
        let loadedTwice = try await db.loadPatient(id: patient.id)
        let twice = try XCTUnwrap(loadedTwice)

        XCTAssertEqual(twice.medical.medications.first?.isActive, true)
        XCTAssertEqual(twice.hospitalizations.first?.status, .admitted)
        XCTAssertEqual(twice.medical.medications.first?.isStopped, true, "still shown as stopped")
    }

    func testEditorSaveKeepsTheArchiveFlagOfAnExistingRow() async throws {
        let db = try makeDB()
        let draft = samplePatient(name: "Maria", amka: "33333333333")
        try await db.savePatient(draft)
        // The archive commits after the editor loaded its draft.
        try await db.setPatientArchived(id: draft.id, archived: true, lastModified: Date())

        var edited = draft
        edited.profile.lastName = "Edited"
        try await db.savePatient(edited, preservingArchiveFlag: true)

        let stored = try await db.loadPatient(id: draft.id)
        XCTAssertEqual(stored?.profile.lastName, "Edited", "the edit itself is saved")
        XCTAssertEqual(stored?.isArchived, true, "a stale draft must not un-archive the record")
    }

    func testPreservingTheArchiveFlagStillStoresItForANewRow() async throws {
        let db = try makeDB()
        var archived = samplePatient(name: "Eleni", amka: "44444444444")
        archived.isArchived = true
        try await db.savePatient(archived, preservingArchiveFlag: true)
        let stored = try await db.loadPatient(id: archived.id)
        XCTAssertEqual(stored?.isArchived, true)
    }

    func testWholeRecordWritesStillReplaceTheArchiveFlag() async throws {
        let db = try makeDB()
        var patient = samplePatient(name: "Petros", amka: "55555555555")
        patient.isArchived = true
        try await db.savePatient(patient)
        patient.isArchived = false
        // Importers and restores write whole records: the flag comes with them.
        try await db.savePatient(patient)
        let stored = try await db.loadPatient(id: patient.id)
        XCTAssertEqual(stored?.isArchived, false)
    }

    func testFailedNewPatientSaveCleansOrphanFiles() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        try await service.save(samplePatient(name: "One", amka: "12345678901"))

        var second = samplePatient(name: "Two", amka: "12345678901")
        second.files = [PatientFile(name: "b.pdf", type: .pdf, data: Data("b".utf8))]
        do {
            try await service.save(second)
            XCTFail("duplicate AMKA must fail")
        } catch {
            XCTAssertTrue(true)
        }

        let orphanDir = filesRoot.appendingPathComponent(second.id.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path),
                       "failed new-patient save must not leave files on disk")
    }

    func testLoadFileDataRejectsPathTraversal() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        let secret = tempDir.appendingPathComponent("secret.txt")
        try Data("classified".utf8).write(to: secret)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        var patient = samplePatient()
        let file = PatientFile(name: "scan.pdf", type: .pdf, data: Data("scan".utf8))
        patient.files = [file]
        try await service.save(patient)

        let conn = try SQLConnection.testConnection(path: tempDir.appendingPathComponent("live.db").path)
        try conn.exec("PRAGMA foreign_keys = ON")
        let update = try conn.prepare("UPDATE patient_files SET file_path = ? WHERE id = ?")
        update.bind(1, "../secret.txt")
        update.bind(2, file.id.uuidString)
        _ = try update.step()
        conn.close()

        let leaked = try await service.loadFileData(patientId: patient.id, fileId: file.id)
        XCTAssertNil(leaked, "file_path outside Files/ must not be readable")
    }

    func testDeletePatientStripsNoteMentions() async throws {
        let db = try makeDB()
        let patient = samplePatient()
        try await db.savePatient(patient)
        var note = Note(title: "about patient", content: "follow up")
        note.mentionedPatients = [patient.id]
        try await db.saveNote(note)

        let linksBefore = try await db.noteLinkCount(noteId: note.id)
        XCTAssertEqual(linksBefore, 1)

        try await db.deletePatient(id: patient.id)

        let loaded = try await db.loadNote(id: note.id)
        XCTAssertNotNil(loaded)
        XCTAssertFalse(loaded?.mentionedPatients.contains(patient.id) ?? true,
                       "deleted patient must be removed from note mentions")
        let linksAfter = try await db.noteLinkCount(noteId: note.id)
        XCTAssertEqual(linksAfter, 0)
        let fkViolations = try await db.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
    }

    func testDeletePatientClearsTodoPatientName() async throws {
        let db = try makeDB()
        let patient = samplePatient()
        try await db.savePatient(patient)

        let todo = TodoItem(
            title: "follow up",
            patientName: patient.displayName,
            patientId: patient.id)
        try await db.saveTodo(todo)

        try await db.deletePatient(id: patient.id)

        let loaded = try await db.loadTodo(id: todo.id)
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.patientId)
        XCTAssertNil(loaded?.patientName, "denormalized patient name must be cleared on delete")
        let fkViolations = try await db.foreignKeyCheck()
        XCTAssertEqual(fkViolations, 0)
    }

    func testDeletePatientWithoutFilesSucceeds() async throws {
        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let audit = AuditService(db: db)
        let service = PatientService(db: db, audit: audit, filesRoot: filesRoot)

        let patient = samplePatient()
        try await service.save(patient)
        try await service.delete(id: patient.id)
        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 0)
    }

    func testSavePatientUpdatesLinkedTodoName() async throws {
        let db = try makeDB()
        var patient = samplePatient(name: "Before")
        try await db.savePatient(patient)

        let todo = TodoItem(
            title: "follow up",
            patientName: patient.displayName,
            patientId: patient.id)
        try await db.saveTodo(todo)

        patient.profile.firstName = "After"
        try await db.savePatient(patient)

        let loaded = try await db.loadTodo(id: todo.id)
        XCTAssertEqual(loaded?.patientName, patient.displayName)
    }

    func testTodoServiceSaveRefreshesStalePatientName() async throws {
        let db = try makeDB()
        let audit = AuditService(db: db)
        let todos = TodoService(db: db, audit: audit)
        let patient = samplePatient(name: "Live")
        try await db.savePatient(patient)

        let todo = TodoItem(
            title: "follow up",
            patientName: "Stale Name",
            patientId: patient.id)
        try await todos.save(todo)

        let loaded = try await todos.load(id: todo.id)
        XCTAssertEqual(loaded?.patientId, patient.id)
        XCTAssertEqual(loaded?.patientName, patient.displayName)
    }

    func testImportDoesNotRestoreStaleTodoPatientName() async throws {
        let db = try makeDB()
        let patient = samplePatient(name: "Live")
        try await db.savePatient(patient)

        let sourceDir = tempDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("Todos", isDirectory: true),
            withIntermediateDirectories: true)
        let todo = TodoItem(
            title: "follow up",
            patientName: "Stale Name",
            patientId: patient.id)
        try encodeJSONData(todo).write(to: sourceDir.appendingPathComponent("Todos/t.json"))

        let importer = JSONImporter(directoryURL: sourceDir)
        _ = try await importer.importAll(into: db)

        let loaded = try await db.loadTodo(id: todo.id)
        XCTAssertEqual(loaded?.patientId, patient.id)
        XCTAssertEqual(loaded?.patientName, patient.displayName)
    }

    func testRestoreReplacesAttachmentsWithTheArchives() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("restore-files-root", isDirectory: true))
        let store = try AppStore.testStore(dataRoot: root)

        var patient = samplePatient()
        patient.files = [PatientFile(name: "keep.pdf", type: .pdf, data: Data("keep".utf8))]
        try await store.patients.save(patient)

        let file = tempDir.appendingPathComponent("files.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "snapshot", to: file, passphrase: "a long enough passphrase")

        // Add a second, later attachment; the restore must bring back only the
        // snapshot's set.
        patient.files.append(PatientFile(name: "later.pdf", type: .pdf, data: Data("later".utf8)))
        try await store.patients.save(patient)

        _ = try await store.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: root),
            attachmentKey: TestKeys.attachment(for: root),
            createRestorePoint: false)

        let restored = try await store.patients.load(id: patient.id)
        XCTAssertEqual(restored?.files.count, 1)
        XCTAssertEqual(restored?.files.first?.name, "keep.pdf")
        let bytes = try await store.patients.loadFileData(
            patientId: patient.id, fileId: try XCTUnwrap(restored?.files.first?.id))
        XCTAssertEqual(bytes, Data("keep".utf8))
    }

}
