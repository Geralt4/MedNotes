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

    /// The six triggers as `Schema.v1` creates them (SQLite stores them without `IF NOT EXISTS`).
    private var originalTriggers: [(name: String, sql: String)] {
        Schema.v1.compactMap { statement in
            let prefix = "CREATE TRIGGER IF NOT EXISTS "
            guard statement.hasPrefix(prefix) else { return nil }
            let name = String(statement.dropFirst(prefix.count).prefix { !$0.isWhitespace })
            return (name, "CREATE TRIGGER " + statement.dropFirst(prefix.count))
        }
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

    func testTextSpelledWithOxiaIsFoundByAnyOfTheForms() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "Oxia", content: "α\u{03B3}\u{03C9}\u{03BD}\u{1F7B}"))   // ends in ύ spelled with oxia
        try await store.notes.save(Note(title: "Oxia word", content: "\u{03B1}\u{03BB}\u{03B3}\u{03BF}\u{03C2}\u{0020}\u{03C0}\u{03BF}\u{03BD}\u{1F79}\u{03C2}"))   // πονός-like, ό as oxia
        let one = try await titles(store, "αγωνυ")
        XCTAssertEqual(one, ["Oxia"])
        let two = try await titles(store, "πονοσ")
        XCTAssertEqual(two, ["Oxia word"], "oxia ό is the same letter as tonos ό")
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
            XCTAssertTrue(Schema.triggerIsExactly(stored[trigger.name], trigger.sql),
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
    /// A failed refold no longer keeps the store shut: the old triggers and
    /// indexes stay, the store opens, it knows search needs rebuilding, and
    /// Rebuild Indexes (or the next open) puts it right.
    func testAFailedUpgradeLeavesTheOldTriggersAndIndexesTheStoreOpensAndRebuildRepairsIt() async throws {
        let root = try makeRoot()
        try await seed(root)
        try makeLegacy(root)
        let before = try rows(root, "SELECT title || '|' || content FROM notes_fts")

        Database.failFTSFoldingForTesting = true
        let store = try AppStore.testStore(dataRoot: root)
        Database.failFTSFoldingForTesting = false

        let needs = await store.db.searchIndexNeedsRebuild
        XCTAssertTrue(needs, "the store should know its search index was not refolded")
        XCTAssertEqual(try rows(root, "SELECT title || '|' || content FROM notes_fts"), before, "the index was left as it was")
        let legacy = originalTriggers.first { $0.name == "notes_fts_insert" }?.sql
        XCTAssertTrue(Schema.triggerIsExactly(try triggerSQL(root)["notes_fts_insert"], legacy ?? ""), "the old trigger is still there")
        XCTAssertEqual(try rows(root, "SELECT COUNT(*) FROM migrations WHERE version = '8.0-fts-folding'"), ["0"])
        let missed = try await titles(store, "ασθενης")
        XCTAssertTrue(missed.isEmpty, "until it is rebuilt an accentless word still misses")

        let report = try await store.db.rebuildIndexes()
        XCTAssertTrue(report.passed)
        let after = await store.db.searchIndexNeedsRebuild
        XCTAssertFalse(after)
        try assertCurrentTriggers(root)
        let found = try await titles(store, "ασθενης")
        XCTAssertEqual(found, ["Visit"])
        await store.close()
    }

    func testTheNextOpenRetriesAFailedRefold() async throws {
        let root = try makeRoot()
        try await seed(root)
        try makeLegacy(root)
        Database.failFTSFoldingForTesting = true
        let first = try AppStore.testStore(dataRoot: root)
        Database.failFTSFoldingForTesting = false
        await first.close()
        let second = try AppStore.testStore(dataRoot: root)
        let needs = await second.db.searchIndexNeedsRebuild
        XCTAssertFalse(needs)
        try assertCurrentTriggers(root)
        await second.close()
    }

    @MainActor
    func testTheSessionSaysSearchNeedsRebuildingAndClearsItAfterARebuild() async throws {
        let defaults = TestDefaults.suite("MedNotesTests.GreekRebuild")
        defer { TestDefaults.clear("MedNotesTests.GreekRebuild") }
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        try await seed(root)
        try makeLegacy(root)
        Database.failFTSFoldingForTesting = true
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Database.failFTSFoldingForTesting = false
        XCTAssertTrue(session.isReady)
        let warned = Date().addingTimeInterval(5)
        while session.integrityWarning != AppSession.searchRebuildWarning, Date() < warned {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(session.integrityWarning, AppSession.searchRebuildWarning)
        let outcome = await session.rebuildIndexes()
        XCTAssertTrue(outcome.passed)
        XCTAssertNil(session.integrityWarning)
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

    // MARK: - Untrusted snapshots are checked before they are migrated (M2)

    func testAPlantedTriggerIsRejectedBeforeAnythingMigratesTheSnapshot() async throws {
        let root = try makeRoot()
        try await seed(root)
        // An older file: the markers a migration would write are missing, and a
        // trigger waits on the table it writes to.
        try exec(root, [
            "DELETE FROM migrations WHERE version IN ('7.0-app-state', '8.0-fts-folding')",
            """
            CREATE TRIGGER planted AFTER INSERT ON migrations BEGIN
                INSERT OR REPLACE INTO app_state(key, value_json, updated_at) VALUES ('planted', '1', 'x');
            END
            """
        ])
        XCTAssertThrowsError(try Database.validateSnapshotFile(path: root.databaseURL.path, key: TestKeys.database(for: root)))
        XCTAssertEqual(try rows(root, "SELECT COUNT(*) FROM app_state WHERE key = 'planted'"), ["0"], "the planted trigger ran")
        XCTAssertEqual(try rows(root, "SELECT COUNT(*) FROM migrations WHERE version = '8.0-fts-folding'"), ["0"],
                       "the file was migrated before it was judged")
    }

    func testViewsAndTriggersOnTheWrongTableAreRejectedBeforeMigration() async throws {
        let root = try makeRoot()
        try await seed(root)
        let key = TestKeys.database(for: root)
        try exec(root, ["CREATE VIEW sneaky AS SELECT id FROM notes"])
        XCTAssertThrowsError(try Database.validateSnapshotFile(path: root.databaseURL.path, key: key))
        try exec(root, ["DROP VIEW sneaky",
                        "CREATE TRIGGER notes_fts_extra AFTER INSERT ON notes BEGIN SELECT 1; END"])
        XCTAssertThrowsError(try Database.validateSnapshotFile(path: root.databaseURL.path, key: key), "an unknown name")
        try exec(root, ["DROP TRIGGER notes_fts_extra",
                        "DROP TRIGGER notes_fts_delete",
                        "CREATE TRIGGER notes_fts_delete AFTER DELETE ON migrations BEGIN SELECT 1; END"])
        XCTAssertThrowsError(try Database.validateSnapshotFile(path: root.databaseURL.path, key: key),
                             "a full-text name on a table the migration writes to")
    }

    /// A known name on its own table passes the early check (the migration
    /// writes nothing to those tables and replaces all six), and the exact-text
    /// check after the migration is what catches a changed body.
    func testAnAlteredBodyPassesTheEarlyCheckAndIsReplacedByTheMigration() async throws {
        let root = try makeRoot()
        try await seed(root)
        try exec(root, ["DROP TRIGGER notes_fts_update", forgedUpdateTrigger(with: "\u{00A0}")])
        try Database.validateSnapshotFile(path: root.databaseURL.path, key: TestKeys.database(for: root))
        let opened = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        try assertCurrentTriggers(root)
        try await opened.validateExpectedSchema()
    }

    func testEverySpellingAnOlderBuildWroteIsAccepted() async throws {
        let current = try makeRoot("current")
        try await seed(current)
        try Database.validateSnapshotFile(path: current.databaseURL.path, key: TestKeys.database(for: current))
        let original = try makeRoot("original")
        try await seed(original)
        try makeLegacy(original)
        try Database.validateSnapshotFile(path: original.databaseURL.path, key: TestKeys.database(for: original))
        // The patients triggers the old father's-name migration wrote.
        let copied = try makeRoot("copied")
        try await seed(copied)
        try exec(copied, ["DROP TRIGGER patients_fts_insert", "DROP TRIGGER patients_fts_delete", "DROP TRIGGER patients_fts_update"]
                 + Schema.migrationCopyPatientTriggers.map(\.sql))
        try Database.validateSnapshotFile(path: copied.databaseURL.path, key: TestKeys.database(for: copied))
    }

    #if DEBUG
    /// The wiring: a restore rejects the snapshot before any `Database` is
    /// opened on it (which would migrate it), and leaves the target alone.
    func testARestoreJudgesTheSnapshotBeforeItIsMigrated() async throws {
        let sourceRoot = try makeRoot("source")
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        try await source.notes.save(Note(title: "From the backup", content: "x"))
        try exec(sourceRoot, ["""
            CREATE TRIGGER planted AFTER INSERT ON migrations BEGIN
                INSERT OR REPLACE INTO app_state(key, value_json, updated_at) VALUES ('planted', '1', 'x');
            END
            """])
        let file = tempDir.appendingPathComponent("planted.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(name: "planted", to: file, passphrase: "a long enough passphrase")
        await source.close()

        let targetRoot = try makeRoot("target")
        let target = try AppStore.testStore(dataRoot: targetRoot)
        try await target.notes.save(Note(title: "Already here", content: "y"))
        Database.eventsForTesting = []
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
                databaseKey: TestKeys.database(for: targetRoot), attachmentKey: TestKeys.attachment(for: targetRoot),
                createRestorePoint: false)
            XCTFail("a snapshot with a planted trigger was restored")
        } catch {}
        XCTAssertEqual(Database.eventsForTesting, ["validate"],
                       "the snapshot must be judged first, and nothing may open (migrate) it afterwards")
        let kept = try await target.notes.loadAll().map(\.title)
        XCTAssertEqual(kept, ["Already here"])
        await target.close()
    }

    func testAPlaintextSnapshotInsideAnArchiveIsJudgedBeforeItIsMigrated() async throws {
        let path = tempDir.appendingPathComponent("plaintext-snapshot.db").path
        let plain = try Database(path: path)
        try await plain.saveNote(Note(title: "Visit", content: "x"))
        await plain.close()
        let conn = try SQLConnection(path: path)
        try conn.exec("CREATE TRIGGER planted AFTER INSERT ON migrations BEGIN SELECT 1; END")
        conn.close()
        Database.eventsForTesting = []
        do {
            try await ArchiveExtraction.ensureEncryptedSnapshot(at: URL(fileURLWithPath: path), key: Data(repeating: 7, count: 32))
            XCTFail("a plaintext snapshot with a planted trigger was converted")
        } catch {}
        XCTAssertEqual(Database.eventsForTesting, ["validate"])
    }
    #endif

    // MARK: - Altered triggers (the security review's H1)

    /// What a lookalike space does: SQLite reads these characters as part of a
    /// name, so `title,<space>content` names a column that does not exist and the
    /// trigger quietly never fires for body edits.
    private static let lookalikeSpaces: [String] = ["\u{00A0}", "\u{2028}", "\u{3000}", " \u{0301}", "\u{2003}"]

    private func forgedUpdateTrigger(with variant: String) -> String {
        let expected = Schema.ftsTriggers.first { $0.name == "notes_fts_update" }!.sql
        return expected.replacingOccurrences(of: "title, content", with: "title,\(variant)content")
    }

    func testAnAlteredTriggerWithALookalikeSpaceIsRejectedByValidationAndReplacedOnOpen() async throws {
        var planted = 0
        for variant in Self.lookalikeSpaces {
            let root = try makeRoot("variant-\(planted)-\(UUID().uuidString.prefix(4))")
            try await seed(root)
            let live = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
            let forged = forgedUpdateTrigger(with: variant)
            XCTAssertFalse(Schema.triggerIsExactly(forged, Schema.ftsTriggers.first { $0.name == "notes_fts_update" }!.sql))
            do {
                try exec(root, ["DROP TRIGGER notes_fts_update", forged])
            } catch {
                continue   // SQLite refused this spelling at CREATE time: nothing to plant
            }
            planted += 1
            do {
                try await live.validateExpectedSchema()
                XCTFail("a trigger with \(variant.unicodeScalars.map { String($0.value, radix: 16) }) was accepted")
            } catch {}
            let reopened = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
            try assertCurrentTriggers(root)
            try await reopened.validateExpectedSchema()
        }
        XCTAssertGreaterThan(planted, 0, "SQLite accepted none of the spellings, so the test checked nothing")
    }

    func testARebuildPutsTheTriggersBack() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Visit", content: "ασθενής"))
        try exec(root, ["DROP TRIGGER notes_fts_update", forgedUpdateTrigger(with: "\u{00A0}")])
        _ = try await store.db.rebuildIndexes()
        try assertCurrentTriggers(root)
        // An edit of the body now reaches the index again.
        let all = try await store.notes.list(search: "", tagKey: nil)
        var note = try XCTUnwrap(all.first)
        note.content = "δύσπνοια"
        try await store.notes.save(note)
        let found = try await titles(store, "δυσπνοια")
        XCTAssertEqual(found, ["Visit"])
        await store.close()
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
