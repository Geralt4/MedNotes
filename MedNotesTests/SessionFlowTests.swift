import XCTest
@testable import MedNotes

/// The flows that were verified by driving the seeded app, now as tests:
/// creation and discard, the one-shot focus request, archive and restore,
/// and the restore point before a legacy import. Each test gets a session
/// over its own temporary root; Application Support is never touched.
@MainActor
final class SessionFlowTests: XCTestCase {
    private var roots: [DataRoot] = []
    /// The sessions' preferences: never the host's own, which are the
    /// owner's. One fixed suite, emptied around every test. See `TestDefaults`.
    private static let defaultsName = "MedNotesTests.SessionFlow"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots = []
        TestDefaults.clear(Self.defaultsName)
    }

    /// The session reloads its lists from `didSet` observers on its own
    /// schedule, the way the UI sees them; tests wait for the outcome.
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    func testNewPatientIsSelectedAndAsksForFocusOnce() async throws {
        let session = try await makeSession()
        await session.newPatient()
        let id = try XCTUnwrap(session.selectedPatientId)
        XCTAssertTrue(session.consumeFocusRequest(for: id))
        XCTAssertFalse(session.consumeFocusRequest(for: id), "the request is one-shot")
        XCTAssertEqual(session.patients.count, 1)
    }

    /// "+" in the Archived list creates an active patient. The list has to
    /// follow it there; otherwise the just-created record is selected but its
    /// row is in the other filter.
    func testNewPatientSwitchesFromArchivedToActive() async throws {
        let session = try await makeSession()
        session.patientFilter = .archived
        await session.newPatient()
        XCTAssertEqual(session.patientFilter, .active)
        let id = try XCTUnwrap(session.selectedPatientId)
        try await waitUntil("the active list shows the new patient") {
            session.patients.contains { $0.id == id }
        }
    }

    func testUntouchedNewPatientIsDiscardedOnLeave() async throws {
        let session = try await makeSession()
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        let patient = try XCTUnwrap(loaded)
        XCTAssertTrue(patient.isUntouchedNewRecord)
        session.selectPatient(nil)
        await session.discardIfUntouched(patient)
        let exists = await session.patientExists(id: patient.id)
        XCTAssertEqual(exists, false)
        XCTAssertTrue(session.patients.isEmpty)
        XCTAssertEqual(session.sidebarCount(for: .patients), 0)
    }

    func testEditedNewPatientIsKept() async throws {
        let session = try await makeSession()
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        var patient = try XCTUnwrap(loaded)
        patient.profile.firstName = "Μαρία"
        let saved = await session.save(patient)
        XCTAssertTrue(saved)
        await session.discardIfUntouched(patient)
        let exists = await session.patientExists(id: patient.id)
        XCTAssertEqual(exists, true)
        XCTAssertEqual(session.patients.first?.profile.firstName, "Μαρία")
    }

    func testArchiveMovesThePatientBetweenLists() async throws {
        let session = try await makeSession()
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        var patient = try XCTUnwrap(loaded)
        patient.profile.firstName = "Ελένη"
        let saved = await session.save(patient)
        XCTAssertTrue(saved)

        await session.archivePatient(id: patient.id)
        XCTAssertNil(session.selectedPatientId, "an archived patient leaves the active selection")
        XCTAssertFalse(session.patients.contains { $0.id == patient.id })
        XCTAssertFalse(session.assignablePatients.contains { $0.id == patient.id })
        XCTAssertEqual(session.sidebarCount(for: .patients), 0)

        session.patientFilter = .archived
        try await waitUntil("archived list shows the patient") {
            session.patients.contains { $0.id == patient.id }
        }

        session.selectPatient(patient.id)
        await session.unarchivePatient(id: patient.id)
        XCTAssertEqual(session.patientFilter, .active, "restoring follows the record back")
        XCTAssertEqual(session.selectedPatientId, patient.id)
        try await waitUntil("active list shows the patient again") {
            session.patients.contains { $0.id == patient.id }
        }
        XCTAssertEqual(session.sidebarCount(for: .patients), 1)
    }

    /// Edit › Delete asks about the main window's selection. With a sheet, an
    /// alert, the switcher or the curtain over that window, the confirmation
    /// would queue behind it or ask about a record nobody can see.
    func testDeleteIsRequestedOnlyWhileNothingCoversTheWindow() async throws {
        let session = try await makeSession()
        session.selectedModule = .notes
        XCTAssertFalse(session.canRequestDelete, "nothing is selected")
        await session.newNote()
        XCTAssertTrue(session.canRequestDelete)

        let covers: [(name: String, raise: (AppSession) -> Void, lower: (AppSession) -> Void)] = [
            ("backup sheet", { $0.backupFlow = .backUp }, { $0.backupFlow = nil }),
            ("import sheet", { $0.importFlow = .init(folderURL: URL(fileURLWithPath: "/nonexistent")) },
             { $0.importFlow = nil }),
            ("destination sheet", { $0.destinationFlow = Self.destinationFlow() }, { $0.destinationFlow = nil }),
            ("error alert", { $0.errorMessage = "Disk full" }, { $0.dismissError() }),
            ("notice alert", { $0.notice = "Backed up" }, { $0.notice = nil }),
            ("quick switcher", { $0.showSwitcher = true }, { $0.showSwitcher = false }),
            ("privacy curtain", { $0.appDidResignActive() }, { $0.appDidBecomeActive() })
        ]
        for cover in covers {
            cover.raise(session)
            XCTAssertFalse(session.canRequestDelete, "offered under the \(cover.name)")
            session.requestDelete()
            XCTAssertFalse(session.confirmDelete, "a confirmation was queued behind the \(cover.name)")
            cover.lower(session)
            XCTAssertTrue(session.canRequestDelete, "still refused after the \(cover.name) closed")
        }
    }

    /// A second ⌘⌫ while the confirmation is up must not retarget it: the
    /// dialog deletes what it first described.
    func testDeleteRequestedTwiceKeepsTheFirstTarget() async throws {
        let session = try await makeSession()
        session.selectedModule = .notes
        await session.newNote()
        session.requestDelete()
        XCTAssertTrue(session.confirmDelete)
        XCTAssertFalse(session.canRequestDelete, "the confirmation is already up")

        await session.newPatient()
        session.selectedModule = .patients
        XCTAssertNotNil(session.selectedPatientId)
        session.requestDelete()
        XCTAssertEqual(session.pendingDeleteTitle, AppModule.notes.deleteConfirmTitle,
                       "the dialog now asks about \(session.pendingDeleteTitle)")
    }

    private static func destinationFlow() -> AppSession.DestinationFlow {
        AppSession.DestinationFlow(bridge: .calendar, wizard: SyncDestinationWizard(
            bridge: .calendar, sources: [], existing: [], recordSummary: "", transmittedFields: [],
            createInSource: { _ in throw CancellationError() },
            confirm: { _ in throw CancellationError() },
            onCancel: {}))
    }

    func testEveryCreatorRequestsFocusForItsRecord() async throws {
        let session = try await makeSession()
        await session.newTodo()
        let todoId = try XCTUnwrap(session.selectedTodoId)
        XCTAssertTrue(session.consumeFocusRequest(for: todoId))
        await session.newEvent()
        let eventId = try XCTUnwrap(session.selectedEventId)
        XCTAssertTrue(session.consumeFocusRequest(for: eventId))
        XCTAssertFalse(session.consumeFocusRequest(for: todoId), "a newer creation replaces the request")
        await session.newNote()
        let noteId = try XCTUnwrap(session.selectedNoteId)
        XCTAssertTrue(session.consumeFocusRequest(for: noteId))
    }

    /// The editor's `[[` completions come from the store, not from the list
    /// column's current, possibly filtered, load — and rank titles first.
    func testLinkCandidatesSearchTheWholeStoreNotTheFilteredList() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let now = Date()
        let renal = Note(title: "Renal panel", content: "Repeat if hypertension persists.",
                         createdAt: now.addingTimeInterval(-30), updatedAt: now.addingTimeInterval(-30))
        let protocolNote = Note(title: "Hypertension protocol", content: "Targets and titration.",
                                createdAt: now.addingTimeInterval(-20), updatedAt: now.addingTimeInterval(-20))
        let greek = Note(title: "Υπέρταση — παρακολούθηση", content: "",
                         createdAt: now.addingTimeInterval(-10), updatedAt: now.addingTimeInterval(-10))
        // The service stamps `updatedAt` with the clock at millisecond
        // precision; two saves inside one millisecond tie, and SQLite orders
        // ties as it pleases. A pause between saves keeps "most recent" real.
        for note in [renal, protocolNote, greek] {
            try await store.notes.save(note)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        var patient = try XCTUnwrap(loaded)
        patient.profile.firstName = "Hypatia"
        patient.profile.lastName = "Karras"
        let saved = await session.save(patient)
        XCTAssertTrue(saved)

        session.searchText = "zzz-nothing-matches"
        try await waitUntil("the list column is filtered to nothing") { session.notes.isEmpty }

        let hits = await session.linkCandidates(anchor: "Hyp", excluding: nil)
        XCTAssertEqual(Array(hits.prefix(2).map(\.title)), ["Hypertension protocol", "Renal panel"],
                       "title match first, body match second; got \(hits.map(\.title))")
        XCTAssertTrue(hits.contains { $0.kind == .patient && $0.title.contains("Hypatia") }, "got \(hits)")

        let excluded = await session.linkCandidates(anchor: "Hyp", excluding: protocolNote.id)
        XCTAssertFalse(excluded.contains { $0.id == protocolNote.id }, "never the note being edited")

        let tooShort = await session.linkCandidates(anchor: "H", excluding: nil)
        XCTAssertTrue(tooShort.isEmpty, "one character is too little to ask")

        let recent = await session.linkCandidates(anchor: "", excluding: nil)
        XCTAssertEqual(recent.map(\.title), ["Υπέρταση — παρακολούθηση", "Hypertension protocol", "Renal panel"],
                       "an empty anchor offers the notes touched most recently")

        let greekHits = await session.linkCandidates(anchor: "Υπέρ", excluding: nil)
        XCTAssertEqual(greekHits.first?.title, "Υπέρταση — παρακολούθηση", "got \(greekHits)")
    }

    /// An unresolved link in the panel creates the note it names; the save
    /// resolves the link that asked for it.
    func testCreatingANoteFromAnUnresolvedLinkOpensItAndResolvesTheLink() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let source = Note(title: "Round", content: "see [[Insulin protocol]] and ![[scan.png]]")
        try await store.notes.save(source)
        await session.refreshLinks(noteId: source.id)
        let open = try XCTUnwrap(session.linksOut.first)
        XCTAssertEqual(open.kind, .unresolved)
        XCTAssertTrue(open.canCreateNote)
        XCTAssertEqual(session.linksOut.last?.canCreateNote, false)

        await session.createNoteFromLink(open.target)
        let created = try XCTUnwrap(session.selectedNoteId)
        XCTAssertNotEqual(created, source.id)
        let createdNote = try await store.notes.load(id: created)
        XCTAssertEqual(createdNote?.title, "Insulin protocol")
        XCTAssertTrue(session.consumeFocusRequest(for: created))

        await session.refreshLinks(noteId: source.id)
        XCTAssertEqual(session.linksOut.first?.kind, .note)
        XCTAssertEqual(session.linksOut.first?.targetID, created)
        await session.refreshLinks(noteId: created)
        XCTAssertEqual(session.backlinks.map(\.noteId), [source.id])
    }

    /// The Settings button: rebuilds, reports, and leaves counts only in the audit trail.
    func testRebuildingIndexesFromTheSessionAuditsCountsAndNoText() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        try await store.notes.save(Note(title: "Visit", content: "see [[SECRET-LINK-TEXT]] #SECRETTAG\n# SECRET-HEADING"))

        let outcome = await session.rebuildIndexes()
        XCTAssertTrue(outcome.passed, outcome.detail)
        XCTAssertFalse(outcome.detail.isEmpty)
        let logs = try await store.audit.recentLogs(limit: 20).filter { $0.action == "indexes_rebuilt" }
        XCTAssertEqual(logs.count, 1)
        let details = try XCTUnwrap(logs.first).details
        XCTAssertTrue(details.contains("notes=1"), details)
        XCTAssertFalse(details.contains("SECRET"), "audit details carry counts, never text")
        XCTAssertFalse(DisplayCopy.auditDetails(try XCTUnwrap(logs.first)).contains("SECRET"))
        XCTAssertFalse(DisplayCopy.auditDetails(try XCTUnwrap(logs.first)).isEmpty)
    }

    /// A note found by an alias is offered under the alias and written `Title|alias`.
    func testLinkCandidatesMatchAliasesAndInsertTheTitleWithTheAlias() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let target = Note(title: "Hypertension protocol", content: "---\naliases: [HTN]\n---\nbody")
        try await store.notes.save(target)
        let hits = await session.linkCandidates(anchor: "htn", excluding: nil)
        let hit = try XCTUnwrap(hits.first { $0.id == target.id }, "got \(hits)")
        XCTAssertEqual(hit.title, "HTN — Hypertension protocol")
        XCTAssertEqual(hit.insert, "Hypertension protocol|HTN")
        // A note found by its title is written as its title.
        let byTitle = await session.linkCandidates(anchor: "Hyper", excluding: nil)
        XCTAssertEqual(byTitle.first?.insert, "Hypertension protocol")
    }

    /// The Tags menu: counts from all three sources, a filter that narrows the
    /// list together with the search text, and nothing left over after a lock.
    func testTheTagFilterNarrowsTheNotesListTogetherWithSearch() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let both = Note(title: "Both", content: "digoxin dose #cardio")
        let tagOnly = Note(title: "Tag", content: "alone", tags: ["Cardio"])
        let other = Note(title: "Other", content: "digoxin elsewhere #renal")
        for note in [both, tagOnly, other] { try await store.notes.save(note) }
        await session.reload()
        await session.reloadNoteTags()
        XCTAssertEqual(session.noteTags.map(\.key), ["cardio", "renal"])
        XCTAssertEqual(session.noteTags.first { $0.key == "cardio" }?.count, 2)

        session.noteTagFilter = "cardio"
        try await waitUntil("the list is narrowed to the tag") { Set(session.notes.map(\.id)) == [both.id, tagOnly.id] }

        session.searchText = "digoxin"
        try await waitUntil("search and tag apply together") { session.notes.map(\.id) == [both.id] }

        session.noteTagFilter = nil
        try await waitUntil("only the search remains") { Set(session.notes.map(\.id)) == [both.id, other.id] }
    }

    func testTheTagFilterIsClearedWhenTheStoreLocks() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        try await store.notes.save(Note(title: "Tagged", content: "#cardio"))
        await session.reloadNoteTags()
        session.noteTagFilter = "cardio"
        await session.lockNow(reason: "test")
        XCTAssertNil(session.noteTagFilter)
        XCTAssertTrue(session.noteTags.isEmpty, "no tag names stay behind the curtain")
    }

    func testLinkCandidatesNeverOfferABlankTitle() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        try await store.notes.save(Note(title: "", content: "mentions hypertension"))
        try await store.notes.save(Note(title: "Hypertension protocol", content: ""))
        let hits = await session.linkCandidates(anchor: "hyper", excluding: nil)
        XCTAssertEqual(hits.map(\.title), ["Hypertension protocol"])
        let recent = await session.linkCandidates(anchor: "", excluding: nil)
        XCTAssertEqual(recent.map(\.title), ["Hypertension protocol"])
    }

    /// Quick Open searches the whole store: a past event or a completed todo
    /// is not in `session.events` / `session.todos` under the module's
    /// current filter, and reading those arrays made it unreachable from ⌘O.
    func testQuickOpenFindsRecordsTheCurrentFiltersHide() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)

        let past = CalendarEvent(
            title: "Old ward round",
            startDate: Date().addingTimeInterval(-2 * 86_400),
            endDate: Date().addingTimeInterval(-2 * 86_400 + 1800))
        try await store.events.save(past)
        let finished = TodoItem(title: "Finished labs", isCompleted: true)
        try await store.todos.save(finished)
        session.eventFilter = .upcoming
        session.todoFilter = .pending
        await session.reloadEvents()
        await session.reloadTodos()
        XCTAssertFalse(session.events.contains { $0.id == past.id },
                       "precondition: the Upcoming filter hides the past event")
        XCTAssertFalse(session.todos.contains { $0.id == finished.id },
                       "precondition: the Pending filter hides the completed todo")

        session.switcherText = "Old ward round"
        await session.updateSwitcherResults()
        XCTAssertTrue(session.switcherResults.contains { $0.id == past.id && $0.kind == .event },
                      "got \(session.switcherResults.map(\.title))")

        session.switcherText = "Finished labs"
        await session.updateSwitcherResults()
        XCTAssertTrue(session.switcherResults.contains { $0.id == finished.id && $0.kind == .todo },
                      "got \(session.switcherResults.map(\.title))")
    }

    /// A record with no name reads as its list fallback in Quick Open too, not
    /// as a blank row.
    func testQuickOpenNamesAnUnnamedPatient() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let unnamed = Patient.newRecord()
        try await store.patients.save(unnamed)

        session.switcherText = ""
        await session.updateSwitcherResults()
        let hit = session.switcherResults.first { $0.id == unnamed.id }
        XCTAssertEqual(hit?.title, "Unnamed Patient", "got \(session.switcherResults.map(\.title))")
    }

    /// Jumping from the graph or a backlink selects a record the list's
    /// search or filter hides; the list must be reset so the selected row is
    /// actually in it.
    func testJumpingToARecordRevealsItInTheList() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)

        // A past event under the default Upcoming filter.
        let past = CalendarEvent(
            title: "Old ward round",
            startDate: Date().addingTimeInterval(-2 * 86_400),
            endDate: Date().addingTimeInterval(-2 * 86_400 + 1800))
        try await store.events.save(past)
        session.eventFilter = .upcoming
        await session.reloadEvents()
        XCTAssertFalse(session.events.contains { $0.id == past.id })

        await session.jumpToGraphNode(LinkingService.GraphNode(
            id: "e:\(past.id.uuidString)", label: past.title, kind: .event))
        XCTAssertEqual(session.selectedEventId, past.id)
        XCTAssertEqual(session.eventFilter, .all)
        try await waitUntil("the list shows the past event again") {
            session.events.contains { $0.id == past.id }
        }

        // An archived patient while the active list is showing.
        var archived = Patient.newRecord()
        archived.profile.firstName = "Archived"
        archived.isArchived = true
        try await store.patients.save(archived)
        session.patientFilter = .active
        await session.reloadPatients()
        XCTAssertFalse(session.patients.contains { $0.id == archived.id })

        await session.jumpToGraphNode(LinkingService.GraphNode(
            id: "p:\(archived.id.uuidString)", label: archived.displayName, kind: .patient))
        XCTAssertEqual(session.patientFilter, .archived)
        XCTAssertEqual(session.selectedPatientId, archived.id)
        try await waitUntil("the archived list shows the restored patient") {
            session.patients.contains { $0.id == archived.id }
        }

        // A note excluded by the list's search.
        let note = Note(title: "Ward round", content: "body")
        try await store.notes.save(note)
        session.searchText = "zzz-nothing-matches"
        await session.reload()
        XCTAssertFalse(session.notes.contains { $0.id == note.id })

        await session.jumpToNote(note.id)
        XCTAssertEqual(session.searchText, "")
        XCTAssertTrue(session.notes.contains { $0.id == note.id })
    }

    func testLegacyImportDryRunsFirstAndKeepsARestorePoint() async throws {
        let session = try await makeSession()
        let folder = try Self.legacyFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let report = try await session.dryRunImport(from: folder)
        XCTAssertGreaterThan(report.totalImported, 0)
        XCTAssertTrue(session.patientDirectory.isEmpty, "a dry run writes nothing")

        try await session.performImport(from: folder)
        XCTAssertEqual(session.patientDirectory.count, report.patientsImported)
        let root = try XCTUnwrap(roots.last)
        let points = await session.restorePoints()
        XCTAssertEqual(points.count, 1, "one restore point before the import")
        XCTAssertEqual(points.first?.name, "Pre-import snapshot")
        XCTAssertTrue(points.first?.url.pathExtension == "mnrp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.filesURL.path),
                       "the import must not leave a plaintext Files/ tree")
        XCTAssertNotNil(session.notice)
    }

    /// The legacy iCloud layout, built from the fixtures the importer tests use.
    private static func legacyFolder() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-session-import-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("MedNotes", isDirectory: true)
        let bundle = Bundle(for: SessionFlowTests.self)
        let fixtures: [(name: String, folder: String)] = [
            ("patient_full", "Patients"), ("note_simple", "Notes"),
            ("todo_high", "Todos"), ("event_appointment", "CalendarEvents")
        ]
        for fixture in fixtures {
            let directory = source.appendingPathComponent(fixture.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let url = bundle.url(forResource: fixture.name, withExtension: "json") else {
                throw XCTSkip("fixture \(fixture.name) is missing from the test bundle")
            }
            try Data(contentsOf: url).write(to: directory.appendingPathComponent("\(fixture.name).json"))
        }
        return source
    }

    /// Operators in the search box narrow the list, and each row gets the
    /// line that matched; nothing of that is left after a lock.
    func testOperatorsNarrowTheNotesListAndEachRowGetsItsMatchedLine() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let cardio = Note(title: "Cardio", content: "Intro\ndigoxin dose raised #cardio")
        let renal = Note(title: "Renal", content: "digoxin held #renal")
        for note in [cardio, renal] { try await store.notes.save(note) }

        session.searchText = "digoxin -tag:renal"
        try await waitUntil("the list is narrowed by the operator") { session.notes.map(\.id) == [cardio.id] }
        XCTAssertEqual(session.noteSnippets[cardio.id]?.text, "digoxin dose raised #cardio")
        XCTAssertNil(session.noteSnippets[renal.id], "a note that is not listed has no snippet")

        session.searchText = "tag:renal"
        try await waitUntil("a tag-only search") { session.notes.map(\.id) == [renal.id] }

        session.searchText = ""
        try await waitUntil("snippets go with the search") { session.noteSnippets.isEmpty && session.notes.count == 2 }

        session.searchText = "digoxin"
        try await waitUntil("snippets are back") { !session.noteSnippets.isEmpty }
        await session.lockNow(reason: "test")
        XCTAssertTrue(session.noteSnippets.isEmpty, "no note text stays behind the curtain")
    }

    func testQuickOpenAndLinkCompletionIgnoreSearchOperators() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        try await store.notes.save(Note(title: "Digoxin protocol", content: "body"))
        let hits = await session.linkCandidates(anchor: "-digoxin", excluding: nil)
        XCTAssertTrue(hits.contains { $0.title == "Digoxin protocol" }, "got \(hits.map(\.title))")
    }

    /// The graph's settings are kept in the encrypted store, leave memory
    /// when the store locks, and come back on unlock.
    func testGraphSettingsAreSavedClearedOnLockAndRestoredOnUnlock() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        session.graphSettings.query = "patient:Nikos"
        session.graphSettings.arrows = true
        session.localGraphSettings.localDepth = 3
        // Saved a moment after the last change; polled in the store itself.
        let deadline = Date().addingTimeInterval(5)
        var saved = false
        while !saved, Date() < deadline {
            let global = try await store.db.appState(key: "graph.global")
            let local = try await store.db.appState(key: "graph.local")
            saved = global?.contains("patient:Nikos") == true && local != nil
            if !saved { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(saved, "both rows should have been saved")

        await session.lockNow(reason: "test")
        XCTAssertEqual(session.graphSettings, GraphSettings(), "a patient's name stays out of memory while locked")
        XCTAssertEqual(session.localGraphSettings, GraphSettings())

        await session.unlock()
        try await waitUntil("the saved settings come back") { session.graphSettings.query == "patient:Nikos" }
        XCTAssertTrue(session.graphSettings.arrows)
        XCTAssertEqual(session.localGraphSettings.localDepth, 3)
    }

    func testGraphQuerySetsNameTheNotesAsGraphNodes() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let a = Note(title: "A", content: "digoxin #cardio")
        let b = Note(title: "B", content: "digoxin #renal")
        for note in [a, b] { try await store.notes.save(note) }
        var settings = GraphSettings()
        settings.query = "digoxin -tag:renal"
        let group = GraphGroup(query: "tag:renal", colorIndex: 4)
        settings.groups = [group, GraphGroup(query: "   ", colorIndex: 1)]
        let sets = await session.graphQuerySets(for: settings)
        XCTAssertEqual(sets.matching, ["n:\(a.id.uuidString)"])
        XCTAssertEqual(sets.groups[group.id], ["n:\(b.id.uuidString)"])
        XCTAssertEqual(sets.groups.count, 1, "a blank group query matches nothing and is not evaluated")
        let none = await session.graphQuerySets(for: GraphSettings())
        XCTAssertNil(none.matching)
    }

    /// One filtered graph, worked out in the session, follows the settings:
    /// toggles at once, a query after its lookup, and nothing is left when locked.
    func testTheFilteredGraphFollowsTheSettingsAndEmptiesOnLock() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let target = Note(title: "Target", content: "x")
        let linked = Note(title: "Linked", content: "digoxin [[Target]] #cardio")
        let other = Note(title: "Other", content: "plain [[Target]] #renal")
        let loose = Note(title: "Loose", content: "digoxin alone")
        for note in [target, linked, other, loose] { try await store.notes.save(note) }
        await session.loadGraph()
        XCTAssertEqual(session.filteredGraph.nodes.count, 4)
        XCTAssertEqual(session.filteredGraph.edges.count, 2)
        XCTAssertEqual(session.filteredGraph.degree["n:\(target.id.uuidString)"], 2)

        session.graphSettings.showOrphans = false
        XCTAssertEqual(session.filteredGraph.nodes.count, 3, "the toggle applies at once")
        session.graphSettings.showOrphans = true

        session.graphSettings.query = "digoxin"
        try await waitUntil("the query narrows the graph") {
            Set(session.filteredGraph.nodes.map(\.label)) == ["Linked", "Loose"]
        }

        let group = GraphGroup(query: "tag:renal", colorIndex: 6)
        session.graphSettings.query = ""
        session.graphSettings.groups = [group]
        try await waitUntil("the group colours its notes") {
            session.filteredGraph.colorIndex["n:\(other.id.uuidString)"] == 6
        }
        XCTAssertEqual(session.filteredGraph.nodes.count, 4, "a group colours; it does not filter")

        await session.lockNow(reason: "test")
        XCTAssertTrue(session.filteredGraph.nodes.isEmpty, "no note title stays behind the curtain")
    }
}
