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

}
