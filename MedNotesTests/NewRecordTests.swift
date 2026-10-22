import XCTest
@testable import MedNotes

/// The "+" buttons save a template record before the user types, and the
/// editors discard it again if it is left untouched. These pin down what
/// "untouched" means — through the real store, since the editors compare the
/// row they loaded, not the value the creator built in memory.
final class NewRecordTests: XCTestCase {
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

    // MARK: - Pure

    func testTemplatesStartUntouched() {
        XCTAssertTrue(Patient.newRecord().isUntouchedNewRecord)
        XCTAssertTrue(Note.newRecord().isUntouchedNewRecord)
        XCTAssertTrue(TodoItem.newRecord().isUntouchedNewRecord)
        XCTAssertTrue(CalendarEvent.newRecord().isUntouchedNewRecord)
        XCTAssertFalse(Patient.newRecord().profile.hasKnownDateOfBirth)
    }

    func testAnyEditCountsAsTouched() {
        var patient = Patient.newRecord()
        patient.profile.firstName = "Μ"
        XCTAssertFalse(patient.isUntouchedNewRecord)

        var withCondition = Patient.newRecord()
        withCondition.medical.conditions.append(MedicalCondition(name: "Άσθμα"))
        XCTAssertFalse(withCondition.isUntouchedNewRecord)

        var withDOB = Patient.newRecord()
        withDOB.profile.dateOfBirth = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(withDOB.isUntouchedNewRecord)

        var note = Note.newRecord()
        note.content = "x"
        XCTAssertFalse(note.isUntouchedNewRecord)

        var pinned = Note.newRecord()
        pinned.isPinned = true
        XCTAssertFalse(pinned.isUntouchedNewRecord)

        var todo = TodoItem.newRecord()
        todo.priority = .high
        XCTAssertFalse(todo.isUntouchedNewRecord)

        var dated = TodoItem.newRecord()
        dated.dueDate = Date()
        XCTAssertFalse(dated.isUntouchedNewRecord)

        var done = TodoItem.newRecord()
        done.isCompleted = true
        XCTAssertFalse(done.isUntouchedNewRecord)

        // Moving the time of an otherwise blank event is a real edit.
        var moved = CalendarEvent.newRecord()
        moved.startDate.addTimeInterval(3600)
        XCTAssertFalse(moved.isUntouchedNewRecord)

        var longer = CalendarEvent.newRecord()
        longer.endDate.addTimeInterval(1800)
        XCTAssertFalse(longer.isUntouchedNewRecord)

        var allDay = CalendarEvent.newRecord()
        allDay.setAllDay(true)
        XCTAssertFalse(allDay.isUntouchedNewRecord)
    }

    func testIdentityStampsAndSyncBookkeepingAreIgnored() {
        var patient = Patient.newRecord()
        patient.id = UUID()
        patient.lastModified = Date(timeIntervalSinceNow: 100)
        XCTAssertTrue(patient.isUntouchedNewRecord)

        var note = Note.newRecord()
        note.updatedAt = Date(timeIntervalSinceNow: 100)
        XCTAssertTrue(note.isUntouchedNewRecord)

        var todo = TodoItem.newRecord()
        todo.updatedAt = Date(timeIntervalSinceNow: 100)
        todo.reminderIdentifier = "r"
        todo.reminderListIdentifier = "l"
        todo.syncStatus = .synced
        todo.lastSyncDate = Date()
        XCTAssertTrue(todo.isUntouchedNewRecord)

        var event = CalendarEvent.newRecord()
        event.updatedAt = Date(timeIntervalSinceNow: 100)
        event.ekEventIdentifier = "ek"
        event.syncStatus = .synced
        event.lastSyncDate = Date()
        XCTAssertTrue(event.isUntouchedNewRecord)
    }

    func testTypedThenClearedStillQualifies() {
        var patient = Patient.newRecord()
        patient.profile.firstName = "A"
        patient.profile.firstName = ""
        XCTAssertTrue(patient.isUntouchedNewRecord)

        var todo = TodoItem.newRecord()
        todo.dueDate = Date()
        todo.dueDate = nil
        XCTAssertTrue(todo.isUntouchedNewRecord)
    }

    // MARK: - Through the store

    func testUntouchedSurvivesARoundTrip() async throws {
        let patient = Patient.newRecord()
        try await store.patients.save(patient)
        let loadedPatient = try await store.patients.load(id: patient.id)
        XCTAssertEqual(loadedPatient?.isUntouchedNewRecord, true)

        let note = Note.newRecord()
        try await store.notes.save(note)
        let loadedNote = try await store.notes.load(id: note.id)
        XCTAssertEqual(loadedNote?.isUntouchedNewRecord, true)

        let todo = TodoItem.newRecord()
        try await store.todos.save(todo)
        let loadedTodo = try await store.todos.load(id: todo.id)
        XCTAssertEqual(loadedTodo?.isUntouchedNewRecord, true)

        // Schedule and creation stamp both pass through the store's
        // millisecond text format; the check must tolerate that.
        let event = CalendarEvent.newRecord()
        try await store.events.save(event)
        let loadedEvent = try await store.events.load(id: event.id)
        XCTAssertEqual(loadedEvent?.isUntouchedNewRecord, true)
    }

    func testDiscardRemovesTheRowAndAuditsItsOwnAction() async throws {
        let patient = Patient.newRecord()
        try await store.patients.save(patient)
        try await store.patients.discard(id: patient.id)
        let gone = try await store.patients.load(id: patient.id)
        XCTAssertNil(gone)

        let todo = TodoItem.newRecord()
        try await store.todos.save(todo)
        try await store.todos.discard(id: todo.id)
        let goneTodo = try await store.todos.load(id: todo.id)
        XCTAssertNil(goneTodo)

        let event = CalendarEvent.newRecord()
        try await store.events.save(event)
        try await store.events.discard(id: event.id)
        let goneEvent = try await store.events.load(id: event.id)
        XCTAssertNil(goneEvent)

        let actions = try await store.audit.recentLogs(limit: 50).map(\.action)
        XCTAssertTrue(actions.contains("patient_discard"))
        XCTAssertTrue(actions.contains("todo_discard"))
        XCTAssertTrue(actions.contains("event_discard"))
        XCTAssertFalse(actions.contains("patient_delete"),
                       "housekeeping must not read as a user deletion")
    }

    func testDiscardingANoteRemovesItAndWritesNoPlaintext() async throws {
        let note = Note.newRecord()
        try await store.notes.save(note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.vaultURL.path),
                       "saving must not write a plaintext mirror")

        try await store.notes.discard(id: note.id)
        let gone = try await store.notes.load(id: note.id)
        XCTAssertNil(gone)
        let actions = try await store.audit.recentLogs(limit: 50).map(\.action)
        XCTAssertTrue(actions.contains("note_discard"))
    }

    func testDiscardIsIdempotent() async throws {
        let patient = Patient.newRecord()
        try await store.patients.save(patient)
        try await store.patients.discard(id: patient.id)
        try await store.patients.discard(id: patient.id)   // must not throw
        try await store.notes.discard(id: UUID())          // never existed
        let discards = try await store.audit.recentLogs(limit: 50)
            .filter { $0.action == "patient_discard" }
        XCTAssertEqual(discards.count, 1, "a second discard leaves no second audit row")
    }
}
