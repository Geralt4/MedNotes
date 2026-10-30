import XCTest
@testable import MedNotes

/// An Apple event or reminder that MedNotes made stays in the user's Calendar or
/// Reminders when the row it came from is deleted, if the Apple copy could not be
/// found at the time (a full sync changes identifiers; a push's result may never
/// have been stored). The next pull used to import it as a new row with no
/// patient. A delete now leaves a tombstone, and the pull skips what it names.
///
/// EventKit cannot be faked, so the decisions are pure rules tested here, and the
/// EventKit calls around them stay thin.
final class SyncTombstoneTests: XCTestCase {
    private var roots: [DataRoot] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    private func destination() -> SyncDestination {
        SyncDestination(
            bridgeType: .calendar, calendarIdentifier: "cal-1", calendarTitle: "MedNotes",
            sourceIdentifier: "src-1", sourceTitle: "iCloud", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
    }

    // MARK: - What a pull does with an Apple object that no row holds

    func testAnObjectMadeFromADeletedRowIsNotImported() {
        let kept = UUID(), deleted = UUID(), stranger = UUID()
        let decide = { (record: UUID?) in
            SyncDestinationCore.importDecision(
                recordID: record, localIDs: [kept], tombstones: [deleted])
        }
        XCTAssertEqual(decide(kept), .belongsToLocalRow)
        XCTAssertEqual(decide(deleted), .deletedHere)
        XCTAssertEqual(decide(stranger), .importAsNew, "made from a row this store never had")
        XCTAssertEqual(decide(nil), .importAsNew, "an older marker names no row")
    }

    func testARowThatExistsBeatsATombstoneForTheSameId() {
        // A deleted record that came back (a restore, an import) owns its object again.
        let id = UUID()
        XCTAssertEqual(
            SyncDestinationCore.importDecision(recordID: id, localIDs: [id], tombstones: [id]),
            .belongsToLocalRow)
    }

    // MARK: - Where a push goes

    func testPushRouteTable() {
        let destination = destination()
        let row = UUID()
        let ours = SyncDestinationCore.markerURL(for: destination, record: row)
        let others = SyncDestinationCore.markerURL(for: destination, record: UUID())
        let route = { (found: (inDestination: Bool, marker: String?, recordID: UUID?)?) in
            SyncDestinationCore.pushRoute(rowID: row, destination: destination, found: found)
        }

        XCTAssertEqual(route(nil), .searchDestination, "the identifier finds nothing")
        XCTAssertEqual(
            route((true, SyncDestinationCore.marker(from: ours), SyncDestinationCore.recordID(from: ours))),
            .useFound)
        XCTAssertEqual(
            route((false, SyncDestinationCore.marker(from: ours), SyncDestinationCore.recordID(from: ours))),
            .movedElsewhere, "the object this row made, moved out of the destination: no second one")
        XCTAssertEqual(
            route((false, SyncDestinationCore.marker(from: others), SyncDestinationCore.recordID(from: others))),
            .searchDestination, "another row's object is not this row's to protect")
        XCTAssertEqual(
            route((false, nil, nil)), .searchDestination,
            "an object MedNotes did not make in a calendar it does not own")
    }

    // MARK: - The pass report

    func testTheReportSaysWhatWasLeftBecauseItWasDeletedHere() {
        var report = SyncPassReport()
        XCTAssertEqual(report.summary, String(localized: "Nothing to sync"))
        report.ignoredDeleted = 2
        XCTAssertTrue(report.summary.contains("2"), report.summary)
    }

    // MARK: - Tombstones in the store

    func testDeletingAnEventOrTodoLeavesATombstoneEvenIfItNeverSynced() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        let event = CalendarEvent(title: "Clinic")
        let todo = TodoItem(title: "Call")
        _ = try await store.events.save(event)
        _ = try await store.todos.save(todo)

        try await store.events.delete(id: event.id)
        try await store.todos.delete(id: todo.id)

        let events = try await store.db.syncTombstones(domain: SyncDestinationCore.calendarDomain)
        let todos = try await store.db.syncTombstones(domain: SyncDestinationCore.remindersDomain)
        XCTAssertEqual(events, [event.id], "a push whose result was never stored leaves no sign on the row")
        XCTAssertEqual(todos, [todo.id])
        XCTAssertFalse(events.contains(todo.id), "the domains are kept apart")
        await store.close()
    }

