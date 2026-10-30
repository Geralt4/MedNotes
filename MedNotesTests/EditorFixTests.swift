import XCTest
@testable import MedNotes

/// The record editors and the small rules behind them: what a checkbox
/// writes, which fields a stale copy must not overwrite, how a title or an
/// AMKA is stored, and which store Settings reports.
@MainActor
final class EditorFixTests: XCTestCase {
    private var roots: [DataRoot] = []
    private static let defaultsName = "MedNotesTests.EditorFix"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDownWithError() throws {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    // MARK: - A load that was superseded

    func testOnlyTheNewestLoadMayClearTheSpinner() {
        var loads = LoadGeneration()
        let first = loads.begin()
        XCTAssertTrue(loads.isCurrent(first))
        let second = loads.begin()
        XCTAssertFalse(loads.isCurrent(first), "the cancelled load that ends late must not clear it")
        XCTAssertTrue(loads.isCurrent(second))
        // A → B → A: the third load is the one that counts, whatever the first said.
        let third = loads.begin()
        XCTAssertFalse(loads.isCurrent(second))
        XCTAssertFalse(loads.isCurrent(first))
        XCTAssertTrue(loads.isCurrent(third))
    }

    // MARK: - The checkbox

    func testTheCheckboxWritesCompletionAndNothingElse() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        var todo = TodoItem(title: "Review labs")
        todo.notes = "NOTES-STAY"
        todo.priority = .high
        todo.tags = ["ward"]
        todo.reminderIdentifier = "reminder-1"
        todo.syncStatus = .synced
        try await store.todos.save(todo)

        try await store.todos.setCompleted(id: todo.id, completed: true)
        var found = try await store.todos.load(id: todo.id)
        var loaded = try XCTUnwrap(found)
        XCTAssertTrue(loaded.isCompleted)
        let stamp = try XCTUnwrap(loaded.completedAt)
        XCTAssertEqual(loaded.title, "Review labs")
        XCTAssertEqual(loaded.notes, "NOTES-STAY")
        XCTAssertEqual(loaded.priority, .high)
        XCTAssertEqual(loaded.tags, ["ward"])
        XCTAssertEqual(loaded.reminderIdentifier, "reminder-1", "the link to the synced reminder is untouched")

        // Stating the same value again keeps the completion stamp.
        try await store.todos.setCompleted(id: todo.id, completed: true)
        found = try await store.todos.load(id: todo.id)
        loaded = try XCTUnwrap(found)
        XCTAssertEqual(loaded.completedAt, stamp)

        try await store.todos.setCompleted(id: todo.id, completed: false)
        found = try await store.todos.load(id: todo.id)
        loaded = try XCTUnwrap(found)
        XCTAssertFalse(loaded.isCompleted)
        XCTAssertNil(loaded.completedAt)
        XCTAssertEqual(loaded.notes, "NOTES-STAY")
    }

    // MARK: - A copy read before the bridge ran

    func testAStaleTodoTakesOnlyTheBridgesFieldsFromTheStore() {
        var stale = TodoItem(title: "Edited locally")
        var stored = TodoItem(id: stale.id, title: "Title in the store")
        stored.reminderIdentifier = "reminder-9"
        stored.reminderListIdentifier = "list-3"
        stored.syncStatus = .synced
        stored.lastSyncDate = Date(timeIntervalSince1970: 5_000)

        stale.adoptSyncState(from: stored)
        XCTAssertEqual(stale.title, "Edited locally", "the user's edit stays")
        XCTAssertEqual(stale.reminderIdentifier, "reminder-9")
        XCTAssertEqual(stale.reminderListIdentifier, "list-3")
        XCTAssertEqual(stale.syncStatus, .synced)
        XCTAssertEqual(stale.lastSyncDate, Date(timeIntervalSince1970: 5_000))
    }

    func testAStaleEventTakesOnlyTheBridgesFieldsFromTheStore() {
        var stale = CalendarEvent(title: "Edited locally")
        var stored = CalendarEvent(id: stale.id, title: "Title in the store")
        stored.ekEventIdentifier = "event-7"
        stored.syncStatus = .synced
        stored.lastSyncDate = Date(timeIntervalSince1970: 9_000)

        stale.adoptSyncState(from: stored)
        XCTAssertEqual(stale.title, "Edited locally")
        XCTAssertEqual(stale.ekEventIdentifier, "event-7")
        XCTAssertEqual(stale.syncStatus, .synced)
        XCTAssertEqual(stale.lastSyncDate, Date(timeIntervalSince1970: 9_000))
    }

    // MARK: - AMKA

    func testAnAmkaIsStoredWithoutTheSpacesAndDashesPeopleType() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        var first = Patient.newRecord()
        first.profile.firstName = "Spaced"
        first.profile.lastName = "Amka"
        first.profile.amka = "123 4567-8901"
        try await store.patients.save(first)
        let found = try await store.db.loadPatient(id: first.id)
        XCTAssertEqual(try XCTUnwrap(found).profile.amka, "12345678901")

