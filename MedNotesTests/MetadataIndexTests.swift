import XCTest
@testable import MedNotes

/// The derived note metadata: what `LinkIndex.deriveRows` writes beside the
/// links, and how it stays true to the notes.
final class MetadataIndexTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        #if DEBUG
        LinkIndex.failDerivationForTesting = nil
        #endif
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRoot() throws -> DataRoot {
        try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
    }

    /// Rows of any query, every column as text, through a second connection.
    private func query(_ root: DataRoot, _ sql: String) throws -> [[String]] {
        let conn = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        return try query(conn, sql)
    }

    private func query(_ conn: SQLConnection, _ sql: String) throws -> [[String]] {
        let s = try conn.prepare(sql)
        defer { s.finalize() }
        var out: [[String]] = []
        let columns = Int32(sqlColumnCount(sql))
        while try s.step() {
            out.append((0..<columns).map { s.columnText($0) ?? "∅" })
        }
        return out
    }

    /// The number of selected columns, for the simple queries used here.
    private func sqlColumnCount(_ sql: String) -> Int {
        guard let from = sql.range(of: " FROM ", options: .caseInsensitive) else { return 1 }
        let list = sql[sql.index(sql.startIndex, offsetBy: 7)..<from.lowerBound]   // after "SELECT "
        return list.split(separator: ",").count
    }

    private func exec(_ root: DataRoot, _ statements: [String]) throws {
        let conn = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        for statement in statements { try conn.exec(statement) }
    }

    private let sample = """
        ---
        status: draft
        count: 3
        done: true
        tags: [cardio, "#ward"]
        aliases: [HTN, "high blood pressure"]
        ---
        # Plan
        Seen today #follow-up ^visit1
        ## Orders #cardio
        """

    // MARK: - What is derived

    func testHeadingsBlocksTagsAliasesAndPropertiesAreDerived() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Visit", content: sample)
        try await store.notes.save(note)
        let id = note.id.uuidString

        XCTAssertEqual(
            try query(root, "SELECT level, text FROM note_headings WHERE note_id = '\(id)' ORDER BY ordinal"),
            [["1", "Plan"], ["2", "Orders #cardio"]])
        XCTAssertEqual(
            try query(root, "SELECT block_id FROM note_blocks WHERE note_id = '\(id)'"), [["visit1"]])
        XCTAssertEqual(
            try query(root, "SELECT tag, source FROM note_tags WHERE note_id = '\(id)' ORDER BY ordinal"),
            [["follow-up", "inline"], ["cardio", "inline"], ["cardio", "property"], ["ward", "property"]])
        XCTAssertEqual(
            try query(root, "SELECT alias FROM note_aliases WHERE note_id = '\(id)' ORDER BY ordinal"),
            [["HTN"], ["high blood pressure"]])
        XCTAssertEqual(
            try query(root, "SELECT key, kind, text_value FROM note_properties WHERE note_id = '\(id)' ORDER BY ordinal"),
            [["status", "text", "draft"], ["count", "number", "3"], ["done", "checkbox", "true"],
             ["tags", "list", "∅"], ["aliases", "list", "∅"]])
        XCTAssertEqual(
            try query(root, "SELECT number_value, list_json FROM note_properties WHERE note_id = '\(id)' AND key = 'count'"),
            [["3.0", "∅"]])
        XCTAssertEqual(
            try query(root, "SELECT list_json FROM note_properties WHERE note_id = '\(id)' AND key = 'tags'"),
            [["[\"cardio\",\"ward\"]"]])
        await store.close()
    }

    func testTheNotesOwnTagFieldIsNotCopied() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Field", content: "text #inline", tags: ["from-field"])
        try await store.notes.save(note)
        XCTAssertEqual(try query(root, "SELECT tag FROM note_tags"), [["inline"]])
        await store.close()
    }

    func testRowsFollowTheTextAndGoWithTheNote() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var note = Note(title: "Visit", content: sample)
        try await store.notes.save(note)
        note.content = "# Only a heading\n"
        try await store.notes.save(note)
        XCTAssertEqual(try query(root, "SELECT text FROM note_headings"), [["Only a heading"]])
        XCTAssertEqual(try query(root, "SELECT tag FROM note_tags"), [])
        XCTAssertEqual(try query(root, "SELECT key FROM note_properties"), [])

        try await store.notes.save(Note(title: "Other", content: sample))
        try await store.notes.delete(id: note.id)
        XCTAssertEqual(try query(root, "SELECT DISTINCT note_id FROM note_tags").count, 1)
        let violations = try await store.foreignKeyViolations()
        XCTAssertEqual(violations, 0)
        await store.close()
    }

    func testProseBetweenTwoRulesIsIndexedAsText() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Rules", content: "---\nThe patient is stable. #improving\n---\n# Plan")
        try await store.notes.save(note)
        XCTAssertEqual(try query(root, "SELECT tag FROM note_tags"), [["improving"]])
        XCTAssertEqual(try query(root, "SELECT text FROM note_headings"), [["Plan"]])
        XCTAssertEqual(try query(root, "SELECT key FROM note_properties"), [])
        await store.close()
    }

    func testAFenceInsideFrontMatterDoesNotHideTheBody() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Target", content: "")
        let note = Note(title: "Fenced", content: "---\nnote: ```\n---\n[[Target]] #t\n# Head")
        try await store.notes.save(target)
        try await store.notes.save(note)
        XCTAssertEqual(try query(root, "SELECT state FROM wikilinks WHERE src_note_id = '\(note.id.uuidString)'"), [["resolved"]])
        XCTAssertEqual(try query(root, "SELECT tag FROM note_tags"), [["t"]])
        XCTAssertEqual(try query(root, "SELECT text FROM note_headings"), [["Head"]])
        await store.close()
    }

    func testALinkToATitleWithAnAliasResolvesToTheTitle() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Plan #2", content: "")
        let source = Note(title: "S", content: "[[Plan #2|see the plan]] and [[Plan #2#Heading|x]]")
        try await store.notes.save(target)
        try await store.notes.save(source)
        let states = try query(root, "SELECT state, dst_id FROM wikilinks WHERE src_note_id = '\(source.id.uuidString)' ORDER BY ordinal")
        // The second names "Plan" with a heading "2#Heading": nothing is called that.
        XCTAssertEqual(states.map { $0[0] }, ["resolved", "unresolved"])
        XCTAssertEqual(states[0][1], target.id.uuidString)
        await store.close()
    }

    // MARK: - Staying true

    func testStaleMetadataIsRepairedWhenTheStoreIsOpened() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var note = Note(title: "Visit", content: sample)
        try await store.notes.save(note)
        // A save whose derivation never ran.
        note.content = "# Changed #new"
        try await store.db.saveNote(note)
        await store.close()

        let reopened = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try query(root, "SELECT text FROM note_headings"), [["Changed #new"]])
        XCTAssertEqual(try query(root, "SELECT tag FROM note_tags"), [["new"]])
        await reopened.close()
    }

    func testTheMetadataTablesCanBeEmptiedAndAreRebuiltOnOpen() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Visit", content: sample))
        let before = try query(root, "SELECT tag, source FROM note_tags ORDER BY ordinal")
        await store.close()
        try exec(root, ["DELETE FROM link_sources"])   // what marks a note stale
        try exec(root, ["DELETE FROM note_tags", "DELETE FROM note_headings", "DELETE FROM note_properties"])

        let reopened = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try query(root, "SELECT tag, source FROM note_tags ORDER BY ordinal"), before)
        XCTAssertEqual(try query(root, "SELECT COUNT(*) FROM note_headings"), [["2"]])
        await reopened.close()
    }

    func testAStoreFromBeforeTheMetadataTablesGainsThemOnOpen() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Visit", content: sample))
        await store.close()
        // As a version-5 build left it: no metadata tables, older derivation version.
        try exec(root, [
            "DROP TABLE note_headings", "DROP TABLE note_blocks", "DROP TABLE note_tags",
            "DROP TABLE note_aliases", "DROP TABLE note_properties",
            "DELETE FROM migrations WHERE version LIKE '6.%'",
            "UPDATE link_sources SET parser_version = 1",
        ])

        let upgraded = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try query(root, "SELECT COUNT(*) FROM note_headings"), [["2"]])
        XCTAssertEqual(try query(root, "SELECT COUNT(*) FROM note_tags"), [["4"]])
        XCTAssertEqual(try query(root, "SELECT version FROM migrations WHERE version = '6.0-note-metadata'"),
                       [["6.0-note-metadata"]])
        XCTAssertEqual(try query(root, "SELECT parser_version FROM link_sources"),
                       [[String(LinkIndex.derivationVersion)]])
        await upgraded.close()
    }

    /// An older build that saves a note records the older version, whatever
    /// the text; the newer build derives that note again.
    func testANoteTheOlderBuildLastSavedIsDerivedAgain() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Visit", content: sample))
        await store.close()
        try exec(root, ["UPDATE link_sources SET parser_version = 1", "DELETE FROM note_headings"])

        let reopened = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try query(root, "SELECT COUNT(*) FROM note_headings"), [["2"]])
        await reopened.close()

        // The other direction: a newer derivation is left alone by the same rule.
        try exec(root, ["UPDATE link_sources SET parser_version = 99", "DELETE FROM note_headings"])
        let again = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try query(root, "SELECT COUNT(*) FROM note_headings"), [["0"]],
                       "a version at or above the current one is trusted")
        await again.close()
    }

    func testRelinkingTwiceGivesTheSameRows() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Visit", content: sample + "\n[[Visit]] [[Nowhere]]")
        try await store.notes.save(note)
        let queries = [
            "SELECT id, ordinal, raw_target, target_key, inner_key, head_key, state, dst_id FROM wikilinks ORDER BY id",
            "SELECT ordinal, level, text, key, start_offset FROM note_headings ORDER BY ordinal",
            "SELECT block_id, start_offset FROM note_blocks ORDER BY block_id",
            "SELECT ordinal, tag, tag_key, source FROM note_tags ORDER BY ordinal",
            "SELECT ordinal, alias, alias_key FROM note_aliases ORDER BY ordinal",
            "SELECT ordinal, key, kind, text_value FROM note_properties ORDER BY ordinal",
        ]
        func snapshot() throws -> [[[String]]] {
            try queries.map { try query(root, $0) }
        }
        let first = try snapshot()
        try await store.db.relinkNote(id: note.id)
        XCTAssertEqual(try snapshot(), first)
        await store.close()
    }

    #if DEBUG
    func testANoteThatCannotBeDerivedDoesNotStopTheOthers() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let a = Note(title: "A", content: "# One")
        let b = Note(title: "B", content: "# Two")
        let c = Note(title: "C", content: "# Three")
        for note in [a, b, c] { try await store.db.saveNote(note) }   // saved, never derived

        LinkIndex.failDerivationForTesting = { $0 == b.id.uuidString }
        await store.db.refreshStaleLinks()
        XCTAssertEqual(try query(root, "SELECT text FROM note_headings ORDER BY text"), [["One"], ["Three"]])
        XCTAssertEqual(try query(root, "SELECT COUNT(*) FROM link_sources"), [["2"]], "the failed note stays stale")

        LinkIndex.failDerivationForTesting = nil
        await store.db.refreshStaleLinks()
        XCTAssertEqual(try query(root, "SELECT text FROM note_headings ORDER BY text"), [["One"], ["Three"], ["Two"]])
        await store.close()
    }
    #endif
}
