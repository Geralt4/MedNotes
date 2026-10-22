import XCTest
@testable import MedNotes

final class ImporterTests: XCTestCase {
    static var testBundle: Bundle { Bundle(for: ImporterTests.self) }

    private var tempDir: URL!
    private var sourceDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-import-\(UUID().uuidString)", isDirectory: true)
        sourceDir = tempDir.appendingPathComponent("MedNotes", isDirectory: true)
        for sub in ["Patients", "Notes", "Todos", "CalendarEvents"] {
            try FileManager.default.createDirectory(
                at: sourceDir.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fixtures = ["patient_full", "note_simple", "todo_high", "todo_workflow", "event_appointment"]
        for name in fixtures {
            guard let url = Self.testBundle.url(forResource: name, withExtension: "json") else {
                XCTFail("missing fixture \(name)")
                continue
            }
            let data = try Data(contentsOf: url)
            let dest: URL
            switch name {
            case "patient_full":
                dest = sourceDir.appendingPathComponent("Patients/patient_full.json")
            case "note_simple":
                dest = sourceDir.appendingPathComponent("Notes/note_simple.json")
            case "todo_high":
                dest = sourceDir.appendingPathComponent("Todos/todo_high.json")
            case "todo_workflow":
                dest = sourceDir.appendingPathComponent("Todos/todo_workflow.json")
            default:
                dest = sourceDir.appendingPathComponent("CalendarEvents/\(name).json")
            }
            try data.write(to: dest)
        }
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeDB() throws -> Database {
        try Database.testDatabase(path: tempDir.appendingPathComponent("import-test.db").path)
    }

    func testImportRealFixtures() async throws {
        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)

        XCTAssertEqual(report.patientsImported, 1, "errors: \(report.errors)")
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(report.todosImported, 2)
        XCTAssertEqual(report.eventsImported, 1)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")

        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 1)
        XCTAssertEqual(counts["notes"], 1)
        XCTAssertEqual(counts["todo_items"], 2)
        XCTAssertEqual(counts["calendar_events"], 1)

        let patients = try await db.loadAllPatients()
        XCTAssertEqual(patients.first?.profile.firstName, "JohnWorkflow")

        let todos = try await db.loadAllTodos()
        XCTAssertEqual(todos.count, 2)
        for todo in todos {
            XCTAssertNil(todo.patientId)
        }

        let events = try await db.loadAllEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.patientId,
                     "event references a patient that does not exist and must be unlinked")
        XCTAssertTrue(
            report.warnings.contains { $0.contains("references missing patient") },
            "expected orphan warning, got: \(report.warnings)")
    }

    func testImportIsIdempotent() async throws {
        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)

        let first = try await importer.importAll(into: db)
        XCTAssertEqual(first.totalImported, 5, "\(first.errors)")

        let second = try await importer.importAll(into: db)
        XCTAssertTrue(second.errors.isEmpty, "\(second.errors)")

        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 1, "duplicate patients imported")
        XCTAssertEqual(counts["notes"], 1, "duplicate notes imported")
        XCTAssertEqual(counts["todo_items"], 2, "duplicate todos imported")
        XCTAssertEqual(counts["calendar_events"], 1, "duplicate events imported")

        let integrity = try await db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

    func testDuplicateIdsAreSkipped() async throws {
        let patient = try decodeJSONData(
            Patient.self,
            from: try Data(contentsOf: try XCTUnwrap(Self.testBundle.url(forResource: "patient_full", withExtension: "json"))))
        try encodeJSONData(patient).write(
            to: sourceDir.appendingPathComponent("Patients/patient_dup.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db)

        XCTAssertEqual(report.patientsImported, 1)
        XCTAssertEqual(report.filesSkipped, 1)
        XCTAssertTrue(report.warnings.contains { $0.contains("duplicate patient") },
                      "expected duplicate warning, got: \(report.warnings)")
        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 1)
    }

    /// The `filesRoot` staging path (stagePatientFiles + FilePromote) is what
    /// the CLI uses, but every other test imports with `filesRoot: nil`, so it
    /// was entirely unexercised. Embedded bytes must land on disk and the row
    /// must keep the id while dropping the inline blob.
    func testImportStagesEmbeddedFileBytesToDisk() async throws {
        let patient = try decodeJSONData(
            Patient.self,
            from: try Data(contentsOf: try XCTUnwrap(
                Self.testBundle.url(forResource: "patient_full", withExtension: "json"))))
        var withFile = patient
        let fileId = UUID()
        let payload = Data("scan-bytes".utf8)
        withFile.files = [PatientFile(
            id: fileId, name: "scan.txt", type: .labResult, data: payload)]
        try encodeJSONData(withFile).write(
            to: sourceDir.appendingPathComponent("Patients/patient_full.json"))

        let filesRoot = tempDir.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        let report = try await importer.importAll(into: db, filesRoot: filesRoot)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")

        let onDisk = filesRoot
            .appendingPathComponent(patient.id.uuidString)
            .appendingPathComponent(fileId.uuidString)
        XCTAssertEqual(try Data(contentsOf: onDisk), payload, "bytes must be promoted to disk")

        let files = try await db.loadPatientFiles(patientId: patient.id)
        XCTAssertEqual(files.map(\.id), [fileId])
        XCTAssertNil(files.first?.data, "inline blob must not be stored in the DB")
        XCTAssertEqual(files.first?.fileSize, payload.count)

        let rel = try await db.loadFileRelativePath(patientId: patient.id, fileId: fileId)
        XCTAssertEqual(rel, "\(patient.id.uuidString)/\(fileId.uuidString)")
    }

    /// README's headline V1.1 fix is "no file_data BLOBs in the iCloud DB".
    /// Byte stripping only happens inside the filesRoot-gated staging paths, so
    /// this pins what an import without a filesRoot actually leaves behind.
    func testImportWithoutFilesRootDoesNotEmbedBlobsInDatabase() async throws {
        let patient = try decodeJSONData(
            Patient.self,
            from: try Data(contentsOf: try XCTUnwrap(
                Self.testBundle.url(forResource: "patient_full", withExtension: "json"))))
        var withFile = patient
        let payload = Data(repeating: 0xAB, count: 512)
        withFile.files = [PatientFile(
            id: UUID(), name: "scan.bin", type: .labResult, data: payload)]
        try encodeJSONData(withFile).write(
            to: sourceDir.appendingPathComponent("Patients/patient_full.json"))

        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        _ = try await importer.importAll(into: db) // no filesRoot

        // WAL mode keeps recent writes in the -wal sidecar; without this the
        // main file would look clean no matter what was written.
        try await db.checkpoint()
        let dbPath = tempDir.appendingPathComponent("import-test.db").path
        let raw = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        // JSONEncoder base64-encodes Data, so that is the form files_json holds.
        let base64 = Data(payload.base64EncodedString().prefix(64).utf8)
        XCTAssertNil(raw.range(of: base64),
                     "file bytes must not be embedded in the database (files_json)")

        // The metadata row is still the authoritative record, without bytes.
        let files = try await db.loadPatientFiles(patientId: patient.id)
        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files.first?.data)
    }

    func testEventLinksWhenPatientExists() async throws {
        var event = try decodeJSONData(
            CalendarEvent.self,
            from: try Data(contentsOf: try XCTUnwrap(Self.testBundle.url(forResource: "event_appointment", withExtension: "json"))))
        let patient = try decodeJSONData(
            Patient.self,
            from: try Data(contentsOf: try XCTUnwrap(Self.testBundle.url(forResource: "patient_full", withExtension: "json"))))
        event.patientId = patient.id

        let db = try makeDB()
        try await db.savePatient(patient)
        try await db.saveEvent(event)

        let loaded = try await db.loadEvent(id: event.id)
        XCTAssertEqual(loaded?.patientId, patient.id)

        let violations = try await db.foreignKeyCheck()
        XCTAssertEqual(violations, 0)

        try await db.deletePatient(id: patient.id)
        let after = try await db.loadEvent(id: event.id)
        XCTAssertNotNil(after)
        XCTAssertNil(after?.patientId, "FK ON DELETE SET NULL should unlink the event")
    }
}
