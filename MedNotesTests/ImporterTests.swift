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
            report.warnings.contains { $0.contains("9550164F") },
            "expected orphan warning, got: \(report.warnings)")
    }

    func testImportIsIdempotent() async throws {
        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)

        let first = try await importer.importAll(into: db)
        XCTAssertEqual(first.totalImported, 5, "\(first.errors)")

        let second = try await importer.importAll(into: db)
        XCTAssertTrue(second.errors.isEmpty, "\(second.errors)")
        XCTAssertEqual(second.totalImported, 0, "a second run adds nothing")
        XCTAssertEqual(second.patientsAlreadyPresent, 1)
        XCTAssertEqual(second.notesAlreadyPresent, 1)
        XCTAssertEqual(second.todosAlreadyPresent, 2)
        XCTAssertEqual(second.eventsAlreadyPresent, 1)

        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 1, "duplicate patients imported")
        XCTAssertEqual(counts["notes"], 1, "duplicate notes imported")
        XCTAssertEqual(counts["todo_items"], 2, "duplicate todos imported")
        XCTAssertEqual(counts["calendar_events"], 1, "duplicate events imported")

        let integrity = try await db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

    /// Importing again used to write every record over the stored one: edits
    /// reverted, completed todos reopened, archive flags and Apple links reset.
    func testReimportingLeavesLaterWorkAlone() async throws {
        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        _ = try await importer.importAll(into: db)

        // Work done in the app since the first import.
        let notes = try await db.loadAllNotes()
        var note = try XCTUnwrap(notes.first)
        note.content = "EDITED AFTER THE IMPORT"
        try await db.saveNote(note)
        let openTodos = try await db.loadAllTodos().filter { !$0.isCompleted }
        var todo = try XCTUnwrap(openTodos.first)
        todo.isCompleted = true
        todo.completedAt = Date()
        try await db.saveTodo(todo)
        let events = try await db.loadAllEvents()
        var event = try XCTUnwrap(events.first)
        event.ekEventIdentifier = "EK-LINKED-AFTER-IMPORT"
        try await db.saveEvent(event)
        let patients = try await db.loadAllPatients()
        let patientID = try XCTUnwrap(patients.first).id
        try await db.setPatientArchived(id: patientID, archived: true, lastModified: Date())

        let again = try await importer.importAll(into: db)

        XCTAssertEqual(again.totalImported, 0)
        XCTAssertEqual(again.totalAlreadyPresent, 5)
        let storedNote = try await db.loadAllNotes().first { $0.id == note.id }
        XCTAssertEqual(storedNote?.content, "EDITED AFTER THE IMPORT")
        let storedTodo = try await db.loadAllTodos().first { $0.id == todo.id }
        XCTAssertEqual(storedTodo?.isCompleted, true, "a completed todo must stay completed")
        let storedEvent = try await db.loadAllEvents().first { $0.id == event.id }
        XCTAssertEqual(storedEvent?.ekEventIdentifier, "EK-LINKED-AFTER-IMPORT",
                       "the link to Apple Calendar must survive")
        let storedPatient = try await db.loadAllPatients().first { $0.id == patientID }
        XCTAssertEqual(storedPatient?.isArchived, true, "an archived patient must stay archived")
    }

    /// Only what is missing is added; what is there is untouched.
    func testReimportAddsOnlyWhatIsMissing() async throws {
        let db = try makeDB()
        let importer = JSONImporter(directoryURL: sourceDir)
        _ = try await importer.importAll(into: db)
        let todos = try await db.loadAllTodos()
        let removed = try XCTUnwrap(todos.first)
        try await db.deleteTodo(id: removed.id)

        let again = try await importer.importAll(into: db)

        XCTAssertEqual(again.todosImported, 1, "only the deleted todo comes back")
        XCTAssertEqual(again.todosAlreadyPresent, 1)
        XCTAssertEqual(again.totalImported, 1)
        let counts = try await db.counts()
        XCTAssertEqual(counts["todo_items"], 2)
    }

    /// A patient the user re-created by hand carries the same AMKA under a new
    /// id. Importing the old one used to fail the whole import on the unique
    /// AMKA column; it is now left out. Its records are not attached to the
    /// stored patient (the match could be a mistyped number): they come in
    /// unlinked, with a warning.
    func testAPatientWithAStoredAMKAIsLeftOutAndItsRecordsComeInUnlinked() async throws {
        let db = try makeDB()
        let legacy = try decodeJSONData(
            Patient.self, from: Data(contentsOf: sourceDir.appendingPathComponent("Patients/patient_full.json")))
        var recreated = legacy
        recreated.id = UUID()
        recreated.files = []
        try await db.savePatient(recreated)
        XCTAssertFalse(AMKA.normalized(legacy.profile.amka).isEmpty, "precondition: the fixture patient has an AMKA")
        // The fixture event names some other patient; point it at this one.
        let eventURL = sourceDir.appendingPathComponent("CalendarEvents/event_appointment.json")
        var eventJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: eventURL)) as? [String: Any])
        eventJSON["patientId"] = legacy.id.uuidString
        try JSONSerialization.data(withJSONObject: eventJSON).write(to: eventURL)

        let report = try await JSONImporter(directoryURL: sourceDir).importAll(into: db)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.patientsImported, 0)
        XCTAssertEqual(report.patientsAlreadyPresent, 1)
        let patients = try await db.loadAllPatients()
        XCTAssertEqual(patients.count, 1, "no second patient with that AMKA")
        let events = try await db.loadAllEvents()
        let event = try XCTUnwrap(events.first)
        XCTAssertNil(event.patientId, "it must not be attached to a patient it may not belong to")
        XCTAssertTrue(report.warnings.contains { $0.contains("without a patient") },
                      "the user is told: \(report.warnings)")
        XCTAssertTrue(report.warnings.contains { $0.contains("references missing patient") })
    }

    /// The same person exported twice, under two ids and two ways of typing the
    /// AMKA. The unique column used to fail the whole import (same text) or the
    /// editor's duplicate check saw two patients (different text).
    func testTwoPatientsWithOneAMKAInTheFolderImportOnce() async throws {
        let db = try makeDB()
        let url = sourceDir.appendingPathComponent("Patients/patient_full.json")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var profile = try XCTUnwrap(json["profile"] as? [String: Any])
        let digits = AMKA.normalized(try XCTUnwrap(profile["amka"] as? String))
        XCTAssertFalse(digits.isEmpty, "precondition: the fixture has an AMKA")
        profile["amka"] = "\(digits.prefix(3))-\(digits.dropFirst(3))"
        json["profile"] = profile
        json["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: json)
            .write(to: sourceDir.appendingPathComponent("Patients/patient_again.json"))

        let report = try await JSONImporter(directoryURL: sourceDir).importAll(into: db)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.patientsImported, 1)
        XCTAssertEqual(report.patientsAlreadyPresent, 1)
        let patients = try await db.loadAllPatients()
        XCTAssertEqual(patients.count, 1)
        XCTAssertEqual(patients.first?.profile.amka, digits, "stored in the normalised form")
    }

    /// The dry run imports into a scratch database but is checked against the
    /// live store, so it reports what the real import will add.
    func testTheDryRunReportsAgainstTheStoreItIsFor() async throws {
        let live = try makeDB()
        _ = try await JSONImporter(directoryURL: sourceDir).importAll(into: live)
        let keys = try await live.storedRecordKeys()
        let scratch = try Database.testDatabase(path: tempDir.appendingPathComponent("scratch.db").path)

        let report = try await JSONImporter(directoryURL: sourceDir)
            .importAll(into: scratch, alreadyStored: keys)

        XCTAssertEqual(report.totalImported, 0)
        XCTAssertEqual(report.totalAlreadyPresent, 5)
        let counts = try await scratch.counts()
        XCTAssertEqual(counts["patients"], 0, "nothing is written for what is already there")
    }

    /// New records in the folder that belong to a patient the store already has.
    /// The dry run writes them into a scratch database that does not hold that
    /// patient, where a todo or event linked to it would break the foreign key.
    func testTheDryRunHandlesNewRecordsOfAPatientTheStoreAlreadyHas() async throws {
        let live = try makeDB()
        var patient = try decodeJSONData(
            Patient.self, from: Data(contentsOf: sourceDir.appendingPathComponent("Patients/patient_full.json")))
        patient.files = []
        try await live.savePatient(patient)

        // The folder: that patient, and a todo, an event and a note that are new
        // to the store but point at it.
        let todoURL = sourceDir.appendingPathComponent("Todos/todo_high.json")
        var todoJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: todoURL)) as? [String: Any])
        todoJSON["patientId"] = patient.id.uuidString
        try JSONSerialization.data(withJSONObject: todoJSON).write(to: todoURL)
        let eventURL = sourceDir.appendingPathComponent("CalendarEvents/event_appointment.json")
        var eventJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: eventURL)) as? [String: Any])
        eventJSON["patientId"] = patient.id.uuidString
        try JSONSerialization.data(withJSONObject: eventJSON).write(to: eventURL)
        let noteURL = sourceDir.appendingPathComponent("Notes/note_simple.json")
        var noteJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: noteURL)) as? [String: Any])
        noteJSON["mentionedPatients"] = [patient.id.uuidString]
        try JSONSerialization.data(withJSONObject: noteJSON).write(to: noteURL)

        let keys = try await live.storedRecordKeys()
        let scratch = try Database.testDatabase(path: tempDir.appendingPathComponent("scratch.db").path)
        let report = try await JSONImporter(directoryURL: sourceDir)
            .importAll(into: scratch, alreadyStored: keys)

        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertEqual(report.patientsAlreadyPresent, 1)
        XCTAssertEqual(report.todosImported, 2)
        XCTAssertEqual(report.eventsImported, 1)
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertFalse(report.warnings.contains { $0.contains("missing patient") },
                       "the patient is in the store, so nothing refers to a missing one: \(report.warnings)")
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

        // A plaintext database: the scan below reads the file itself, and an
        // encrypted one would look clean whatever was written to it.
        let dbPath = tempDir.appendingPathComponent("import-plain.db").path
        let db = try Database(path: dbPath)
        let importer = JSONImporter(directoryURL: sourceDir)
        _ = try await importer.importAll(into: db) // no filesRoot

        // WAL mode keeps recent writes in the -wal sidecar; without this the
        // main file would look clean no matter what was written.
        try await db.checkpoint()
        let raw = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        XCTAssertNotNil(raw.range(of: Data(patient.profile.lastName.utf8)),
                        "control: the scan can see text in this file, so a clean result means something")
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
