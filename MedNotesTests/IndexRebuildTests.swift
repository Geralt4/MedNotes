import XCTest
@testable import MedNotes

/// "Rebuild indexes": everything derived from the notes and patients is made
/// again, checked, and nothing else is touched.
final class IndexRebuildTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-rebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        #if DEBUG
        LinkIndex.failDerivationForTesting = nil
        #endif
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeStore() throws -> (AppStore, DataRoot) {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        return (try AppStore.testStore(dataRoot: root), root)
    }

    private func connection(_ root: DataRoot) throws -> SQLConnection {
        try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
    }

    private func scalar(_ root: DataRoot, _ sql: String) throws -> Int {
        let conn = try connection(root)
        defer { conn.close() }
        let s = try conn.prepare(sql)
        defer { s.finalize() }
        return try s.step() ? (s.columnInt(0) ?? 0) : 0
    }

    private func rows(_ root: DataRoot, _ sql: String, columns: Int32) throws -> [[String]] {
        let conn = try connection(root)
        defer { conn.close() }
        let s = try conn.prepare(sql)
        defer { s.finalize() }
        var out: [[String]] = []
        while try s.step() { out.append((0..<columns).map { s.columnText($0) ?? "∅" }) }
        return out
    }

    private func patient() -> Patient {
        var profile = PatientProfile(firstName: "Maria", lastName: "Papadopoulou",
                                     dateOfBirth: Date(timeIntervalSince1970: 0))
        profile.amka = "70000000001"
        return Patient(profile: profile)
    }

    private func seed(_ store: AppStore) async throws -> (round: Note, protocolNote: Note) {
        let protocolNote = Note(title: "Protocol", content: "body")
        let round = Note(title: "Round", content: "digoxin dose reviewed [[Protocol]] #cardio\n# Plan")
        try await store.patients.save(patient())
        try await store.notes.save(protocolNote)
        try await store.notes.save(round)
        return (round, protocolNote)
    }

    func testARebuildReportsCountsAndSearchStillWorks() async throws {
        let (store, _) = try makeStore()
        let (round, _) = try await seed(store)

        let report = try await store.db.rebuildIndexes()
        XCTAssertTrue(report.passed, "\(report.problems)")
        XCTAssertEqual(report.notes, 2)
        XCTAssertEqual(report.patients, 1)
        XCTAssertEqual(report.links, 1)
        XCTAssertEqual(report.unresolvedLinks, 0)
        XCTAssertEqual(report.headings, 1)
        XCTAssertEqual(report.tags, 1)
        let found = try await store.notes.search("digoxin")
        XCTAssertEqual(found.map(\.id), [round.id])
        let patients = try await store.patients.search("Maria")
        XCTAssertEqual(patients.count, 1)
        await store.close()
    }

    func testARebuildRepairsDamagedIndexes() async throws {
        let (store, root) = try makeStore()
        let (round, _) = try await seed(store)
        let conn = try connection(root)
        for statement in ["DELETE FROM notes_fts", "DELETE FROM patients_fts", "DELETE FROM wikilinks",
                          "DELETE FROM link_sources", "DELETE FROM note_tags", "DELETE FROM note_headings"] {
            try conn.exec(statement)
        }
        conn.close()
        let before = try await store.notes.search("digoxin")
        XCTAssertTrue(before.isEmpty, "the damage is real")

        let report = try await store.db.rebuildIndexes()
        XCTAssertTrue(report.passed, "\(report.problems)")
        let after = try await store.notes.search("digoxin")
        XCTAssertEqual(after.map(\.id), [round.id])
        let patients = try await store.patients.search("Papadopoulou")
        XCTAssertEqual(patients.count, 1)
        XCTAssertEqual(try scalar(root, "SELECT COUNT(*) FROM wikilinks"), 1)
        XCTAssertEqual(try scalar(root, "SELECT COUNT(*) FROM note_tags"), 1)
        XCTAssertEqual(try scalar(root, "SELECT COUNT(*) FROM note_headings"), 1)
        await store.close()
    }

    func testALinkKeepsItsOriginalTargetAcrossARebuildEvenWhenTheTitleIsNowShared() async throws {
        let (store, root) = try makeStore()
        let first = Note(title: "Plan", content: "first")
        let source = Note(title: "S", content: "[[Plan]]")
        try await store.notes.save(first)
        try await store.notes.save(source)
        try await store.notes.save(Note(title: "Plan", content: "second"))

        _ = try await store.db.rebuildIndexes()
        let link = try rows(root, "SELECT state, dst_id FROM wikilinks WHERE src_note_id = '\(source.id.uuidString)'", columns: 2)
        XCTAssertEqual(link, [["resolved", first.id.uuidString]])
        await store.close()
    }

    func testRebuildingTwiceChangesNothing() async throws {
        let (store, root) = try makeStore()
        _ = try await seed(store)
        let first = try await store.db.rebuildIndexes()
        let snapshot = try rows(root, "SELECT id, state, dst_id, head_key FROM wikilinks ORDER BY id", columns: 4)
        let second = try await store.db.rebuildIndexes()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try rows(root, "SELECT id, state, dst_id, head_key FROM wikilinks ORDER BY id", columns: 4), snapshot)
        await store.close()
    }

    func testARebuildLeavesEverythingElseAlone() async throws {
        let (store, root) = try makeStore()
        let (round, protocolNote) = try await seed(store)
        // A superseded link row and a todo, to be sure nothing outside the indexes is touched.
        let conn = try connection(root)
        try conn.exec("""
            INSERT INTO note_links (id, src_note_id, dst_note_id, dst_patient_id, anchor_text)
            VALUES ('legacy', '\(round.id.uuidString)', '\(protocolNote.id.uuidString)', NULL, 'Protocol')
            """)
        conn.close()
        let notesBefore = try await store.notes.loadAll()
        let queries = [
            "SELECT id, src_note_id, dst_note_id, anchor_text FROM note_links ORDER BY id",
            "SELECT patient_id, note_id FROM patient_notes ORDER BY note_id",
            "SELECT version FROM migrations ORDER BY version",
            "SELECT id, action FROM audit_logs ORDER BY id",
            "SELECT id, name FROM note_templates ORDER BY id",
        ]
        let before = try queries.map { try rows(root, $0, columns: $0.contains("src_note_id") ? 4 : 2) }

        _ = try await store.db.rebuildIndexes()

        let after = try queries.map { try rows(root, $0, columns: $0.contains("src_note_id") ? 4 : 2) }
        XCTAssertEqual(after, before)
        let notesAfter = try await store.notes.loadAll()
        XCTAssertEqual(notesAfter, notesBefore, "notes are not rewritten")
        await store.close()
    }

    #if DEBUG
    func testANoteThatCannotBeDerivedIsReportedAndTheRestIsRebuilt() async throws {
        let (store, _) = try makeStore()
        let (round, protocolNote) = try await seed(store)
        LinkIndex.failDerivationForTesting = { $0 == protocolNote.id.uuidString }

        let report = try await store.db.rebuildIndexes()
        XCTAssertEqual(report.failedNotes, 1)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.problems.isEmpty, "the counts still agree: the failed note is left out of both sides")
        let found = try await store.notes.search("digoxin")
        XCTAssertEqual(found.map(\.id), [round.id], "the full-text index is rebuilt regardless")
        await store.close()
    }
    #endif

    func testTheAuditDetailsAreCountsOnly() {
        var report = IndexRebuildReport()
        report.notes = 3
        report.links = 5
        XCTAssertEqual(
            report.auditDetails,
            "notes=3 links=5 unresolved=0 ambiguous=0 headings=0 tags=0 properties=0 failed=0 passed=1")
    }
}