    func testDiscardingAnUntouchedNewRecordAlsoLeavesATombstone() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        let event = CalendarEvent.newRecord()
        _ = try await store.events.save(event)
        try await store.events.discard(id: event.id)
        let tombstones = try await store.db.syncTombstones(domain: SyncDestinationCore.calendarDomain)
        XCTAssertEqual(tombstones, [event.id], "it may have been pushed before it was discarded")
        await store.close()
    }

    func testTheTombstoneAndTheDeleteAreOneChange() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        let event = CalendarEvent.newRecord()
        _ = try await store.events.save(event)
        try await store.db.deleteEvent(id: event.id)
        let events = try await store.events.loadAll()
        let tombstones = try await store.db.syncTombstones(domain: SyncDestinationCore.calendarDomain)
        XCTAssertTrue(events.isEmpty, "the row is gone")
        XCTAssertEqual(tombstones, [event.id], "and its tombstone was written with it")
        // Nothing to delete: nothing breaks, and no event appears.
        try await store.db.deleteEvent(id: UUID())
        let after = try await store.events.loadAll()
        XCTAssertTrue(after.isEmpty)
        await store.close()
    }

    // MARK: - The migration

    private func rows(_ root: DataRoot, _ sql: String) throws -> [String] {
        let conn = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        let s = try conn.prepare(sql)
        defer { s.finalize() }
        var out: [String] = []
        while try s.step() { out.append(s.columnText(0) ?? "∅") }
        return out
    }

    private func exec(_ root: DataRoot, _ statements: [String]) throws {
        let conn = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        for statement in statements { try conn.exec(statement) }
    }

    func testANewStoreHasTheTombstoneTableAndItsMarker() async throws {
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 9)
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(
            try rows(root, "SELECT version FROM migrations WHERE version = '9.0-sync-tombstones'"),
            ["9.0-sync-tombstones"])
        XCTAssertEqual(
            try rows(root, "SELECT name FROM sqlite_master WHERE name = 'sync_tombstones'"),
            ["sync_tombstones"])
        await store.close()
    }

    /// A version-8 store (no table, no marker) opens, gains the table, and keeps
    /// what it had.
    func testAVersionEightStoreGainsTheTableOnOpen() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Kept", content: "text"))
        await store.close()
        try exec(root, ["DROP TABLE sync_tombstones", "DELETE FROM migrations WHERE version = '9.0-sync-tombstones'"])

        let upgraded = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(
            try rows(root, "SELECT version FROM migrations WHERE version = '9.0-sync-tombstones'"),
            ["9.0-sync-tombstones"])
        let event = CalendarEvent(title: "Clinic")
        _ = try await upgraded.events.save(event)
        try await upgraded.events.delete(id: event.id)
        let tombstones = try await upgraded.db.syncTombstones(domain: SyncDestinationCore.calendarDomain)
        XCTAssertEqual(tombstones, [event.id])
        let notes = try await upgraded.notes.loadAll()
        XCTAssertEqual(notes.map(\.title), ["Kept"])
        await upgraded.close()
    }

    /// Tombstones travel with the store, so a restore brings back the deletions
    /// that were recorded when the backup was made, and nothing it should not.
    func testTombstonesAreCarriedByABackup() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let event = CalendarEvent(title: "Clinic")
        _ = try await store.events.save(event)
        try await store.events.delete(id: event.id)
        let archive = root.rootURL.appendingPathComponent("tombstones.mednotesbackup")
        let passphrase = "a long enough passphrase"
        _ = try await store.backups.createEncryptedBackup(name: "t", to: archive, passphrase: passphrase)

        let other = try makeRoot()
        let target = try AppStore.testStore(dataRoot: other)
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: other),
            attachmentKey: TestKeys.attachment(for: other), createRestorePoint: false)

        let restored = try await target.db.syncTombstones(domain: SyncDestinationCore.calendarDomain)
        XCTAssertEqual(restored, [event.id])
        await store.close()
        await target.close()
    }
}
