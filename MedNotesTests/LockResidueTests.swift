import XCTest
@testable import MedNotes

/// What a lock leaves behind. Everything the session shows is cleared when it
/// locks, but two things could outlive it: a quick-switcher lookup already in
/// flight, and a selection made by a task that was waiting on the store.
@MainActor
final class LockResidueTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.LockResidue"
    private var roots: [DataRoot] = []

    override func setUp() {
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDown() {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        session.selectedModule = .notes
        return session
    }

    /// A lookup already running when the lock lands used to put note titles and
    /// patient names back into the results after the lock had emptied them.
    func testASwitcherLookupInFlightDuringALockDoesNotRefillTheResults() async throws {
        let session = try await makeSession()
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Alpha ward patient"
        note.content = "x"
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        session.switcherText = "Alpha"
        // The lock lands after the lookup has read the store and before it publishes.
        session.switcherLookupWillPublish = { [unowned session] in
            session.switcherLookupWillPublish = {}
            await session.lockNow(reason: "idle")
        }

        await session.updateSwitcherResults()

        XCTAssertTrue(session.switcherResults.isEmpty,
                      "results read before the lock must not be shown after it: \(session.switcherResults.map(\.title))")
    }

    /// A new note being saved when the lock lands: its editor must not open under
    /// the curtain, and the untouched row must not be left in the store.
    func testANewNoteBeingSavedWhenTheLockLandsIsNotOpenedAndIsNotLeftBehind() async throws {
        let session = try await makeSession()
        // The lock lands after the note is saved and before it would be opened.
        session.newNoteDidSave = { [unowned session] in
            session.newNoteDidSave = {}
            await session.lockNow(reason: "idle")
        }
        await session.newNote()

        XCTAssertNil(session.selectedNoteId, "no editor may be opened for a session that has locked")
        XCTAssertNil(session.pendingFocusRecordId)

        await session.unlock()
        let store = try XCTUnwrap(session.store, "unlock failed: \(session.initError ?? "")")
        let notes = try await store.notes.loadAll()
        // The title a new note is given, in whatever language the app runs.
        let untouchedTitle = Note.newRecord().title
        XCTAssertTrue(notes.filter { $0.title == untouchedTitle }.isEmpty,
                      "the untouched row was left behind: \(notes.map(\.title))")
    }

    // MARK: - Deleting an event while the session locks

    /// Saves an event, lands a lock after `removeEvent` has read the event and
    /// its destination, deletes it, and returns the session unlocked again.
    private func deleteAnEventWhileTheLockLands(linked: Bool) async throws -> (session: AppSession, id: UUID) {
        let session = try await makeSession()
        session.selectedModule = .calendar
        var event = CalendarEvent(title: "Clinic")
        if linked {
            event.ekEventIdentifier = "apple-identifier"
            event.syncStatus = .synced
            event.lastSyncDate = Date()
        }
        let store = try XCTUnwrap(session.store)
        try await store.events.save(event)
        session.eventRemovalDidLookUpDestination = { [unowned session] in
            session.eventRemovalDidLookUpDestination = {}
            await session.lockNow(reason: "idle")
        }

        await session.deleteEvent(id: event.id)
        return (session, event.id)
    }

    /// A lock that lands while the Apple copy is being looked up must stop the
    /// delete before that copy is touched: past that point the copy would go
    /// while the row, on a store that has closed, stayed with an identifier
    /// that finds nothing. With the Apple account not reachable (as in every
    /// test) the old code failed here with the reconnect message, under the
    /// curtain, and reloaded the lists on the closed store.
    func testALockDuringTheDeleteOfALinkedEventStopsItBeforeTheAppleCopyIsTouched() async throws {
        let (session, id) = try await deleteAnEventWhileTheLockLands(linked: true)

        XCTAssertNil(session.errorMessage, "nothing is reported for a delete that a lock stopped")

        await session.unlock()
        let store = try XCTUnwrap(session.store, "unlock failed: \(session.initError ?? "")")
        let kept = try await store.events.load(id: id)
        XCTAssertEqual(kept?.ekEventIdentifier, "apple-identifier", "the row and its link are as they were")
        XCTAssertNil(session.errorMessage)
    }

    /// The same for a row that was never linked, whose delete then reaches the
    /// store: on a closed store it threw, and the message was shown.
    func testALockDuringTheDeleteOfAnUnlinkedEventStopsItWithoutAMessage() async throws {
        let (session, id) = try await deleteAnEventWhileTheLockLands(linked: false)

        XCTAssertNil(session.errorMessage, "nothing is reported for a delete that a lock stopped")

        await session.unlock()
        let store = try XCTUnwrap(session.store, "unlock failed: \(session.initError ?? "")")
        let kept = try await store.events.load(id: id)
        XCTAssertNotNil(kept, "the delete was stopped by the lock, so the event is still there")
    }

    /// Without a lock the delete still happens, so the guards cannot be what
    /// the two tests above are passing on.
    func testWithoutALockAnUnlinkedEventIsStillDeleted() async throws {
        let session = try await makeSession()
        session.selectedModule = .calendar
        let event = CalendarEvent(title: "Clinic")
        let store = try XCTUnwrap(session.store)
        try await store.events.save(event)

        await session.deleteEvent(id: event.id)

        let gone = try await store.events.load(id: event.id)
        XCTAssertNil(gone)
        XCTAssertNil(session.errorMessage)
    }
}
