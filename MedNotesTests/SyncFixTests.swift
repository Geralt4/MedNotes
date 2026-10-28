import XCTest
@testable import MedNotes

/// What a sync pass may overwrite, how an Apple object is recognised again,
/// and how passes are kept from overlapping. All of it is decided by pure
/// rules and small values, so none of it needs EventKit or an account.
final class SyncFixTests: XCTestCase {
    private var roots: [DataRoot] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private let lastSync = Date(timeIntervalSince1970: 1_000_000)

    private func destination() -> SyncDestination {
        SyncDestination(
            bridgeType: .calendar, calendarIdentifier: "cal-1", calendarTitle: "MedNotes",
            sourceIdentifier: "src-1", sourceTitle: "iCloud", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
    }

    // MARK: - Is the Apple copy newer?

    func testToleranceMeansOnlyAClearlyLaterEditCounts() {
        XCTAssertFalse(SyncDestinationCore.remoteChangedSinceSync(lastSync: lastSync, remoteModified: nil))
        XCTAssertFalse(SyncDestinationCore.remoteChangedSinceSync(lastSync: nil, remoteModified: lastSync))
        XCTAssertFalse(SyncDestinationCore.remoteChangedSinceSync(
            lastSync: lastSync, remoteModified: lastSync.addingTimeInterval(-500)))
        XCTAssertFalse(SyncDestinationCore.remoteChangedSinceSync(
            lastSync: lastSync, remoteModified: lastSync.addingTimeInterval(5)),
            "a server stamping our own push a moment after we saved it is not someone else's edit")
        XCTAssertFalse(SyncDestinationCore.remoteChangedSinceSync(
            lastSync: lastSync,
            remoteModified: lastSync.addingTimeInterval(SyncDestinationCore.remoteChangeTolerance)))
        XCTAssertTrue(SyncDestinationCore.remoteChangedSinceSync(
            lastSync: lastSync,
            remoteModified: lastSync.addingTimeInterval(SyncDestinationCore.remoteChangeTolerance + 1)))
    }

    // MARK: - Calendar: may this row be pushed?

    private func dirtyEvent() -> CalendarEvent {
        var event = CalendarEvent(title: "Clinic", updatedAt: lastSync.addingTimeInterval(30))
        event.syncStatus = .synced
        event.ekEventIdentifier = "ek-1"
        event.lastSyncDate = lastSync
        return event
    }

    func testCalendarPushDecisionTable() {
        let local = dirtyEvent()
        var edited = CalendarSyncCore.fields(of: local)
        edited.title = "Edited in Calendar"
        let later = lastSync.addingTimeInterval(SyncDestinationCore.remoteChangeTolerance + 30)

        XCTAssertEqual(CalendarSyncCore.pushDecision(
            local: local, remote: CalendarSyncCore.fields(of: local), remoteModified: later), .unchanged,
            "the Apple copy already holds the row: nothing to write, whatever its date")
        XCTAssertEqual(CalendarSyncCore.pushDecision(
            local: local, remote: edited, remoteModified: later), .remoteNewer,
            "edited in Calendar after the last sync, and different: do not overwrite it")
        XCTAssertEqual(CalendarSyncCore.pushDecision(
            local: local, remote: edited, remoteModified: lastSync.addingTimeInterval(3)), .push,
            "the Apple copy is the one we last wrote: our own edit goes over it")
        XCTAssertEqual(CalendarSyncCore.pushDecision(
            local: local, remote: edited, remoteModified: nil), .push,
            "no evidence the Apple copy changed")
    }

    func testARowNeverSyncedOrLocalOnlyIsPushedWhateverTheAppleCopySays() {
        var never = dirtyEvent()
        never.lastSyncDate = nil
        var edited = CalendarSyncCore.fields(of: never)
        edited.title = "Different"
        let much = lastSync.addingTimeInterval(86_400)
        XCTAssertEqual(CalendarSyncCore.pushDecision(local: never, remote: edited, remoteModified: much), .push)

        var localOnly = dirtyEvent()
        localOnly.syncStatus = .localOnly
        XCTAssertEqual(CalendarSyncCore.pushDecision(local: localOnly, remote: edited, remoteModified: much), .push)
    }

    // MARK: - Reminders: may this todo be pushed?

    private func dirtyTodo() -> TodoItem {
        var todo = TodoItem(title: "Chase labs", updatedAt: lastSync.addingTimeInterval(30))
        todo.syncStatus = .synced
        todo.reminderIdentifier = "rem-1"
        todo.lastSyncDate = lastSync
        return todo
    }

    func testRemindersPushDecisionTable() {
        let local = dirtyTodo()
        var edited = ReminderSyncCore.fields(of: local)
        edited.title = "Edited in Reminders"
        let later = lastSync.addingTimeInterval(SyncDestinationCore.remoteChangeTolerance + 30)

        XCTAssertEqual(ReminderSyncCore.pushDecision(
            local: local, remote: ReminderSyncCore.fields(of: local), remoteModified: later), .unchanged)
        XCTAssertEqual(ReminderSyncCore.pushDecision(
            local: local, remote: edited, remoteModified: later), .remoteNewer)
        XCTAssertEqual(ReminderSyncCore.pushDecision(
            local: local, remote: edited, remoteModified: lastSync.addingTimeInterval(3)), .push)
        XCTAssertEqual(ReminderSyncCore.pushDecision(
            local: local, remote: edited, remoteModified: nil), .push)
    }

    func testATimeOfDayOnTheDueDateIsNotARemoteEdit() {
        var local = dirtyTodo()
        local.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 8))
        // The reminder holds the same day, with no time of day.
        let remote = ReminderFields(
            title: local.title, notes: "", dueDay: DueDay(year: 2026, month: 9, day: 11),
            isCompleted: false, priority: local.priority)
        let later = lastSync.addingTimeInterval(SyncDestinationCore.remoteChangeTolerance + 30)
        XCTAssertEqual(ReminderSyncCore.pushDecision(local: local, remote: remote, remoteModified: later), .unchanged)
    }

    // MARK: - Markers

    func testAMarkerNamesTheDestinationAndTheRowItWasMadeFrom() throws {
        let destination = destination()
        let row = UUID()

        let withRecord = SyncDestinationCore.markerURL(for: destination, record: row)
        XCTAssertEqual(SyncDestinationCore.marker(from: withRecord), destination.id.uuidString)
        XCTAssertEqual(SyncDestinationCore.recordID(from: withRecord), row)
        XCTAssertTrue(SyncDestinationCore.ownsRemoteObject(
            marker: SyncDestinationCore.marker(from: withRecord), destination: destination, inDestination: true))

        // The shape every earlier build wrote: the destination alone.
        let legacy = SyncDestinationCore.markerURL(for: destination)
        XCTAssertEqual(SyncDestinationCore.marker(from: legacy), destination.id.uuidString)
        XCTAssertNil(SyncDestinationCore.recordID(from: legacy))
        XCTAssertTrue(SyncDestinationCore.ownsRemoteObject(
            marker: SyncDestinationCore.marker(from: legacy), destination: destination, inDestination: true),
            "objects made before the record id existed are still MedNotes-owned")
    }

    func testAMarkerFromAnotherDestinationOrApplicationIsNotOwned() throws {
        let destination = destination()
        let other = SyncDestination(
            bridgeType: .calendar, calendarIdentifier: "cal-2", calendarTitle: "Other",
            sourceIdentifier: "src-1", sourceTitle: "iCloud", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
        let foreign = SyncDestinationCore.markerURL(for: other, record: UUID())
        XCTAssertFalse(SyncDestinationCore.ownsRemoteObject(
            marker: SyncDestinationCore.marker(from: foreign), destination: destination, inDestination: true))

        let web = try XCTUnwrap(URL(string: "https://example.com/object/\(destination.id.uuidString)/\(UUID().uuidString)"))
        XCTAssertNil(SyncDestinationCore.marker(from: web))
        XCTAssertNil(SyncDestinationCore.recordID(from: web))
        XCTAssertNil(SyncDestinationCore.recordID(from: nil))
        let junk = try XCTUnwrap(URL(string: "x-mednotes://object/\(destination.id.uuidString)/not-a-uuid"))
        XCTAssertNil(SyncDestinationCore.recordID(from: junk))
        XCTAssertEqual(SyncDestinationCore.marker(from: junk), destination.id.uuidString)
    }

    // MARK: - One pass at a time

    func testASecondRequestDuringAPassBecomesOneRerun() {
        var gate = SyncPassGate()
        XCTAssertTrue(gate.enter(automatic: true))
        XCTAssertTrue(gate.isRunning)

        XCTAssertFalse(gate.enter(automatic: true), "refused while a pass runs")
        XCTAssertFalse(gate.enter(automatic: true), "and a third does not make a second rerun")
        XCTAssertEqual(gate.finish(), true, "one more automatic pass")
        XCTAssertNil(gate.finish(), "and then the gate is idle")
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.enter(automatic: true), "a later request starts a pass again")
    }

    func testAManualRequestDuringAPassMakesTheRerunManual() {
        var gate = SyncPassGate()
        XCTAssertTrue(gate.enter(automatic: true))
        XCTAssertFalse(gate.enter(automatic: true))
        XCTAssertFalse(gate.enter(automatic: false), "Sync Now pressed meanwhile")
        XCTAssertEqual(gate.finish(), false, "the rerun may open the destination wizard")
        XCTAssertNil(gate.finish())
    }

    func testARequestWhileIdleLeavesNoRerunBehind() {
        var gate = SyncPassGate()
        XCTAssertTrue(gate.enter(automatic: false))
        XCTAssertNil(gate.finish())
        XCTAssertTrue(gate.enter(automatic: true))
        XCTAssertNil(gate.finish())
    }

    // MARK: - A row pointed at the object it made

    func testPointingARowAtItsObjectChangesTheIdentifierAndNothingElse() async throws {
        let root = try DataRoot.temporary()
        roots.append(root)
        let store = try AppStore.testStore(dataRoot: root)

        var event = CalendarEvent(title: "Clinic")
        event.ekEventIdentifier = "stale-id"
        event.syncStatus = .synced
        event.lastSyncDate = Date(timeIntervalSince1970: 5_000)
        try await store.events.save(event)
        // Compared as the database holds them: the saved value in memory has
        // finer time precision than the stored one.
        let storedBefore = try await store.events.load(id: event.id)
        let beforeEvent = try XCTUnwrap(storedBefore)
        try await store.events.setRemoteIdentifier(id: event.id, identifier: "fresh-id")
        let loadedEvent = try await store.events.load(id: event.id)
        let reloadedEvent = try XCTUnwrap(loadedEvent)
        XCTAssertEqual(reloadedEvent.ekEventIdentifier, "fresh-id")
        XCTAssertEqual(reloadedEvent.title, "Clinic")
        XCTAssertEqual(reloadedEvent.updatedAt, beforeEvent.updatedAt, "still as dirty or clean as it was")
        XCTAssertEqual(reloadedEvent.lastSyncDate, Date(timeIntervalSince1970: 5_000))

        var todo = TodoItem(title: "Chase labs")
        todo.reminderIdentifier = "stale-reminder"
        todo.syncStatus = .synced
        try await store.todos.save(todo)
        let todoBefore = try await store.todos.load(id: todo.id)
        let beforeTodo = try XCTUnwrap(todoBefore)
        try await store.todos.setRemoteIdentifier(id: todo.id, identifier: "fresh-reminder")
        let loadedTodo = try await store.todos.load(id: todo.id)
        let reloadedTodo = try XCTUnwrap(loadedTodo)
        XCTAssertEqual(reloadedTodo.reminderIdentifier, "fresh-reminder")
        XCTAssertEqual(reloadedTodo.title, "Chase labs")
        XCTAssertEqual(reloadedTodo.updatedAt, beforeTodo.updatedAt)
    }
}
