import XCTest
@testable import MedNotes

/// Greek accents, capitals and the final sigma do not matter to a search, in
/// the full-text indexes, in their migration, and in the filters that run in
/// Swift.
final class GreekSearchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-greek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        #if DEBUG
        Database.failFTSFoldingForTesting = false
        #endif
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRoot(_ name: String = "root") throws -> DataRoot {
        try DataRoot(rootURL: tempDir.appendingPathComponent(name, isDirectory: true))
    }

    private func patient(_ first: String, _ last: String, fathers: String? = nil, amka: String = "12345678901") -> Patient {
        var profile = PatientProfile(
            firstName: first, lastName: last,
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -40, to: Date())!,
            gender: .male, amka: amka, phone: "", email: "")
        profile.fathersName = fathers
        return Patient(profile: profile)
    }

    private func titles(_ store: AppStore, _ text: String) async throws -> [String] {
        try await store.notes.list(search: text, tagKey: nil).map(\.title).sorted()
    }

    // MARK: - Notes

    func testAnAccentedWordIsFoundWithoutItsAccentAndTheOtherWayRound() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "Accented", content: "Ο ασθενής ήρθε σήμερα με πόνο"))
        try await store.notes.save(Note(title: "Plain", content: "ο ασθενης ηρθε σημερα"))
        try await store.notes.save(Note(title: "Other", content: "τίποτα"))

        for query in ["ασθενης", "ασθενής", "ΑΣΘΕΝΗΣ", "ΑΣΘΕΝΉΣ", "ασθεν", "σημερα", "σήμερα", "πονο", "ΠΌΝΟ"] {
            let found = try await titles(store, query)
            XCTAssertTrue(found.contains("Accented"), "\(query) → \(found)")
        }
        for query in ["ασθενης", "ασθενής", "ΗΡΘΕ"] {
            let found = try await titles(store, query)
            XCTAssertTrue(found.contains("Plain"), "\(query) → \(found)")
        }
        let none = try await titles(store, "ασθενης τιποτα")
        XCTAssertTrue(none.isEmpty)
        await store.close()
    }

    func testCapitalsFinalSigmaAndDecomposedTextAreFolded() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "Caps", content: "ΚΑΡΔΙΟΛΟΓΊΑ ΚΌΣΜΟΣ"))
        let decomposed = "κο\u{0301}σμος και ασθενη\u{0301}ς".decomposedStringWithCanonicalMapping
        try await store.notes.save(Note(title: "NFD", content: decomposed))
        let caps = try await titles(store, "καρδιολογια")
        XCTAssertEqual(caps, ["Caps"])
        let sigma = try await titles(store, "κοσμοσ")
        XCTAssertEqual(sigma, ["Caps", "NFD"], "ς, Σ and σ are one letter")
        let composedQuery = try await titles(store, "ασθενής")
        XCTAssertEqual(composedQuery, ["NFD"], "decomposed stored text matches a composed query")
        await store.close()
    }

    func testPhrasesNegationTagsAndTheOperatorsFold() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "One", content: "θωρακικός πόνος σήμερα #Καρδιολογία"))
        try await store.notes.save(Note(title: "Two", content: "θωρακικός πόνος χθες", tags: ["Νεφρολογία"]))
        let phrase = try await titles(store, "\"θωρακικος πονος\"")
        XCTAssertEqual(phrase, ["One", "Two"])
        let negated = try await titles(store, "πονος -σημερα")
        XCTAssertEqual(negated, ["Two"])
        let tag = try await titles(store, "tag:καρδιολογια")
        XCTAssertEqual(tag, ["One"])
        let fieldTag = try await titles(store, "tag:ΝΕΦΡΟΛΟΓΊΑ")
        XCTAssertEqual(fieldTag, ["Two"])
        // The plain search (quick open, [[ completion) folds too.
        let plain = try await store.notes.search("θωρακικος").map(\.title).sorted()
        XCTAssertEqual(plain, ["One", "Two"])
        await store.close()
    }

    func testAGreekTagInTheTagFieldIsFoundByWord() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "Tagged", content: "nothing here", tags: ["#Παθολογία"]))
        let found = try await titles(store, "παθολογια")
        XCTAssertEqual(found, ["Tagged"], "the tag field is indexed folded, with the JSON around it")
        await store.close()
    }

    // MARK: - Patients

    func testPatientNamesAndFathersNamesFold() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.db.savePatient(patient("Γεώργιος", "Παπαδόπουλος", fathers: "Ιωάννης", amka: "11111111111"))
        try await store.db.savePatient(patient("Μαρία", "Νικολάου", amka: "22222222222"))

        for query in ["Παπαδόπουλος", "παπαδοπουλος", "ΠΑΠΑΔΟΠΟΥΛΟΣ", "γεωργιος", "ΓΕΩΡΓΙΟΣ", "γεωργιοσ παπαδ"] {
            let found = try await store.db.searchPatients(query)
            XCTAssertEqual(found.map(\.profile.lastName), ["Παπαδόπουλος"], query)
        }
        // The father's name: as a word, and from the middle of it.
        for query in ["ιωαννης", "ΙΩΆΝΝΗΣ", "ωαννη"] {
            let found = try await store.db.searchPatients(query)
            XCTAssertEqual(found.map(\.profile.lastName), ["Παπαδόπουλος"], query)
        }
        let none = try await store.db.searchPatients("ζζζ")
        XCTAssertTrue(none.isEmpty)
        await store.close()
    }

    func testANoteIsFoundThroughItsPatientsNameWhateverTheAccents() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        let p = patient("Ελένη", "Αντωνοπούλου", amka: "33333333333")
        try await store.db.savePatient(p)
        var note = Note(title: "Follow-up", content: "no name in the text")
        note.mentionedPatients = [p.id]
        try await store.notes.save(note)
        for query in ["ελενη", "ΑΝΤΩΝΟΠΟΥΛΟΥ", "patient:αντωνοπουλου", "ελενη αντωνοπουλου"] {
            let found = try await titles(store, query)
            XCTAssertEqual(found, ["Follow-up"], query)
        }
        await store.close()
    }

    // MARK: - The migration

    private func connection(_ root: DataRoot) throws -> SQLConnection {
        try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
    }

    private func rows(_ root: DataRoot, _ sql: String) throws -> [String] {
        let conn = try connection(root)
        defer { conn.close() }
        let s = try conn.prepare(sql)
        defer { s.finalize() }
        var out: [String] = []
        while try s.step() { out.append(s.columnText(0) ?? "∅") }
        return out
    }

    private func exec(_ root: DataRoot, _ statements: [String]) throws {
        let conn = try connection(root)
        defer { conn.close() }
        for statement in statements { try conn.exec(statement) }
    }

    /// What a database from before this change looks like: the six original
    /// triggers, indexes filled with the raw text, no folding marker.
    private func makeLegacy(_ root: DataRoot, keepMarker: Bool = false) throws {
        var statements = Schema.ftsTriggerNames.map { "DROP TRIGGER IF EXISTS \($0)" }
        statements += Schema.v1.filter { $0.hasPrefix("CREATE TRIGGER IF NOT EXISTS") }
        statements += [
            "DELETE FROM notes_fts",
            "INSERT INTO notes_fts(rowid, id, title, content, tags) SELECT rowid, id, title, content, tags_json FROM notes",
            "DELETE FROM patients_fts",
            """
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
            SELECT rowid, id, first_name, last_name, first_name || ' ' || last_name, phone, email, amka, fathers_name FROM patients
            """
        ]
        if !keepMarker { statements.append("DELETE FROM migrations WHERE version = '8.0-fts-folding'") }
        try exec(root, statements)
    }

    private func seed(_ root: DataRoot) async throws {
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Visit", content: "ο ασθενής ήρθε σήμερα", tags: ["Καρδιολογία"]))
        try await store.db.savePatient(patient("Γεώργιος", "Παπαδόπουλος", fathers: "Ιωάννης"))
        await store.close()
    }

    private func triggerSQL(_ root: DataRoot) throws -> [String: String] {
        let conn = try connection(root)
        defer { conn.close() }
        let s = try conn.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'")
        defer { s.finalize() }
        var out: [String: String] = [:]
        while try s.step() { out[s.columnText(0) ?? ""] = s.columnText(1) ?? "" }
        return out
    }

    private func assertCurrentTriggers(_ root: DataRoot, file: StaticString = #filePath, line: UInt = #line) throws {
        let stored = try triggerSQL(root)
        XCTAssertEqual(Set(stored.keys), Set(Schema.ftsTriggerNames), file: file, line: line)
        for trigger in Schema.ftsTriggers {
            XCTAssertTrue(Schema.sameTriggerSQL(Schema.canonicalTriggerSQL(trigger.sql), stored[trigger.name] ?? ""),
                          "\(trigger.name) is not the current text", file: file, line: line)
        }
    }

    func testADatabaseFromBeforeIsUpgradedOnOpenAndSearchable() async throws {
        let root = try makeRoot()
        try await seed(root)
        try makeLegacy(root)
        // The precondition: the legacy index cannot find the folded word.
        XCTAssertEqual(try rows(root, "SELECT COUNT(*) FROM notes_fts WHERE notes_fts MATCH '\"ασθενησ\"'"), ["0"])
        XCTAssertNotEqual(try rows(root, "SELECT sql FROM sqlite_master WHERE name = 'notes_fts_insert'").first,
                          Schema.ftsTriggers.first { $0.name == "notes_fts_insert" }?.sql)

        let store = try AppStore.testStore(dataRoot: root)
        try assertCurrentTriggers(root)
        XCTAssertEqual(try rows(root, "SELECT version FROM migrations WHERE version = '8.0-fts-folding'"), ["8.0-fts-folding"])
        let note = try await titles(store, "ασθενης")
        XCTAssertEqual(note, ["Visit"])
        let tag = try await titles(store, "καρδιολογια")
        XCTAssertEqual(tag, ["Visit"])
        let patients = try await store.db.searchPatients("παπαδοπουλος")
        XCTAssertEqual(patients.count, 1)
        // New writes go in folded.
        try await store.notes.save(Note(title: "New", content: "ΝΈΑ ΕΞΈΤΑΣΗ"))
        let added = try await titles(store, "εξεταση")
        XCTAssertEqual(added, ["New"])
        await store.close()
    }

    func testAnUpToDateDatabaseIsNotTouchedAgain() async throws {
        let root = try makeRoot()
        try await seed(root)
        // A marker in the right place and rows nobody should rewrite.
        try exec(root, ["UPDATE notes_fts SET title = 'SENTINEL'"])
        let again = try AppStore.testStore(dataRoot: root)
        await again.close()
        XCTAssertEqual(try rows(root, "SELECT title FROM notes_fts"), ["SENTINEL"], "the open refilled an index that was already current")
    }

    func testLegacyTriggersAreReplacedEvenWhenTheMarkerIsThere() async throws {
        let root = try makeRoot()
        try await seed(root)
        try makeLegacy(root, keepMarker: true)
        let store = try AppStore.testStore(dataRoot: root)
        try assertCurrentTriggers(root)
        let found = try await titles(store, "ασθενης")
        XCTAssertEqual(found, ["Visit"])
        await store.close()
    }

    func testAnAlteredTriggerIsReplacedOnOpen() async throws {
        let root = try makeRoot()
        try await seed(root)
        try exec(root, ["DROP TRIGGER notes_fts_insert",
                        "CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN DELETE FROM notes; END"])
        let store = try AppStore.testStore(dataRoot: root)
        try assertCurrentTriggers(root)
        await store.close()
    }

    #if DEBUG
    func testAFailedUpgradeLeavesTheOldTriggersAndIndexesAndTheNextOpenRetries() async throws {
        let root = try makeRoot()
        try await seed(root)
        try makeLegacy(root)
        let before = try rows(root, "SELECT title || '|' || content FROM notes_fts")

        Database.failFTSFoldingForTesting = true
        XCTAssertThrowsError(try AppStore.testStore(dataRoot: root))
        Database.failFTSFoldingForTesting = false

        XCTAssertEqual(try rows(root, "SELECT title || '|' || content FROM notes_fts"), before, "the index was left as it was")
        let legacy = Schema.v1.first { $0.contains("notes_fts_insert") }
        XCTAssertTrue(Schema.sameTriggerSQL(
            Schema.canonicalTriggerSQL((legacy ?? "").replacingOccurrences(of: "IF NOT EXISTS ", with: "")),
            try triggerSQL(root)["notes_fts_insert"] ?? ""), "the old trigger came back")
        XCTAssertEqual(try rows(root, "SELECT COUNT(*) FROM migrations WHERE version = '8.0-fts-folding'"), ["0"])

        let store = try AppStore.testStore(dataRoot: root)
        try assertCurrentTriggers(root)
        let found = try await titles(store, "ασθενης")
        XCTAssertEqual(found, ["Visit"])
        await store.close()
    }
    #endif

    func testTheOriginalPlaintextStoreReaderLeavesTheIndexesAlone() async throws {
        let path = tempDir.appendingPathComponent("plain.db").path
        let original = try Database(path: path)
        try await original.saveNote(Note(title: "Visit", content: "ο ασθενής ήρθε"))

        func read(_ sql: String) throws -> [String] {
            let conn = try SQLConnection(path: path)
            defer { conn.close() }
            let s = try conn.prepare(sql)
            defer { s.finalize() }
            var out: [String] = []
            while try s.step() { out.append(s.columnText(0) ?? "∅") }
            return out
        }
        // Made to look like it did before this change.
        let conn = try SQLConnection(path: path)
        for name in Schema.ftsTriggerNames { try conn.exec("DROP TRIGGER IF EXISTS \(name)") }
        for statement in Schema.v1 where statement.hasPrefix("CREATE TRIGGER IF NOT EXISTS") { try conn.exec(statement) }
        try conn.exec("DELETE FROM notes_fts")
        try conn.exec("INSERT INTO notes_fts(rowid, id, title, content, tags) SELECT rowid, id, title, content, tags_json FROM notes")
        try conn.exec("DELETE FROM migrations WHERE version = '8.0-fts-folding'")
        conn.close()

        let before = try read("SELECT title || '|' || content FROM notes_fts")
        let triggersBefore = try read("SELECT sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        _ = try Database(path: path, deriveLinks: false)
        XCTAssertEqual(try read("SELECT title || '|' || content FROM notes_fts"), before)
        XCTAssertEqual(try read("SELECT sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name"), triggersBefore)
        XCTAssertEqual(try read("SELECT COUNT(*) FROM migrations WHERE version = '8.0-fts-folding'"), ["0"])
    }

    func testARestoredLegacyDatabaseIsUpgradedBeforeItServesSearches() async throws {
        let sourceRoot = try makeRoot("source")
        try await seed(sourceRoot)
        try makeLegacy(sourceRoot)

        let targetRoot = try makeRoot("target")
        let target = try AppStore.testStore(dataRoot: targetRoot)
        try await target.db.replaceDatabaseFile(
            with: sourceRoot.databaseURL.path, sourceKey: TestKeys.database(for: sourceRoot))
        try await target.db.validateExpectedSchema()
        let found = try await titles(target, "ασθενης")
        XCTAssertEqual(found, ["Visit"])
        await target.close()
        try assertCurrentTriggers(targetRoot)
    }

    func testValidationAcceptsTheCurrentTriggersAndRejectsAnythingElse() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.db.validateExpectedSchema()   // fresh database: the current triggers
        await store.close()

        try exec(root, ["CREATE TRIGGER notes_fts_extra AFTER INSERT ON notes BEGIN SELECT 1; END"])
        let reopened = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        do {
            try await reopened.validateExpectedSchema()
            XCTFail("an unknown trigger was accepted")
        } catch {}
    }

    func testARebuildKeepsTheIndexesFolded() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "Visit", content: "ο ασθενής ήρθε"))
        try await store.db.savePatient(patient("Γεώργιος", "Παπαδόπουλος"))
        _ = try await store.db.rebuildIndexes()
        let found = try await titles(store, "ασθενης")
        XCTAssertEqual(found, ["Visit"])
        let patients = try await store.db.searchPatients("παπαδοπουλος")
        XCTAssertEqual(patients.count, 1)
        await store.close()
    }

    // MARK: - Filters that run in Swift

    @MainActor
    func testTheQuickSwitcherFindsATodoWhateverItsAccents() async throws {
        let defaults = TestDefaults.suite("MedNotesTests.GreekSearch")
        defer { TestDefaults.clear("MedNotesTests.GreekSearch") }
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let store = try XCTUnwrap(session.store)
        try await store.todos.save(TodoItem(title: "Έλεγχος πίεσης"))
        session.switcherText = "ελεγχος"
        let found = Date().addingTimeInterval(5)
        while !session.switcherResults.contains(where: { $0.kind == .todo }), Date() < found {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.switcherResults.contains { $0.kind == .todo && $0.title == "Έλεγχος πίεσης" },
                      "got \(session.switcherResults.map(\.title))")
    }
}
