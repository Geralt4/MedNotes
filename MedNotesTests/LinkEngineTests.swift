import XCTest
@testable import MedNotes

/// The stored wiki-link edges: what `LinkIndex` derives from note text, and
/// how it keeps resolving as notes and patients come, change and go.
final class LinkEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRoot() throws -> DataRoot {
        try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
    }

    // MARK: - Reading the tables

    private struct Row: Equatable {
        let source: String
        let ordinal: Int
        let target: String
        let state: String
        let kind: String?
        let dst: String?
    }

    /// The stored link rows, read through a second connection.
    private func rows(_ root: DataRoot) throws -> [Row] {
        let conn = try SQLConnection(
            path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        return try readRows(conn)
    }

    private func readRows(_ conn: SQLConnection) throws -> [Row] {
        let s = try conn.prepare("""
            SELECT src_note_id, ordinal, raw_target, state, dst_kind, dst_id
            FROM wikilinks ORDER BY src_note_id, ordinal
            """)
        var out: [Row] = []
        while try s.step() {
            out.append(Row(
                source: s.columnText(0) ?? "", ordinal: s.columnInt(1) ?? -1,
                target: s.columnText(2) ?? "", state: s.columnText(3) ?? "",
                kind: s.columnText(4), dst: s.columnText(5)))
        }
        s.finalize()
        return out
    }

    private func rows(for note: Note, in root: DataRoot) throws -> [Row] {
        try rows(root).filter { $0.source == note.id.uuidString }
    }

    private func patient(_ first: String, _ last: String, amka: String) -> Patient {
        var profile = PatientProfile(
            firstName: first, lastName: last, dateOfBirth: Date(timeIntervalSince1970: 0))
        profile.amka = amka
        return Patient(profile: profile)
    }

    // MARK: - Storage

    func testAnUnresolvedLinkIsStoredAndSurvivesAReopen() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let note = Note(title: "Round", content: "see [[Nobody Here]] and [[#Plan]]")
        try await store.notes.save(note)

        let first = try rows(for: note, in: root)
        XCTAssertEqual(first.map(\.target), ["Nobody Here", ""])
        XCTAssertEqual(first.map(\.state), ["unresolved", "resolved"])
        XCTAssertEqual(first[1].dst, note.id.uuidString, "a link to a heading of the note itself")
        await store.close()

        let reopened = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try rows(for: note, in: root), first,
                       "the every-open sweep must not remove unresolved links")
        await reopened.close()
    }

    func testEveryOccurrenceIsItsOwnRow() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "A", content: "")
        let source = Note(title: "S", content: "[[A]] then [[A|again]] then [[A#Plan]]")
        try await store.notes.save(target)
        try await store.notes.save(source)

        let stored = try rows(for: source, in: root)
        XCTAssertEqual(stored.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(Set(stored.compactMap(\.dst)), [target.id.uuidString])
        let backlinks = try await store.linking.backlinks(noteId: target.id)
        XCTAssertEqual(backlinks.map(\.noteId), [source.id], "one backlink, however many occurrences")
        let out = try await store.linking.linksFrom(noteId: source.id)
        XCTAssertEqual(out.count, 1)
        await store.close()
    }

    func testEditingAwayALinkRemovesItsRow() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var note = Note(title: "S", content: "[[A]] [[B]]")
        try await store.notes.save(note)
        XCTAssertEqual(try rows(for: note, in: root).count, 2)
        note.content = "[[B]]"
        try await store.notes.save(note)
        XCTAssertEqual(try rows(for: note, in: root).map(\.target), ["B"])
        await store.close()
    }

    // MARK: - Resolution over time

    func testAForwardLinkResolvesWhenItsTargetIsCreated() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let source = Note(title: "S", content: "plan: [[Insulin Protocol]]")
        try await store.notes.save(source)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state), ["unresolved"])

        let target = Note(title: "Insulin Protocol", content: "")
        try await store.notes.save(target)
        let after = try rows(for: source, in: root)
        XCTAssertEqual(after.map(\.state), ["resolved"])
        XCTAssertEqual(after[0].dst, target.id.uuidString)
        await store.close()
    }

    func testRenamingATargetUnresolvesOldLinksAndResolvesNewOnes() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var target = Note(title: "Old name", content: "")
        let byOld = Note(title: "S1", content: "[[Old name]]")
        let byNew = Note(title: "S2", content: "[[New name]]")
        try await store.notes.save(target)
        try await store.notes.save(byOld)
        try await store.notes.save(byNew)
        XCTAssertEqual(try rows(for: byOld, in: root).map(\.state), ["resolved"])
        XCTAssertEqual(try rows(for: byNew, in: root).map(\.state), ["unresolved"])

        target.title = "New name"
        try await store.notes.save(target)
        XCTAssertEqual(try rows(for: byOld, in: root).map(\.state), ["unresolved"],
                       "the text still says Old name")
        XCTAssertEqual(try rows(for: byNew, in: root).map(\.state), ["resolved"])

        target.title = "Old name"
        try await store.notes.save(target)
        XCTAssertEqual(try rows(for: byOld, in: root).map(\.state), ["resolved"])
        XCTAssertEqual(try rows(for: byNew, in: root).map(\.state), ["unresolved"])
        await store.close()
    }

    func testDeletingATargetLeavesTheLinkInTheNoteUnresolved() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Protocol", content: "")
        let source = Note(title: "S", content: "[[Protocol]]")
        try await store.notes.save(target)
        try await store.notes.save(source)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state), ["resolved"])

        try await store.notes.delete(id: target.id)
        let after = try rows(for: source, in: root)
        XCTAssertEqual(after.map(\.state), ["unresolved"])
        XCTAssertNil(after[0].dst)
        let violations = try await store.foreignKeyViolations()
        XCTAssertEqual(violations, 0)
        await store.close()
    }

    func testDeletingASourceRemovesItsRows() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let source = Note(title: "S", content: "[[A]]")
        try await store.notes.save(source)
        try await store.notes.delete(id: source.id)
        XCTAssertEqual(try rows(root), [])
        await store.close()
    }

    func testANewDuplicateTitleDoesNotBreakAWorkingLinkButMakesNewOnesAmbiguous() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let first = Note(title: "Plan", content: "first")
        let working = Note(title: "Old note", content: "[[Plan]]")
        try await store.notes.save(first)
        try await store.notes.save(working)
        XCTAssertEqual(try rows(for: working, in: root)[0].dst, first.id.uuidString)

        let second = Note(title: "Plan", content: "second")
        try await store.notes.save(second)
        XCTAssertEqual(try rows(for: working, in: root)[0].dst, first.id.uuidString,
                       "a working link keeps its destination")

        let fresh = Note(title: "New note", content: "[[Plan]]")
        try await store.notes.save(fresh)
        let ambiguous = try rows(for: fresh, in: root)
        XCTAssertEqual(ambiguous.map(\.state), ["ambiguous"])
        XCTAssertNil(ambiguous[0].dst)

        try await store.notes.delete(id: second.id)
        let settled = try rows(for: fresh, in: root)
        XCTAssertEqual(settled.map(\.state), ["resolved"], "one candidate is left")
        XCTAssertEqual(settled[0].dst, first.id.uuidString)
        await store.close()
    }

    func testTitlesContainingHashAndPipeResolveAsWholeTitles() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let hash = Note(title: "Plan #2", content: "")
        let pipe = Note(title: "A | B", content: "")
        let source = Note(title: "S", content: "[[Plan #2]] [[A | B]] [[Plan]]")
        try await store.notes.save(hash)
        try await store.notes.save(pipe)
        try await store.notes.save(source)
        let stored = try rows(for: source, in: root)
        XCTAssertEqual(stored.map(\.state), ["resolved", "resolved", "unresolved"])
        XCTAssertEqual(stored[0].dst, hash.id.uuidString)
        XCTAssertEqual(stored[1].dst, pipe.id.uuidString)
        await store.close()
    }

    func testAnUntitledNoteIsNothingALinkCanName() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let blank = Note(title: "", content: "")
        let spaces = Note(title: "   ", content: "")
        let source = Note(title: "S", content: "[[Untitled]] [[Χωρίς τίτλο]]")
        try await store.notes.save(blank)
        try await store.notes.save(spaces)
        try await store.notes.save(source)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state), ["unresolved", "unresolved"])
        await store.close()
    }

    func testGreekLinksMatchAcrossCaseAccentsAndFinalSigma() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Καλός Γιατρός", content: "")
        let source = Note(title: "S", content: "[[ΚΑΛΟΣ ΓΙΑΤΡΟΣ]] και [[καλοσ γιατροσ]]")
        try await store.notes.save(target)
        try await store.notes.save(source)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state), ["resolved", "resolved"])
        await store.close()
    }

    // MARK: - Patients

    func testPatientsResolveByEitherNameOrderAndFollowRenamesAndDeletion() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let source = Note(title: "S", content: "[[Maria Papadopoulou]] [[Papadopoulou Maria]] [[Elena Nikou]]")
        try await store.notes.save(source)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state),
                       ["unresolved", "unresolved", "unresolved"])

        var maria = patient("Maria", "Papadopoulou", amka: "70000000001")
        try await store.patients.save(maria)
        let resolved = try rows(for: source, in: root)
        XCTAssertEqual(resolved.map(\.state), ["resolved", "resolved", "unresolved"])
        XCTAssertEqual(resolved[0].kind, "patient")
        XCTAssertEqual(resolved[1].dst, maria.id.uuidString)

        maria.profile.firstName = "Elena"
        maria.profile.lastName = "Nikou"
        try await store.patients.save(maria)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state),
                       ["unresolved", "unresolved", "resolved"])

        try await store.patients.delete(id: maria.id)
        XCTAssertEqual(try rows(for: source, in: root).map(\.state),
                       ["unresolved", "unresolved", "unresolved"])
        let violations = try await store.foreignKeyViolations()
        XCTAssertEqual(violations, 0)
        await store.close()
    }

    func testANoteTitleWinsOverAPatientName() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let maria = patient("Maria", "Papadopoulou", amka: "70000000001")
        let titled = Note(title: "Maria Papadopoulou", content: "")
        let source = Note(title: "S", content: "[[Maria Papadopoulou]]")
        try await store.patients.save(maria)
        try await store.notes.save(titled)
        try await store.notes.save(source)
        let stored = try rows(for: source, in: root)
        XCTAssertEqual(stored[0].kind, "note")
        XCTAssertEqual(stored[0].dst, titled.id.uuidString)
        await store.close()
    }

    // MARK: - Opening, upgrading, importing

    func testAStaleNoteIsRepairedWhenTheStoreIsOpened() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Protocol", content: "")
        var source = Note(title: "S", content: "[[Protocol]]")
        try await store.notes.save(target)
        try await store.notes.save(source)

        // A save whose relink never ran: the text changed, the rows did not.
        source.content = "[[Protocol]] and [[Other]]"
        try await store.db.saveNote(source)
        XCTAssertEqual(try rows(for: source, in: root).count, 1)
        await store.close()

        let reopened = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try rows(for: source, in: root).map(\.target), ["Protocol", "Other"])
        await reopened.close()
    }

    func testImportedNotesGetLinksIncludingForwardLinksWithinTheBatch() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let first = Note(title: "First", content: "see [[Second]]")
        let second = Note(title: "Second", content: "back to [[First]]")
        try await store.db.importBatch(patients: [], notes: [first, second], todos: [], events: [])
        XCTAssertEqual(try rows(for: first, in: root).first?.dst, second.id.uuidString)
        XCTAssertEqual(try rows(for: second, in: root).first?.dst, first.id.uuidString)
        await store.close()
    }

    func testAReaderOpenedWithoutDerivingWritesNoLinkRows() async throws {
        let path = tempDir.appendingPathComponent("plain.db").path
        let writer = try Database(path: path)
        try await writer.saveNote(Note(title: "S", content: "[[A]]"))
        await writer.close()

        let reader = try Database(path: path, deriveLinks: false)
        await reader.close()
        let plain = try SQLConnection(path: path)
        defer { plain.close() }
        XCTAssertEqual(try readRows(plain), [], "a read-only open must not write link rows")
        for table in ["link_sources", "note_headings", "note_blocks", "note_tags", "note_aliases", "note_properties"] {
            let count = try plain.prepare("SELECT COUNT(*) FROM \(table)")
            XCTAssertTrue(try count.step())
            XCTAssertEqual(count.columnInt(0), 0, "\(table) must stay empty in a store opened only to read it")
            count.finalize()
        }

        let owner = try Database(path: path)
        await owner.close()
        let after = try SQLConnection(path: path)
        defer { after.close() }
        XCTAssertEqual(try readRows(after).map(\.target), ["A"])
    }

    /// A store from before the link tables: older edges in `note_links`, no
    /// `wikilinks`, no marker. Opening it derives the new rows and records
    /// counts only.
    func testOpeningAStoreFromBeforeTheLinkTablesDerivesLinksAndRecordsCounts() async throws {
        let root = try makeRoot()
        var store: AppStore? = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Ward Rounds", content: "")
        let source = Note(title: "S", content: "[[Ward]] and [[Ward Rounds]]")
        try await store!.notes.save(target)
        try await store!.notes.save(source)
        await store!.close()
        store = nil

        let side = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        for statement in [
            "DROP TABLE wikilinks", "DROP TABLE link_sources",
            "DELETE FROM migrations WHERE version LIKE '5.%'",
            "DELETE FROM audit_logs",
        ] { try side.exec(statement) }
        // The older engine resolved "Ward" to "Ward Rounds" by partial match.
        let legacy = try side.prepare("""
            INSERT INTO note_links (id, src_note_id, dst_note_id, dst_patient_id, anchor_text)
            VALUES ('legacy-1', ?, ?, NULL, 'Ward')
            """)
        legacy.bind(1, source.id.uuidString)
        legacy.bind(2, target.id.uuidString)
        _ = try legacy.step()
        legacy.finalize()
        side.close()

        let reopened = try AppStore.testStore(dataRoot: root)
        let stored = try rows(for: source, in: root)
        XCTAssertEqual(stored.map(\.state), ["unresolved", "resolved"],
                       "the partial-title link no longer resolves")

        let log = try await reopened.audit.recentLogs(limit: 20).filter { $0.action == "links_rebuilt" }
        XCTAssertEqual(log.count, 1)
        let details = try XCTUnwrap(log.first).details
        XCTAssertTrue(details.contains("earlier=1"), details)
        XCTAssertTrue(details.contains("unresolvedNow=1"), details)
        XCTAssertFalse(details.contains("Ward"), "audit details carry counts, never link text")
        await reopened.close()

        // Opened again: nothing further is recorded.
        let again = try AppStore.testStore(dataRoot: root)
        let afterLog = try await again.audit.recentLogs(limit: 20).filter { $0.action == "links_rebuilt" }
        XCTAssertEqual(afterLog.count, 1)
        await again.close()
    }

    func testAFreshStoreRecordsNoLinkRebuild() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let log = try await store.audit.recentLogs(limit: 20)
        XCTAssertTrue(log.filter { $0.action == "links_rebuilt" }.isEmpty)
        await store.close()
    }

    func testConcurrentSavesOfOneNoteLeaveRowsThatMatchTheStoredText() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let base = Note(title: "S", content: "[[T0]]")
        try await store.notes.save(base)

        var saved = 0
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<16 {
                group.addTask {
                    var note = base
                    note.content = (0...(i % 4)).map { "[[T\($0)]]" }.joined(separator: " ")
                    return (try? await store.notes.save(note)) != nil
                }
            }
            for await ok in group where ok { saved += 1 }
        }
        // If every save failed the stored text would stay `[[T0]]` and the
        // comparison below would hold without testing anything.
        XCTAssertEqual(saved, 16, "every concurrent save goes through")

        let loaded = try await store.notes.load(id: base.id)
        let stored = try XCTUnwrap(loaded)
        let expected = WikiLinkParser.scan(stored.content).links.map(\.target)
        XCTAssertEqual(try rows(for: base, in: root).map(\.target), expected,
                       "the rows are those of the text that is stored, whatever order the saves ran in")
        await store.close()
    }

    func testARestoredBackupCarriesItsLinks() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Protocol", content: "")
        let source = Note(title: "S", content: "[[Protocol]] and [[Missing]]")
        try await store.notes.save(target)
        try await store.notes.save(source)
        let file = tempDir.appendingPathComponent("links.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "links", to: file, passphrase: "a long enough passphrase")

        let second = try DataRoot(rootURL: tempDir.appendingPathComponent("second", isDirectory: true))
        let target2 = try AppStore.testStore(dataRoot: second)
        _ = try await target2.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: second),
            attachmentKey: TestKeys.attachment(for: second),
            createRestorePoint: false)
        let restored = try rows(for: source, in: second)
        XCTAssertEqual(restored.map(\.state), ["resolved", "unresolved"])
        let backlinks = try await target2.linking.backlinks(noteId: target.id)
        XCTAssertEqual(backlinks.map(\.noteId), [source.id])
        await target2.close()
        await store.close()
    }

    /// A backup taken by a build that had no link tables: the archive holds
    /// notes only. Restoring it in a running session derives the links in the
    /// restored file, with no relaunch.
    func testRestoringABackupMadeBeforeTheLinkTablesDerivesThem() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Protocol", content: "")
        let source = Note(title: "S", content: "[[Protocol]] and [[Missing]]")
        try await store.notes.save(target)
        try await store.notes.save(source)
        // The store as an older build left it: no link tables in the snapshot.
        let side = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        try side.exec("DROP TABLE wikilinks")
        try side.exec("DROP TABLE link_sources")
        try side.exec("DELETE FROM migrations WHERE version LIKE '5.%'")
        side.close()
        let file = tempDir.appendingPathComponent("old.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "old", to: file, passphrase: "a long enough passphrase")
        await store.close()

        let second = try DataRoot(rootURL: tempDir.appendingPathComponent("second", isDirectory: true))
        let running = try AppStore.testStore(dataRoot: second)
        _ = try await running.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: second),
            attachmentKey: TestKeys.attachment(for: second),
            createRestorePoint: false)
        XCTAssertEqual(try rows(for: source, in: second).map(\.state), ["resolved", "unresolved"])
        let backlinks = try await running.linking.backlinks(noteId: target.id)
        XCTAssertEqual(backlinks.map(\.noteId), [source.id], "the running store sees them without a relaunch")
        await running.close()
    }

    func testMigratingAPlaintextStoreCarriesLinksIntoTheEncryptedOne() async throws {
        let root = try makeRoot()
        let plaintext = try Database(path: root.databaseURL.path)
        let target = Note(title: "Protocol", content: "body")
        let source = Note(title: "S", content: "see [[Protocol]] and [[Nobody]]")
        try await plaintext.saveNote(target)
        try await plaintext.saveNote(source)
        await plaintext.close()

        let backupURL = tempDir.appendingPathComponent("pre-migration.mednotesbackup")
        let keyManager = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keyManager)
        let backupService = BackupService(
            db: try Database(path: root.databaseURL.path),
            fileStore: nil, restorePointsRoot: root.restorePointsURL)
        _ = try await backupService.createEncryptedBackup(
            name: "Pre-encryption", to: backupURL, passphrase: "a long enough passphrase")
        _ = try await migrator.migrate(
            backupDestination: backupURL, passphrase: "a long enough passphrase")
        try await migrator.finishCleanup()

        let rootKey = try XCTUnwrap(keyManager.rootKey())
        let databaseKey = try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.database)
        let conn = try SQLConnection(path: root.databaseURL.path, key: databaseKey)
        defer { conn.close() }
        let migrated = try readRows(conn).filter { $0.source == source.id.uuidString }
        XCTAssertEqual(migrated.map(\.state), ["resolved", "unresolved"])
        XCTAssertEqual(migrated[0].dst, target.id.uuidString)
    }

    // MARK: - Queries

    func testOutgoingLinksListEachDestinationOnceAndSayWhyOthersLeadNowhere() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let a = Note(title: "A", content: "")
        let dup1 = Note(title: "Dup", content: "one")
        let dup2 = Note(title: "Dup", content: "two")
        let maria = patient("Maria", "Papadopoulou", amka: "70000000001")
        let source = Note(title: "S", content: """
            [[A]] [[A|again]] [[Dup]] [[Missing]] [[Missing]] [[Maria Papadopoulou]] [[#Heading]] ![[scan.png]]
            """)
        for note in [a, dup1, dup2] { try await store.notes.save(note) }
        try await store.patients.save(maria)
        try await store.notes.save(source)

        let links = try await store.linking.outgoingLinks(noteId: source.id)
        XCTAssertEqual(links.map(\.kind), [.note, .ambiguous, .unresolved, .patient, .unresolved])
        XCTAssertEqual(links[0].targetID, a.id)
        XCTAssertEqual(links[3].targetID, maria.id)
        XCTAssertTrue(links[2].canCreateNote)
        XCTAssertFalse(links[1].canCreateNote, "several notes share the title: creating one would make three")
        XCTAssertFalse(links[4].canCreateNote, "scan.png names a file")
        XCTAssertTrue(links[4].isEmbed)
        await store.close()
    }

    func testNamesAFile() {
        XCTAssertTrue(LinkingService.namesAFile("scan.png"))
        XCTAssertTrue(LinkingService.namesAFile("Report 2026.PDF"))
        XCTAssertFalse(LinkingService.namesAFile("Dr. Smith"))
        XCTAssertFalse(LinkingService.namesAFile("Plan v2.1"))
        XCTAssertFalse(LinkingService.namesAFile(".png"))
        XCTAssertFalse(LinkingService.namesAFile("Ward Rounds"))
    }

    func testUnlinkedMentionsFindPlainTextAndSkipLinksCodeAndPartialWords() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "Insulin protocol", content: "Insulin protocol is named here too")
        let plain = Note(title: "Plain", content: "start the insulin protocol today")
        let loud = Note(title: "Loud", content: "INSULIN   PROTOCOL.")
        let linked = Note(title: "Linked", content: "see [[Insulin protocol]]")
        let aliased = Note(title: "Aliased", content: "see [[Insulin protocol|the protocol]] and insulin protocol")
        let code = Note(title: "Code", content: "`insulin protocol`\n\n```\ninsulin protocol\n```")
        let comment = Note(title: "Comment", content: "%% insulin protocol %%")
        let partial = Note(title: "Partial", content: "insulin protocols and preinsulin protocol")
        let short = Note(title: "ab", content: "ab ab ab")
        for note in [target, plain, loud, linked, aliased, code, comment, partial, short] {
            try await store.notes.save(note)
        }

        let found = try await store.linking.unlinkedMentions(noteId: target.id)
        XCTAssertEqual(Set(found.map(\.noteId)), [plain.id, loud.id])
        let none = try await store.linking.unlinkedMentions(noteId: short.id)
        XCTAssertTrue(none.isEmpty, "a title under three characters matches too much to be useful")
        await store.close()
    }

    func testLinkStatsCountOrphansDeadEndsAndDegree() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let maria = patient("Maria", "Papadopoulou", amka: "70000000001")
        let a = Note(title: "A", content: "[[B]]")
        let b = Note(title: "B", content: "")
        let c = Note(title: "C", content: "alone")
        let d = Note(title: "D", content: "[[Maria Papadopoulou]]")
        let e = Note(title: "E", content: "[[E]] only itself")
        try await store.patients.save(maria)
        for note in [b, a, c, d, e] { try await store.notes.save(note) }

        let stats = try await store.linking.linkStats()
        XCTAssertEqual(Set(stats.orphans), [c.id, e.id])
        XCTAssertEqual(Set(stats.deadEnds), [b.id, c.id, e.id])
        XCTAssertEqual(stats.degree[a.id], 1)
        XCTAssertEqual(stats.degree[b.id], 1)
        XCTAssertEqual(stats.degree[d.id], 1)
        XCTAssertEqual(stats.degree[e.id], 0)
        await store.close()
    }

    func testTheLinkTablesCanBeDroppedWithoutLosingAnyNote() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let target = Note(title: "T", content: "body")
        let source = Note(title: "S", content: "[[T]]")
        try await store.notes.save(target)
        try await store.notes.save(source)
        let before = try rows(root)
        await store.close()

        let side = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        try side.exec("DELETE FROM wikilinks")
        try side.exec("DELETE FROM link_sources")
        side.close()

        let reopened = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try rows(root), before, "the index is rebuilt from the notes")
        let notes = try await reopened.notes.loadAll()
        XCTAssertEqual(Set(notes.map(\.id)), [target.id, source.id])
        await reopened.close()
    }
}
