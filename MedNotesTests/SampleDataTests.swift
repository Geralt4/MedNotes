import XCTest
@testable import MedNotes

/// Guards the preview harness itself. A silently broken seed costs a whole
/// review run — the reviewer launches, sees something plausible but wrong, and
/// draws conclusions about UI code that was never exercised.
final class SampleDataTests: XCTestCase {
    private var root: DataRoot!
    private var store: AppStore!
    private var now = Date()

    override func setUpWithError() throws {
        now = Date()   // XCTest builds every test instance at bundle start
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

    func testSeedWritesEveryModule() async throws {
        let summary = try await SampleData.seed(into: store, now: now)

        let counts = try await store.counts()
        XCTAssertEqual(counts["patients"], summary.patients)
        XCTAssertEqual(counts["notes"], summary.notes)
        XCTAssertEqual(counts["todo_items"], summary.todos)
        XCTAssertEqual(counts["calendar_events"], summary.events)

        // Enough of each to fill a list rather than a near-empty column.
        XCTAssertGreaterThanOrEqual(summary.patients, 10)
        XCTAssertGreaterThanOrEqual(summary.notes, 12)
        XCTAssertGreaterThanOrEqual(summary.todos, 14)
        XCTAssertGreaterThanOrEqual(summary.events, 18)

        let integrity = try await store.integrity()
        let violations = try await store.foreignKeyViolations()
        XCTAssertEqual(integrity, "ok")
        XCTAssertEqual(violations, 0)
    }

    func testSeedIsIdempotentlyDetectable() async throws {
        let isEmptyBefore = try await SampleData.isEmpty(store)
        XCTAssertTrue(isEmptyBefore)
        try await SampleData.seed(into: store, now: now)
        let isEmptyAfter = try await SampleData.isEmpty(store)
        XCTAssertFalse(isEmptyAfter, "a seeded store must not re-seed on relaunch")
    }

    /// `NoteService.save` stamps `updatedAt = Date()` unconditionally, so the
    /// seeder writes the row a second time to put the intended timestamp back.
    /// Without this the notes list would show every row as "just now" and sort
    /// them all into one indistinguishable block.
    func testNoteTimestampsAreBackdatedToTheirIntendedValues() async throws {
        try await SampleData.seed(into: store, now: now)

        let expected = SampleData.expectedNoteTimestamps(now: now)
        let saved = try await store.notes.loadAll()
        XCTAssertEqual(saved.count, expected.count)

        for note in saved {
            let intended = try XCTUnwrap(
                expected[note.title], "unexpected seeded note titled \(note.title)")
            XCTAssertEqual(
                note.updatedAt.timeIntervalSince1970,
                intended.timeIntervalSince1970,
                accuracy: 1,
                "note \"\(note.title)\" was not backdated to its intended timestamp")
        }
    }

    func testSeededNotesAreAllInThePast() async throws {
        try await SampleData.seed(into: store, now: now)
        let seedFinished = Date()
        for note in try await store.notes.loadAll() {
            XCTAssertLessThan(
                note.updatedAt, seedFinished,
                "note \"\(note.title)\" carries a future timestamp; relative stamps would read \"in …\"")
        }
    }

    /// Pins the assumption the backdating rests on. Nothing may rewrite the
    /// stamps after the seed: the mirror is retired, so a plain reload must
    /// return exactly what was written.
    func testReloadDoesNotUndoTheBackdating() async throws {
        try await SampleData.seed(into: store, now: now)
        let before = try await store.notes.loadAll()

        // Read back through a second connection to the file, not through the
        // connection that wrote: that is what a relaunch does.
        try await store.db.checkpoint()
        let reopened = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        let after = try await reopened.loadAllNotes()
        await reopened.close()
        XCTAssertEqual(after.count, before.count, "reload changed the note count")

        let beforeStamps = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.updatedAt) })
        for note in after {
            let original = try XCTUnwrap(beforeStamps[note.id])
            XCTAssertEqual(
                note.updatedAt.timeIntervalSince1970, original.timeIntervalSince1970,
                accuracy: 1,
                "reload re-stamped \"\(note.title)\"")
        }
    }

    /// The seeded bodies are what the note list actually renders, so they must
    /// survive the stripper without leaking syntax into a row.
    func testSeededBodiesSurviveThePreviewStripper() async throws {
        try await SampleData.seed(into: store, now: now)

        for note in try await store.notes.loadAll() {
            let preview = DisplayCopy.preview(note.content)
            for marker in ["[[", "](", "**", "~~", "```"] {
                XCTAssertFalse(
                    preview.contains(marker),
                    "preview of \"\(note.title)\" leaked \(marker): \(preview)")
            }
        }
    }

    /// The seed exists to make the rows awkward, not tidy. If these collapse to
    /// uniform records the harness stops testing anything.
    func testSeedCoversTheAwkwardCases() async throws {
        try await SampleData.seed(into: store, now: now)

        let patients = try await store.patients.loadAll()
        XCTAssertTrue(
            patients.contains { $0.displayName.trimmingCharacters(in: .whitespaces).isEmpty },
            "expected an unnamed patient to exercise the DisplayCopy fallback")
        XCTAssertTrue(
            patients.contains { $0.medical.conditions.filter { $0.status == .active }.isEmpty },
            "expected a patient with no active conditions (no trailing pill)")
        XCTAssertTrue(
            patients.contains { $0.medical.conditions.filter { $0.status == .active }.count >= 3 },
            "expected a patient with several active conditions")
        XCTAssertTrue(
            patients.contains { $0.profile.amka.isEmpty || $0.profile.phone.isEmpty },
            "expected a patient with a gap in the subline")

        let notes = try await store.notes.loadAll()
        XCTAssertTrue(notes.contains { $0.tags.count > 3 },
                      "expected a note with more tags than TagChipRow can show")
        XCTAssertTrue(notes.contains { $0.isPinned }, "expected pinned notes")
        XCTAssertTrue(notes.contains { $0.content.isEmpty },
                      "expected an empty-bodied note (row must collapse its preview line)")

        let todos = try await store.todos.loadAll()
        for priority in TodoPriority.allCases {
            XCTAssertTrue(todos.contains { $0.priority == priority },
                          "expected at least one \(priority.rawValue) todo")
        }
        XCTAssertTrue(todos.contains(where: \.isOverdue), "expected an overdue todo")
        XCTAssertTrue(todos.contains(where: \.isDueToday), "expected a todo due today")
        XCTAssertTrue(todos.contains(where: \.isCompleted), "expected a completed todo")

        let events = try await store.events.loadAll()
        let months = Set(events.map {
            Calendar.current.dateInterval(of: .month, for: $0.startDate)?.start
        })
        XCTAssertGreaterThanOrEqual(months.count, 3, "expected events across several month sections")
    }

    /// Wiki-links must resolve against seeded targets, so the graph and the
    /// backlinks panel are reviewed on real edges rather than only broken ones.
    func testSeededWikiLinksResolve() async throws {
        try await SampleData.seed(into: store, now: now)

        let notes = try await store.notes.loadAll()
        let linking = notes.first { $0.content.contains("[[") }
        let source = try XCTUnwrap(linking, "expected at least one note containing wiki-links")

        let anchors = LinkingService.extractAnchors(from: source.content)
        XCTAssertFalse(anchors.isEmpty)

        let titles = Set(notes.map(\.title))
        let patientNames = Set(try await store.patients.loadAll().map(\.displayName))
        for anchor in anchors {
            XCTAssertTrue(
                titles.contains(anchor) || patientNames.contains(anchor),
                "wiki-link [[\(anchor)]] has no seeded target")
        }
    }
}
