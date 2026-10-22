import XCTest
@testable import MedNotes

/// Archiving is what every Delete affordance does for a patient now, so it
/// must hide the record from the active list and the pickers while keeping
/// the row and every link to it — the reverse of `delete`'s finality.
final class ArchiveTests: XCTestCase {
    private var root: DataRoot!
    private var store: AppStore!

    override func setUpWithError() throws {
        root = try DataRoot.temporary()
        store = try AppStore.testStore(dataRoot: root)
    }

    override func tearDownWithError() throws {
        store = nil
        if let root {
            try? FileManager.default.removeItem(at: root.rootURL)
        }
        root = nil
    }

    private func savedPatient(_ first: String = "Archibald", _ last: String = "Testcase") async throws -> Patient {
        var patient = Patient.newRecord()
        patient.profile.firstName = first
        patient.profile.lastName = last
        try await store.patients.save(patient)
        return patient
    }

    func testArchiveHidesFromActiveListsAndSearch() async throws {
        let patient = try await savedPatient()
        try await store.patients.archive(id: patient.id)

        let active = try await store.patients.loadAll(includeArchived: false)
        XCTAssertFalse(active.contains { $0.id == patient.id })
        let everyone = try await store.patients.loadAll(includeArchived: true)
        XCTAssertEqual(everyone.first { $0.id == patient.id }?.isArchived, true)

        let found = try await store.patients.search("Archibald")
        XCTAssertFalse(found.contains { $0.id == patient.id }, "search defaults to active patients")
        let foundArchived = try await store.patients.search("Archibald", includeArchived: true)
        XCTAssertTrue(foundArchived.contains { $0.id == patient.id })
    }

    func testArchiveKeepsTheRowAndItsLinks() async throws {
        let patient = try await savedPatient()
        let todo = TodoItem(title: "Chase results", patientId: patient.id)
        try await store.todos.save(todo)
        let event = CalendarEvent(title: "Review", patientId: patient.id)
        try await store.events.save(event)

        try await store.patients.archive(id: patient.id)

        let loadedTodo = try await store.todos.load(id: todo.id)
        XCTAssertEqual(loadedTodo?.patientId, patient.id)
        XCTAssertEqual(loadedTodo?.patientName, "Archibald Testcase")
        let loadedEvent = try await store.events.load(id: event.id)
        XCTAssertEqual(loadedEvent?.patientId, patient.id)
        let counts = try await store.counts()
        XCTAssertEqual(counts["patients"], 1)
    }

    func testUnarchiveRestoresAndBothStepsAreAudited() async throws {
        let patient = try await savedPatient()
        try await store.patients.archive(id: patient.id)
        try await store.patients.unarchive(id: patient.id)

        let active = try await store.patients.loadAll(includeArchived: false)
        XCTAssertTrue(active.contains { $0.id == patient.id })
        let actions = try await store.audit.recentLogs(limit: 20).map(\.action)
        XCTAssertTrue(actions.contains("patient_archive"))
        XCTAssertTrue(actions.contains("patient_unarchive"))
        XCTAssertFalse(actions.contains("patient_delete"))
    }

    func testArchivingTwiceIsANoOp() async throws {
        let patient = try await savedPatient()
        try await store.patients.archive(id: patient.id)
        try await store.patients.archive(id: patient.id)
        let archives = try await store.audit.recentLogs(limit: 20).filter { $0.action == "patient_archive" }
        XCTAssertEqual(archives.count, 1)
    }

    /// The editor autosaves its draft when it leaves the screen — including
    /// the moment a patient with unsaved edits is archived from the toolbar.
    /// That draft still says `isArchived == false`; saving it must keep the
    /// edits and lose nothing else.
    func testSavingAStaleDraftKeepsTheArchive() async throws {
        let patient = try await savedPatient()
        try await store.patients.archive(id: patient.id)

        var staleDraft = patient          // loaded before the archive
        staleDraft.profile.firstName = "Archie"
        try await store.patients.save(staleDraft)

        let loaded = try await store.patients.load(id: patient.id)
        XCTAssertEqual(loaded?.isArchived, true, "save must not undo an archive")
        XCTAssertEqual(loaded?.profile.firstName, "Archie", "the edit itself is kept")
        let active = try await store.patients.loadAll(includeArchived: false)
        XCTAssertFalse(active.contains { $0.id == patient.id })
    }

    func testArchivedPatientIsNotAnUntouchedNewRecord() async throws {
        let patient = Patient.newRecord()
        try await store.patients.save(patient)
        try await store.patients.archive(id: patient.id)
        let loaded = try await store.patients.load(id: patient.id)
        XCTAssertEqual(loaded?.isUntouchedNewRecord, false,
                       "archiving is a deliberate act; the editor must not discard the record")
    }
}
