import XCTest
@testable import MedNotes

/// The Apple Reminders bridge shares the calendar bridge's shape: a pure
/// decision + merge core that never touches EventKit, and a store contract —
/// `updatedAt` stamped by user saves and toggles, left alone by sync results —
/// that the last-writer-wins rule depends on.
final class RemindersSyncTests: XCTestCase {
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

    private func fields(_ title: String = "T", notes: String = "", due: DueDay? = nil,
                        completed: Bool = false, priority: TodoPriority = .medium) -> ReminderFields {
        ReminderFields(title: title, notes: notes, dueDay: due, isCompleted: completed, priority: priority)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Due day

    func testDueDayIgnoresTimeOfDayAndStrayComponents() {
        XCTAssertEqual(DueDay(date: date(2026, 9, 11, hour: 8, minute: 5)),
                       DueDay(date: date(2026, 9, 11, hour: 22, minute: 45)))
        var timed = DateComponents(year: 2026, month: 9, day: 11, hour: 14, minute: 30)
        timed.timeZone = TimeZone(identifier: "Europe/Athens")
        XCTAssertEqual(DueDay(components: timed), DueDay(year: 2026, month: 9, day: 11))
        XCTAssertNil(DueDay(components: nil))
        XCTAssertNil(DueDay(components: DateComponents(hour: 9)))
        XCTAssertEqual(DueDay(year: 2026, month: 9, day: 11).date(),
                       Calendar.current.startOfDay(for: date(2026, 9, 11, hour: 8)))
    }

    // MARK: - Pull decisions

    func testPullDecisionTreatsUnchangedRemoteAsSame() {
        var local = TodoItem(title: "Chase renal panel", updatedAt: Date(timeIntervalSince1970: 50))
        local.dueDate = Date()
        local.notes = "ask the lab"
        local.priority = .high
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: ReminderSyncCore.fields(of: local)), .same)
    }

    func testPullDecisionCleanLocalRowAcceptsRemoteEditWithoutConflict() {
        var local = TodoItem(updatedAt: Date(timeIntervalSince1970: 100))
        local.lastSyncDate = Date(timeIntervalSince1970: 120)
        local.syncStatus = .synced
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: fields("remote edit")),
                       .update(conflict: false))
    }

    func testPullDecisionDirtyLocalRowFlagsConflictButStillUpdates() {
        var local = TodoItem(updatedAt: Date(timeIntervalSince1970: 150))
        local.lastSyncDate = Date(timeIntervalSince1970: 100)
        local.syncStatus = .synced
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: fields("remote edit")),
                       .update(conflict: true))
        // Never-synced but freshly edited locally is not a conflict either —
        // both sides hold independent rows until a push runs.
        local.lastSyncDate = nil
        local.syncStatus = .localOnly
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: fields("brand new")),
                       .update(conflict: false))
    }

    func testTimeOfDayOnTheDueDateIsNotDrift() {
        var local = TodoItem(title: "T", updatedAt: Date(timeIntervalSince1970: 100))
        local.dueDate = date(2026, 9, 11, hour: 12)
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: fields(due: DueDay(year: 2026, month: 9, day: 11))),
                       .same)
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: fields(due: DueDay(year: 2026, month: 9, day: 12))),
                       .update(conflict: false))
    }

    func testEmptyNotesAndMissingNotesReadAlike() {
        var local = TodoItem(title: "T")
        local.notes = nil
        XCTAssertEqual(ReminderSyncCore.decide(local: local, remote: fields(notes: "")), .same)
    }

    // MARK: - Merging

    func testMergingKeepsMedNotesOnlyConceptsAndTheLocalInstant() {
        let patientId = UUID()
        let noon = date(2026, 9, 11, hour: 12)
        var merged = TodoItem(title: "old", updatedAt: Date(timeIntervalSince1970: 1),
                              dueDate: noon, notes: "old notes", patientName: "Maria P.",
                              patientId: patientId, tags: ["renal"])
        ReminderSyncCore.merging(
            remote: fields("New Title", notes: "note text",
                           due: DueDay(year: 2026, month: 9, day: 11), priority: .high),
            into: &merged)
        XCTAssertEqual(merged.title, "New Title")
        XCTAssertEqual(merged.notes, "note text")
        XCTAssertEqual(merged.priority, .high)
        // Same day: the local instant stays, so a round trip never rewrites it.
        XCTAssertEqual(merged.dueDate, noon)
        // Compared against values captured before the merge, so the test
        // still fails if merging clears the links it exists to protect.
        XCTAssertEqual(merged.patientId, patientId)
        XCTAssertEqual(merged.patientName, "Maria P.")
        XCTAssertEqual(merged.tags, ["renal"])
    }

    func testMergingMovesTheDueDayAndClearsIt() {
        var todo = TodoItem(title: "T", dueDate: Date())
        ReminderSyncCore.merging(remote: fields(due: DueDay(year: 2026, month: 10, day: 2)), into: &todo)
        XCTAssertEqual(todo.dueDate, date(2026, 10, 2))
        ReminderSyncCore.merging(remote: fields(due: nil), into: &todo)
        XCTAssertNil(todo.dueDate)
        todo.notes = "something"
        ReminderSyncCore.merging(remote: fields(notes: ""), into: &todo)
        XCTAssertNil(todo.notes, "empty remote notes read as no notes, the shape the editor stores")
    }

    func testMergingCompletionCarriesTheRemoteCompletionDate() {
        let completedRemotely = Date(timeIntervalSince1970: 1_700_000_000)
        var todo = TodoItem(title: "T")
        ReminderSyncCore.merging(remote: fields(completed: true), into: &todo, completedAt: completedRemotely)
        XCTAssertTrue(todo.isCompleted)
        XCTAssertEqual(todo.completedAt, completedRemotely)
        ReminderSyncCore.merging(remote: fields(completed: false), into: &todo)
        XCTAssertFalse(todo.isCompleted)
        XCTAssertNil(todo.completedAt)
    }

    func testMergedRowReadsAsCleanOnceStamped() {
        var todo = TodoItem(title: "T", updatedAt: Date(timeIntervalSince1970: 150))
        todo.lastSyncDate = Date(timeIntervalSince1970: 100)
        todo.syncStatus = .synced
        let now = Date(timeIntervalSince1970: 200)
        ReminderSyncCore.merging(remote: fields("remote"), into: &todo, now: now)
        todo.lastSyncDate = now
        XCTAssertEqual(ReminderSyncCore.decide(local: todo, remote: fields("remote")), .same)
        XCTAssertLessThanOrEqual(todo.updatedAt, now)
    }

    // MARK: - Priority

    func testPriorityMappingRoundTripsAndReadsNoneAsMedium() {
        for priority in TodoPriority.allCases {
            XCTAssertEqual(
                ReminderSyncCore.priority(fromReminder: ReminderSyncCore.reminderPriority(priority)),
                priority)
        }
        XCTAssertEqual(ReminderSyncCore.priority(fromReminder: 0), .medium)
        XCTAssertEqual(ReminderSyncCore.priority(fromReminder: 3), .high)
        XCTAssertEqual(ReminderSyncCore.priority(fromReminder: 5), .medium)
        XCTAssertEqual(ReminderSyncCore.priority(fromReminder: 7), .low)
    }

    // MARK: - Store contract

    func testUserSavesStampUpdatedAtAndSyncResultsDoNot() async throws {
        let past = Date(timeIntervalSince1970: 1_000)
        let todo = TodoItem(title: "Chase renal panel", updatedAt: past)
        let persisted = try await store.todos.save(todo)
        XCTAssertGreaterThan(persisted.updatedAt, past)
        let afterSaveOpt = try await store.todos.load(id: todo.id)
        let afterSave = try XCTUnwrap(afterSaveOpt)
        XCTAssertEqual(afterSave.updatedAt.timeIntervalSince1970,
                       persisted.updatedAt.timeIntervalSince1970, accuracy: 0.001)

        var synced = afterSave
        synced.updatedAt = past
        synced.reminderIdentifier = "reminder-1"
        synced.reminderListIdentifier = "list-1"
        synced.syncStatus = .synced
        synced.lastSyncDate = Date(timeIntervalSince1970: 2_000)
        try await store.todos.saveSyncResult(synced)
        let afterSyncOpt = try await store.todos.load(id: todo.id)
        let afterSync = try XCTUnwrap(afterSyncOpt)
        XCTAssertEqual(afterSync.updatedAt.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(afterSync.reminderIdentifier, "reminder-1")
        XCTAssertEqual(afterSync.reminderListIdentifier, "list-1")
        XCTAssertEqual(afterSync.syncStatus, .synced)
        XCTAssertEqual(afterSync.lastSyncDate?.timeIntervalSince1970 ?? 0, 2_000, accuracy: 0.001)
    }

    func testToggleIsAUserEditAndStampsUpdatedAt() async throws {
        var todo = TodoItem(title: "Sign discharge summary", updatedAt: Date(timeIntervalSince1970: 1_000))
        todo.syncStatus = .synced
        todo.lastSyncDate = Date(timeIntervalSince1970: 2_000)
        try await store.todos.saveSyncResult(todo)
        try await store.todos.toggle(id: todo.id)
        let toggledOpt = try await store.todos.load(id: todo.id)
        let toggled = try XCTUnwrap(toggledOpt)
        XCTAssertTrue(toggled.isCompleted)
        XCTAssertNotNil(toggled.completedAt)
        let lastSync = try XCTUnwrap(toggled.lastSyncDate)
        XCTAssertGreaterThan(toggled.updatedAt, lastSync,
                             "a toggled row must read as dirty so the bridge pushes it")
    }

    func testSyncResultDropsADanglingPatientLink() async throws {
        var todo = TodoItem(title: "Call about the echo slot")
        todo.patientId = UUID()
        todo.patientName = "Nobody"
        try await store.todos.saveSyncResult(todo)
        let loadedOpt = try await store.todos.load(id: todo.id)
        let loaded = try XCTUnwrap(loadedOpt)
        XCTAssertNil(loaded.patientId)
        XCTAssertNil(loaded.patientName)
    }

    func testUpdatedAtSurvivesAJSONRoundTripAndDefaultsToCreatedAt() throws {
        let created = Date(timeIntervalSince1970: 5_000)
        let todo = TodoItem(title: "T", createdAt: created)
        XCTAssertEqual(todo.updatedAt, created)
        let back = try decodeJSONData(TodoItem.self, from: try encodeJSONData(todo))
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)

        // Legacy JSON (the V1.1 store) never carried the stamp.
        let legacy = Data("""
            {"id":"178C2A48-6051-454B-B789-03440711241B","title":"legacy","createdAt":"2026-03-04T22:39:53Z"}
            """.utf8)
        let decoded = try decodeJSONData(TodoItem.self, from: legacy)
        XCTAssertEqual(decoded.updatedAt, decoded.createdAt)
    }
}
