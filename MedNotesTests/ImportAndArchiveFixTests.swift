import XCTest
@testable import MedNotes

/// File ids and storage ids in an import, and archiving a patient.
final class ImportAndArchiveFixTests: XCTestCase {
    private var folders: [URL] = []
    private var roots: [DataRoot] = []

    override func tearDownWithError() throws {
        for url in folders { try? FileManager.default.removeItem(at: url) }
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        folders.removeAll()
        roots.removeAll()
    }

    // MARK: - Helpers

    /// A folder the importer can read, holding `patients` as JSON.
    private func folder(with patients: [Patient]) throws -> URL {
        let top = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-importfix-\(UUID().uuidString)", isDirectory: true)
        let dir = top.appendingPathComponent("Patients", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for patient in patients {
            try encodeJSONData(patient).write(to: dir.appendingPathComponent("\(patient.id).json"))
        }
        folders.append(top)
        return top
    }

    private func store() throws -> AppStore {
        let root = try DataRoot.temporary()
        roots.append(root)
        return try AppStore.testStore(dataRoot: root)
    }

    private func patient(named name: String, file: PatientFile) -> Patient {
        var patient = Patient.newRecord()
        patient.profile.firstName = name
        patient.profile.lastName = "Importfix"
        patient.files = [file]
        return patient
    }

    // MARK: - File ids

    func testImportGivesARepeatedFileIdToExactlyOneOfTwoPatientsInOneBatch() async throws {
        let store = try store()
        let first = patient(named: "First", file: PatientFile(name: "a.txt", type: .other, data: Data("FIRST".utf8)))
        var second = patient(named: "Second", file: PatientFile(name: "b.txt", type: .other, data: Data("SECOND".utf8)))
        second.files[0].id = first.files[0].id
        let sharedID = first.files[0].id

        let db = await store.db
        let fileStore = await store.fileStore
        let report = try await JSONImporter(directoryURL: try folder(with: [first, second]))
            .importAll(into: db, fileStore: fileStore)

        XCTAssertEqual(report.warnings.count, 1, "\(report.warnings)")
        // The importer reads files in name order, which here is arbitrary:
        // either patient may keep the file, but never both and never neither.
        let firstRows = try await db.loadPatientFiles(patientId: first.id)
        let secondRows = try await db.loadPatientFiles(patientId: second.id)
        XCTAssertEqual(firstRows.count + secondRows.count, 1, "one file row, not moved and not lost")
        let owner = firstRows.isEmpty ? second : first
        let ownerRows = firstRows.isEmpty ? secondRows : firstRows
        XCTAssertEqual(ownerRows.map(\.id), [sharedID])
        let expected = firstRows.isEmpty ? Data("SECOND".utf8) : Data("FIRST".utf8)
        let bytes = try await store.patients.loadFileData(patientId: owner.id, fileId: sharedID)
        XCTAssertEqual(bytes, expected, "the file that stayed is still readable")
    }

    func testImportDoesNotMoveAFileFromAnotherPatientAlreadyInTheStore() async throws {
        let store = try store()
        let db = await store.db
        let fileStore = await store.fileStore
        let owner = patient(named: "Owner", file: PatientFile(name: "a.txt", type: .other, data: Data("OWNER-BYTES".utf8)))
        _ = try await JSONImporter(directoryURL: try folder(with: [owner])).importAll(into: db, fileStore: fileStore)

        var intruder = patient(named: "Intruder", file: PatientFile(name: "b.txt", type: .other, data: Data("OTHER".utf8)))
        intruder.files[0].id = owner.files[0].id
        let report = try await JSONImporter(directoryURL: try folder(with: [intruder]))
            .importAll(into: db, fileStore: fileStore)

        XCTAssertFalse(report.warnings.isEmpty)
        let ownerRows = try await db.loadPatientFiles(patientId: owner.id)
        XCTAssertEqual(ownerRows.map(\.id), [owner.files[0].id], "the owner keeps its file")
        let bytes = try await store.patients.loadFileData(patientId: owner.id, fileId: owner.files[0].id)
        XCTAssertEqual(bytes, Data("OWNER-BYTES".utf8))
    }

    // MARK: - Storage ids

    func testImportDoesNotTrustAStorageIdWrittenInTheJSON() async throws {
        let store = try store()
        let db = await store.db
        var file = PatientFile(name: "ghost.txt", type: .other, data: nil)
        file.storageID = String(repeating: "ab", count: 16)
        file.plaintextLength = 99
        file.contentDigest = "not-a-real-digest"
        let ghost = patient(named: "Ghost", file: file)
        let fileStore = await store.fileStore

        let report = try await JSONImporter(directoryURL: try folder(with: [ghost]))
            .importAll(into: db, fileStore: fileStore)

        let stored = try await db.attachmentStorageID(patientId: ghost.id, fileId: file.id)
        XCTAssertNil(stored, "a storage id from the JSON names an object this store never made")
        XCTAssertFalse(report.warnings.isEmpty, "the user is told the file has no content")
    }

    func testReimportingTheStoredStorageIdKeepsTheFile() async throws {
        let store = try store()
        let db = await store.db
        let fileStore = await store.fileStore
        let original = patient(named: "Kept", file: PatientFile(name: "a.txt", type: .other, data: Data("KEPT".utf8)))
        _ = try await JSONImporter(directoryURL: try folder(with: [original])).importAll(into: db, fileStore: fileStore)
        let storageID = try await db.attachmentStorageID(patientId: original.id, fileId: original.files[0].id)
        let kept = try XCTUnwrap(storageID)

        var again = original
        again.files[0].data = nil
        again.files[0].storageID = kept
        let report = try await JSONImporter(directoryURL: try folder(with: [again]))
            .importAll(into: db, fileStore: fileStore)

        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
        let bytes = try await store.patients.loadFileData(patientId: original.id, fileId: original.files[0].id)
        XCTAssertEqual(bytes, Data("KEPT".utf8))
    }

    // MARK: - Archiving

    func testArchivingWritesTheFlagAndTheStampAndNothingElse() async throws {
        let store = try store()
        let db = await store.db
        var patient = patient(named: "Archive", file: PatientFile(name: "keep.txt", type: .other, data: nil))
        patient.profile.phone = "6900000001"
        patient.lastModified = Date(timeIntervalSince1970: 1_000_000)
        try await db.savePatient(patient)

        try await store.patients.archive(id: patient.id)
        var found = try await db.loadPatient(id: patient.id)
        var loaded = try XCTUnwrap(found)
        XCTAssertTrue(loaded.isArchived)
        XCTAssertGreaterThan(loaded.lastModified, patient.lastModified)
        XCTAssertEqual(loaded.profile.phone, "6900000001")
        XCTAssertEqual(loaded.files.map(\.id), patient.files.map(\.id), "the attachment list is not rewritten")

        try await store.patients.unarchive(id: patient.id)
        found = try await db.loadPatient(id: patient.id)
        loaded = try XCTUnwrap(found)
        XCTAssertFalse(loaded.isArchived)
        XCTAssertEqual(loaded.files.map(\.id), patient.files.map(\.id))
    }
}