        // The same number typed another way is a duplicate the index now sees.
        var second = Patient.newRecord()
        second.profile.firstName = "Plain"
        second.profile.lastName = "Amka"
        second.profile.amka = "12345678901"
        do {
            try await store.patients.save(second)
            XCTFail("the same AMKA must not be accepted twice")
        } catch {
            // Expected: the unique index refuses it.
        }
    }

    // MARK: - Titles Apple gives back

    func testThePlaceholderTitleComesBackAsNoTitle() {
        XCTAssertEqual(SyncDestinationCore.titleFromRemote("(untitled)"), "")
        XCTAssertEqual(SyncDestinationCore.titleFromRemote(String(localized: "(untitled)")), "")
        XCTAssertEqual(SyncDestinationCore.titleFromRemote(nil), "")
        XCTAssertEqual(SyncDestinationCore.titleFromRemote("Ward round"), "Ward round")
        XCTAssertEqual(SyncDestinationCore.titleFromRemote("(untitled) round"), "(untitled) round",
                       "only the whole placeholder counts")
    }

    func testAnEmptyTitleSurvivesAPushAndAPull() {
        let pushed = SyncDestinationCore.titleForRemote("")
        XCTAssertFalse(pushed.isEmpty, "Apple wants a title")
        XCTAssertEqual(SyncDestinationCore.titleFromRemote(pushed), "", "and it comes back as none")
        XCTAssertEqual(SyncDestinationCore.titleForRemote("Real"), "Real")
    }

    // MARK: - Notes from the old mirror

    func testANoteThatStartsWithBlankLinesKeepsThem() throws {
        for body in ["\n\nStarts with two blank lines", "Starts with text", "\nOne blank line", ""] {
            let note = Note(title: "Blank lines", content: body)
            let decoded = try XCTUnwrap(MarkdownVaultDecoder.decode(MarkdownExportService.encode(note: note)))
            XCTAssertEqual(decoded.content, body, "round trip of \(body.debugDescription)")
        }
    }

    // MARK: - Which store Settings reports

    func testSettingsDoesNotCallAnEncryptedStorePlaintextBeforeItIsReady() async throws {
        let root = try makeRoot()
        let session = AppSession(
            dataRoot: root, defaults: defaults,
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        XCTAssertFalse(session.storeIsPlaintext, "not claimed before bootstrap has looked")
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.storeIsPlaintext)
        await session.lockNow(reason: "test")
        XCTAssertFalse(session.storeIsPlaintext, "a locked store is still an encrypted one")
    }

    /// A plaintext store in a session that has reached the encryption wizard.
    private func sessionAtTheWizard() async throws -> (AppSession, DataRoot) {
        let root = try DataRoot.temporary()
        roots.append(root)
        let plaintext = try Database(path: root.databaseURL.path)
        try await plaintext.saveNote(Note(title: "old", content: "plaintext era"))
        await plaintext.close()
        let session = AppSession(dataRoot: root, defaults: defaults, keyManager: InMemoryKeyManager())
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isMigrating, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isMigrating, "precondition: the wizard owns the screen")
        return (session, root)
    }

    func testTheEncryptionWizardCanBeOpenedAgainAfterCancelling() async throws {
        let (session, root) = try await sessionAtTheWizard()
        XCTAssertFalse(session.canRetryMigration)

        session.cancelMigration()

        XCTAssertFalse(session.isMigrating)
        XCTAssertTrue(session.canRetryMigration)
        XCTAssertNotNil(session.initError, "the screen says what happened")
        XCTAssertTrue(SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL))

        session.returnToMigration()

        XCTAssertTrue(session.isMigrating)
        XCTAssertNil(session.initError)
        XCTAssertFalse(session.canRetryMigration)
        session.returnToMigration()
        XCTAssertTrue(session.isMigrating, "there is nothing to return to twice")
    }

    func testAMigrationThatFailsBeforeChangingAnythingCanBeTriedAgain() async throws {
        let (session, root) = try await sessionAtTheWizard()
        let missing = root.rootURL.appendingPathComponent("never-written.mednotesbackup")

        do {
            try await session.runMigration(backupURL: missing, passphrase: "a long enough passphrase")
            XCTFail("a backup that does not exist cannot start the migration")
        } catch {}

        XCTAssertFalse(session.isMigrating)
        XCTAssertTrue(session.canRetryMigration)
        XCTAssertNotNil(session.initError)
        XCTAssertTrue(SQLiteHeaderInspection.isPlaintextSQLite(at: root.databaseURL),
                      "the original store is as it was")

        session.returnToMigration()
        XCTAssertTrue(session.isMigrating)
        XCTAssertNil(session.initError)
    }

    func testSettingsReportsAPlaintextStoreUntilItIsConverted() async throws {
        let root = try makeRoot()
        let plaintext = try Database(path: root.databaseURL.path)
        try await plaintext.saveNote(Note(title: "old", content: "plaintext era"))
        await plaintext.close()
        let session = AppSession(dataRoot: root, defaults: defaults, keyManager: InMemoryKeyManager())
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isMigrating, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isMigrating, "precondition: the wizard owns the screen")
        XCTAssertTrue(session.storeIsPlaintext)
    }
}
