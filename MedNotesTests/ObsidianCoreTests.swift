import XCTest
@testable import MedNotes

final class ObsidianCoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeDataRoot() throws -> DataRoot {
        try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
    }

    // MARK: - Markdown export encoding

    func testMarkdownExportRoundTripPreservesAllFields() throws {
        let note = Note(
            title: "Rounds \"day\" two",
            content: "Line one\nLine [[two]]",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            tags: ["cardio", "ward 3"],
            mentionedPatients: [UUID()],
            isPinned: true)

        let text = MarkdownExportService.encode(note: note)
        let decoded = MarkdownVaultDecoder.decode(text)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, note.id)
        XCTAssertEqual(decoded?.title, note.title)
        XCTAssertEqual(decoded?.content, note.content)
        XCTAssertEqual(decoded?.tags, note.tags)
        XCTAssertEqual(decoded?.mentionedPatients, note.mentionedPatients)
        XCTAssertEqual(decoded?.isPinned, note.isPinned)
        XCTAssertEqual(decoded?.createdAt.timeIntervalSince1970 ?? 0,
                       note.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMigrationClearsPreExistingOrphanedNoteLinks() async throws {
        let dbPath = tempDir.appendingPathComponent("orphans.db").path
        let db = try Database.testDatabase(path: dbPath)
        let note = Note(title: "Ward round", content: "body")
        try await db.saveNote(note)
        try await db.checkpoint()
        await db.close()

        // Forge the pre-fix bad state: an edge with neither destination set.
        let side = try SQLConnection.testConnection(path: dbPath)
        let insert = try side.prepare("""
            INSERT INTO note_links (id, src_note_id, dst_note_id, dst_patient_id, anchor_text)
            VALUES (?, ?, NULL, NULL, ?)
            """)
        insert.bind(1, "zombie-row")
        insert.bind(2, note.id.uuidString)
        insert.bind(3, "Deleted Patient")
        _ = try insert.step()
        insert.finalize()
        let check = try side.prepare("SELECT COUNT(*) FROM note_links")
        XCTAssertTrue(try check.step())
        XCTAssertEqual(check.columnInt(0), 1, "precondition: zombie row exists")
        check.finalize()
        side.close()

        // Reopening runs migrateV2, which must sweep it. (`note_links` is the
        // superseded v2 table: nothing reads it any more, but the sweep stays.)
        let reopened = try Database.testDatabase(path: dbPath)
        let links = try await reopened.linksFromNote(noteId: note.id)
        XCTAssertTrue(links.isEmpty, "orphaned edge survived migration: \(links)")
        let verify = try SQLConnection.testConnection(path: dbPath)
        let remaining = try verify.prepare("SELECT COUNT(*) FROM note_links")
        XCTAssertTrue(try remaining.step())
        XCTAssertEqual(remaining.columnInt(0), 0, "the legacy sweep no longer ran")
        remaining.finalize()
        verify.close()
    }

    /// note_links.dst_patient_id is ON DELETE SET NULL (unlike dst_note_id,
    /// which cascades), so deleting a patient used to leave an edge with both
    /// dst columns NULL. linksFromNote infers kind from dst_note_id, so the
    /// zombie rendered in the links panel as a patient labelled "(missing)".
    func testDeletingPatientRemovesNoteLinksToIt() async throws {
        let root = try makeDataRoot()
        let store = try AppStore.testStore(dataRoot: root)

        var profile = PatientProfile(firstName: "Maria", lastName: "Papadopoulou",
                                     dateOfBirth: Date(timeIntervalSince1970: 0))
        profile.amka = "70000000001"
        let patient = Patient(profile: profile)
        try await store.patients.save(patient)

        let note = Note(title: "Ward round", content: "reviewed [[Maria Papadopoulou]]")
        try await store.notes.save(note)
        let before = try await store.linking.linksFrom(noteId: note.id)
        XCTAssertEqual(before.map(\.label), ["Maria Papadopoulou"])

        try await store.patients.delete(id: patient.id)

        let after = try await store.linking.linksFrom(noteId: note.id)
        XCTAssertTrue(after.isEmpty,
                      "orphaned edge survived patient deletion: \(after)")

        // And the graph must not carry a dangling edge either.
        let graph = try await store.linking.graph()
        XCTAssertFalse(graph.edges.contains { $0.sourceID == "n:\(note.id.uuidString)" })
        let violations = try await store.foreignKeyViolations()
        XCTAssertEqual(violations, 0)
    }

    /// A link names a patient by the patient's name. Renaming Bob to "Alice
    /// Smith" leaves the link that already pointed at Alice on Alice (it keeps
    /// its destination while the name still matches) and leaves the link that
    /// named "Bob Jones" without a patient: unresolved, kept in the note, and
    /// no longer listed among the note's resolved links.
    func testRenamingAPatientAwayFromALinkedNameUnresolvesThatLink() async throws {
        let root = try makeDataRoot()
        let store = try AppStore.testStore(dataRoot: root)

        func patient(_ first: String, _ last: String, amka: String) -> Patient {
            var p = PatientProfile(firstName: first, lastName: last,
                                   dateOfBirth: Date(timeIntervalSince1970: 0))
            p.amka = amka
            return Patient(profile: p)
        }
        let alice = patient("Alice", "Smith", amka: "10000000001")
        let bob = patient("Bob", "Jones", amka: "10000000002")
        try await store.patients.save(alice)
        try await store.patients.save(bob)

        let note = Note(title: "Round", content: "saw [[Alice Smith]] and [[Bob Jones]]")
        try await store.notes.save(note)
        let before = try await store.linking.linksFrom(noteId: note.id)
        XCTAssertEqual(Set(before.map(\.label)), ["Alice Smith", "Bob Jones"])

        var renamed = bob
        renamed.profile.firstName = "Alice"
        renamed.profile.lastName = "Smith"
        try await store.patients.save(renamed)

        let after = try await store.linking.linksFrom(noteId: note.id)
        XCTAssertEqual(after.map(\.label), ["Alice Smith"],
                       "only the link that still names its patient stays resolved")
    }

    /// `NoteService.save` calls relink on every save, so repeated saves must
    /// converge on one edge per link rather than accumulating duplicates.
    func testRelinkIsIdempotentAcrossSaves() async throws {
        let root = try makeDataRoot()
        let store = try AppStore.testStore(dataRoot: root)

        let target = Note(title: "Insulin Protocol", content: "body")
        try await store.notes.save(target)
        var source = Note(title: "Ward round", content: "see [[Insulin Protocol]]")
        for _ in 0..<3 {
            try await store.notes.save(source)
        }

        let backlinks = try await store.linking.backlinks(noteId: target.id)
        XCTAssertEqual(backlinks.map(\.noteId), [source.id], "one edge per link, not one per save")
        let outgoing = try await store.linking.linksFrom(noteId: source.id)
        XCTAssertEqual(outgoing.count, 1)

        let graph = try await store.linking.graph()
        let edges = graph.edges.filter {
            $0.sourceID == "n:\(source.id.uuidString)" && $0.targetID == "n:\(target.id.uuidString)"
        }
        XCTAssertEqual(edges.count, 1, "graph must not show duplicate edges")

        // Removing the mention clears the edge through the same paths.
        source.content = "cleared"
        try await store.notes.save(source)
        let after = try await store.linking.backlinks(noteId: target.id)
        XCTAssertTrue(after.isEmpty)
    }

    /// The one-time export writes one file per note and leaves nothing else.
    func testMarkdownExportWritesOneFilePerNote() async throws {
        let root = try DataRoot.temporary()
        let store = try AppStore.testStore(dataRoot: root)
        var note = Note(title: "exported", content: "revision 5")
        try await store.notes.save(note)
        note.content = "tiny"
        try await store.notes.save(note)

        let exportDir = root.rootURL.appendingPathComponent("Export", isDirectory: true)
        let report = try await MarkdownExportService(db: store.db).export(to: exportDir)
        XCTAssertEqual(report.notesWritten, 1)

        let entries = try FileManager.default.contentsOfDirectory(
            at: exportDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        let text = try String(contentsOf: entries[0], encoding: .utf8)
        XCTAssertEqual(MarkdownVaultDecoder.decode(text)?.content, "tiny")
        try? FileManager.default.removeItem(at: root.rootURL)
    }

    /// A lock cancels the export's task: no note is started after it, and the
    /// report says the export stopped.
    func testACancelledMarkdownExportWritesNothingMore() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        for index in 0..<3 {
            try await store.notes.save(Note(title: "note \(index)", content: "body \(index)"))
        }
        let service = MarkdownExportService(db: await store.db)
        let prepared = try await service.prepare()
        XCTAssertEqual(prepared.noteCount, 3)
        let notes = try await store.db.loadAllNotes()
        XCTAssertEqual(prepared.byteCount, notes.reduce(0) { $0 + MarkdownExportService.encode(note: $1).utf8.count })

        let exportDir = root.rootURL.appendingPathComponent("Export", isDirectory: true)
        let export = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.write(prepared, to: exportDir)
        }
        let report = try await export.value
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.notesWritten, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDir.path))

        let whole = try await service.write(prepared, to: exportDir)
        XCTAssertFalse(whole.wasCancelled)
        XCTAssertEqual(whole.notesWritten, 3)
    }

    /// A lock part-way through the export: the note being written finishes,
    /// and no further one is started.
    func testAMarkdownExportCancelledPartWayStopsAtTheNextNote() async throws {
        let root = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = try AppStore.testStore(dataRoot: root)
        for index in 0..<3 {
            try await store.notes.save(Note(title: "note \(index)", content: "body \(index)"))
        }
        let service = MarkdownExportService(db: await store.db)
        let prepared = try await service.prepare()
        let exportDir = root.rootURL.appendingPathComponent("Export", isDirectory: true)

        let export = Task {
            try await service.write(prepared, to: exportDir, didWrite: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        let report = try await export.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.notesWritten, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path).count, 1)
    }

    /// Notes whose content contains or starts with a divider must survive.
    func testMarkdownExportPreservesDividersInContent() {
        for content in ["---", "a\n---\nb", "---\nstill content"] {
            let note = Note(title: "dividers", content: content)
            let decoded = MarkdownVaultDecoder.decode(MarkdownExportService.encode(note: note))
            XCTAssertEqual(decoded?.content, content, "content: \(content)")
        }
    }

    func testMarkdownDecoderRejectsFilesWithoutFrontMatter() {
        XCTAssertNil(MarkdownVaultDecoder.decode("just some text"))
        XCTAssertNil(MarkdownVaultDecoder.decode("---\ntitle: no id"))
    }

    func testYAMLListParserHandlesEscapesAndLooseItems() {
        XCTAssertEqual(MarkdownVaultDecoder.parseYAMLList("[ \"a\", \"b c\", \"d\\ne\" ]"), ["a", "b c", "d\ne"])
        XCTAssertEqual(MarkdownVaultDecoder.parseYAMLList("[]"), [])
        XCTAssertEqual(MarkdownVaultDecoder.parseYAMLList(nil), [])
        XCTAssertEqual(MarkdownVaultDecoder.parseYAMLList("[loose]"), ["loose"])
    }

    /// A bare CR is a YAML line break, so it must travel escaped like a
    /// newline; otherwise the front-matter value is split across lines.
    func testMarkdownExportRoundTripsCarriageReturns() {
        let note = Note(
            title: "Line one\rLine two",
            content: "Body with\r\nWindows line endings",
            tags: ["carriage\rreturn"])
        let text = MarkdownExportService.encode(note: note)
        XCTAssertFalse(text.contains("\rLine two"), "the title's CR leaked into the front matter: \(text)")
        XCTAssertEqual(MarkdownVaultDecoder.decode(text)?.title, note.title)
        XCTAssertEqual(MarkdownVaultDecoder.decode(text)?.content, note.content)
        XCTAssertEqual(MarkdownVaultDecoder.decode(text)?.tags, note.tags)
    }

    /// The upgrade reads the retired mirror once and classifies every note.
    func testVaultReconciliationClassifiesAgainstTheDatabase() async throws {
        let root = try DataRoot.temporary()
        let store = try AppStore.testStore(dataRoot: root)
        let dbOnly = Note(title: "db only", content: "b")
        try await store.notes.save(dbOnly)

        let fileNote = Note(title: "file only", content: "f")
        let divergent = Note(title: "divergent", content: "vault text")
        let dbDivergent = Note(id: divergent.id, title: "divergent", content: "db text")
        try await store.notes.save(dbDivergent)

        try FileManager.default.createDirectory(at: root.vaultURL, withIntermediateDirectories: true)
        for note in [fileNote, divergent] {
            try MarkdownExportService.encode(note: note).write(
                to: root.vaultURL.appendingPathComponent(note.id.uuidString + ".md"),
                atomically: true, encoding: .utf8)
        }

        let scan = VaultReconciliation.scan(root: root.vaultURL)
        XCTAssertEqual(scan.notes.count, 2)
        let notes = try await store.db.loadAllNotes()
        let report = VaultReconciliation.reconcile(vaultNotes: scan.notes, databaseNotes: notes)
        XCTAssertEqual(report.vaultOnly.map(\.title), ["file only"])
        XCTAssertEqual(report.divergent.map(\.title), ["divergent"])
        XCTAssertEqual(report.databaseOnly.map(\.title), ["db only"])
        try? FileManager.default.removeItem(at: root.rootURL)
    }

    /// The mirror carries patient mentions and the pin flag too. A note that
    /// differs only in one of those is not identical, and must be shown to the
    /// user before the mirror is deleted.
    func testVaultReconciliationSeesPatientAndPinDifferences() {
        let id = UUID()
        let database = Note(id: id, title: "same", content: "same", tags: ["t"])
        var pinned = database
        pinned.isPinned = true
        let pinnedReport = VaultReconciliation.reconcile(
            vaultNotes: [.init(note: pinned, relativePath: "same.md")],
            databaseNotes: [database])
        XCTAssertEqual(pinnedReport.divergent.map(\.outcome), [.divergent])

        var mentioned = database
        mentioned.mentionedPatients = [UUID()]
        let mentionedReport = VaultReconciliation.reconcile(
            vaultNotes: [.init(note: mentioned, relativePath: "same.md")],
            databaseNotes: [database])
        XCTAssertEqual(mentionedReport.divergent.count, 1)
    }

    /// Dropping a file into Vault/ is the advertised Obsidian workflow, and
    /// README promises resolved edges land in `note_links`. Reconcile imported
    /// the note but never relinked it, so its [[links]] were missing from
    /// backlinks and the graph until something re-saved the note.
    func testVaultDerivedNoteKeepsItsOwnID() async throws {
        let root = try DataRoot.temporary()
        let store = try AppStore.testStore(dataRoot: root)
        let existing = Note(title: "existing", content: "e")
        try await store.notes.save(existing)

        let fileNote = Note(id: UUID(), title: "imported", content: "see [[existing]]")
        try FileManager.default.createDirectory(at: root.vaultURL, withIntermediateDirectories: true)
        try MarkdownExportService.encode(note: fileNote).write(
            to: root.vaultURL.appendingPathComponent(fileNote.id.uuidString + ".md"),
            atomically: true, encoding: .utf8)

        let scan = VaultReconciliation.scan(root: root.vaultURL)
        XCTAssertEqual(scan.notes.first?.note.id, fileNote.id)
        try? FileManager.default.removeItem(at: root.rootURL)
    }

    func testGraphNodeIDsCarryParsableUUIDAfterPrefix() async throws {
        let root = try makeDataRoot()
        let store = try AppStore.testStore(dataRoot: root)

        var profile = PatientProfile(firstName: "Maria", lastName: "Papadopoulou",
                                     dateOfBirth: Date(timeIntervalSince1970: 0))
        profile.amka = "99999999999"
        try await store.patients.save(Patient(profile: profile))
        try await store.notes.save(Note(title: "Ward round", content: "body"))

        let graph = try await store.linking.graph()
        XCTAssertFalse(graph.nodes.isEmpty)
        for node in graph.nodes {
            XCTAssertEqual(node.id.dropFirst(1).first, ":", "expected \"<kind>:<uuid>\", got \(node.id)")
            XCTAssertNotNil(UUID(uuidString: String(node.id.dropFirst(2))),
                            "UUID must parse after dropping the 2-char prefix: \(node.id)")
        }
    }

    // MARK: - Markdown preview

    /// `- [X] done` is valid Markdown. The parser detected it but passed the
    /// lowercase marker to a case-sensitive search, so the item's text was
    /// dropped and the line rendered as an empty checked box.
    func testChecklistKeepsTextForUppercaseX() {
        let blocks = MarkdownPreview.parseBlocks("""
        - [ ] Draw bloods
        - [x] Administered insulin
        - [X] Reviewed chart
        """)
        var seen: [(String, Bool)] = []
        for block in blocks {
            if case let .checklist(text, checked) = block { seen.append((text, checked)) }
        }
        XCTAssertEqual(seen.map(\.0), ["Draw bloods", "Administered insulin", "Reviewed chart"])
        XCTAssertEqual(seen.map(\.1), [false, true, true])
    }

    /// A tag with no space after the hash is content, not an ATX heading. The
    /// sample store opens a note on "#cardiology and #respiratory"; rendering
    /// that as a heading dropped both hashes from the preview.
    func testHashTagIsNotAHeading() {
        let blocks = MarkdownPreview.parseBlocks("#cardiology and #respiratory")
        guard case let .paragraph(text)? = blocks.first else {
            return XCTFail("expected a paragraph, got \(blocks)")
        }
        XCTAssertEqual(text, "#cardiology and #respiratory")
    }

    /// A leading `---` pair is front matter: one block of its lines, not a
    /// rule and a run-on paragraph of YAML. Later rules stay rules.
    func testFrontMatterIsOneBlock() {
        let blocks = MarkdownPreview.parseBlocks("""
        ---
        created: 2026-10-01
        tags: [cardiology]
        ---
        Seen today.

        ---
        """)
        guard blocks.count == 3, case let .frontMatter(lines) = blocks[0] else {
            return XCTFail("expected front matter first, got \(blocks)")
        }
        XCTAssertEqual(lines, ["created: 2026-10-01", "tags: [cardiology]"])
        guard case .paragraph("Seen today.") = blocks[1], case .divider = blocks[2] else {
            return XCTFail("got \(blocks)")
        }
    }

    /// Without a closing `---` the first line is an ordinary rule, and an
    /// empty pair adds no block.
    func testUnclosedOrEmptyFrontMatter() {
        let unclosed = MarkdownPreview.parseBlocks("---\nJust text")
        guard unclosed.count == 2, case .divider = unclosed[0], case .paragraph("Just text") = unclosed[1] else {
            return XCTFail("got \(unclosed)")
        }
        let empty = MarkdownPreview.parseBlocks("---\n---\nBody")
        guard empty.count == 1, case .paragraph("Body") = empty[0] else {
            return XCTFail("got \(empty)")
        }
    }

    // MARK: - Linking

    func testExtractAnchorsDeduplicatesAndSkipsNesting() {
        let content = "See [[Ward Rounds]] then [[Private]] again [[ward rounds]] bad [[a[[b]]c]] [[ ]] tail [[Unclosed"
        let anchors = LinkingService.extractAnchors(from: content)
        XCTAssertEqual(anchors, ["Ward Rounds", "Private", "b"])
    }

    func testOpenAnchorAndCompletion() {
        XCTAssertEqual(LinkingService.openAnchor(in: "hello [[war"), "war")
        XCTAssertEqual(LinkingService.openAnchor(in: "hello [[war]] done"), nil)
        XCTAssertEqual(LinkingService.openAnchor(in: "no brackets"), nil)
        // Last unterminated [[ wins — typing a second bracket pair mid-anchor
        // is literal text in real editors.
        XCTAssertEqual(LinkingService.openAnchor(in: "[[nested [[deep"), "deep")
        let completed = LinkingService.complete(openAnchorText: "see [[war", choice: "Ward Rounds")
        XCTAssertEqual(completed, "see [[Ward Rounds]]")
    }

    /// A "[[" typed above existing text must not turn the rest of the note
    /// into the query, and completing must never drop what follows it.
    func testOpenAnchorMidNoteLeavesFollowingTextAlone() {
        let body = "Discussed with cardiology.\nFollow up in two weeks."

        // "[[" alone at the end of a line, above the rest of the note.
        let bare = "Plan: [[\n" + body
        XCTAssertNil(LinkingService.openAnchor(in: bare))
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: bare, choice: "Cardiology follow-up"),
            "Plan: [[Cardiology follow-up]]\n" + body)

        // Mid-line, with more text on that line and lines below it: the
        // anchor ends at its line, and the lines below are kept.
        let midLine = "Seen on [[ward rounds\n" + body
        XCTAssertNil(LinkingService.openAnchor(in: midLine))
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: midLine, choice: "Ward Rounds"),
            "Seen on [[Ward Rounds]]\n" + body)

        // At the very top of the note.
        let top = "[[car\n" + body
        XCTAssertNil(LinkingService.openAnchor(in: top))
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: top, choice: "Cardiology follow-up"),
            "[[Cardiology follow-up]]\n" + body)

        // Any line break ends the anchor, not only "\n".
        let crlf = "See [[war\r\nNext line"
        XCTAssertNil(LinkingService.openAnchor(in: crlf))
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: crlf, choice: "Ward Rounds"),
            "See [[Ward Rounds]]\r\nNext line")
    }

    func testOpenAnchorAtEndOfNoteKeepsEarlierText() {
        let text = "Discussed with cardiology.\nSee [[war"
        XCTAssertEqual(LinkingService.openAnchor(in: text), "war")
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: text, choice: "Ward Rounds"),
            "Discussed with cardiology.\nSee [[Ward Rounds]]")

        // Freshly typed brackets: an empty query that lists recent notes.
        XCTAssertEqual(LinkingService.openAnchor(in: "Discussed.\nSee [["), "")
        XCTAssertEqual(LinkingService.openAnchor(in: "See [[ Maria "), "Maria")
        XCTAssertEqual(LinkingService.openAnchor(in: "Βλ. [[Παπαδ"), "Παπαδ")

        // A closed link earlier in the note does not stop a new one.
        let afterLink = "See [[Ward Rounds]] and\n[[card"
        XCTAssertEqual(LinkingService.openAnchor(in: afterLink), "card")
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: afterLink, choice: "Cardiology follow-up"),
            "See [[Ward Rounds]] and\n[[Cardiology follow-up]]")
    }

    /// The whole-text rule, for when the editor cannot tell where the caret
    /// is: any line break after the query ends it — including a trailing
    /// one, which reads the same as Return — and on the last line everything
    /// after "[[" is the query. With the caret known, see the tests below.
    func testOpenAnchorWithoutCaretEndsAtTheLine() {
        XCTAssertNil(LinkingService.openAnchor(in: "See [[war\n"))
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: "See [[war\n", choice: "Ward Rounds"),
            "See [[Ward Rounds]]\n")

        // "[[" typed before words already on the last line takes them in,
        // up to `maxOpenAnchorLength` characters of that line and no more.
        let wrapped = "Plan: review.\nFollow up with [[cardiology in two weeks."
        XCTAssertEqual(LinkingService.openAnchor(in: wrapped), "cardiology in two weeks.")
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: wrapped, choice: "Cardiology follow-up"),
            "Plan: review.\nFollow up with [[Cardiology follow-up]]")
    }

    func testOpenAnchorLengthLimit() {
        let limit = LinkingService.maxOpenAnchorLength
        let longest = String(repeating: "a", count: limit)
        XCTAssertEqual(LinkingService.openAnchor(in: "x [[" + longest), longest)

        let tooLong = "x [[" + longest + "b"
        XCTAssertNil(LinkingService.openAnchor(in: tooLong))
        XCTAssertEqual(LinkingService.complete(openAnchorText: tooLong, choice: "Ward Rounds"), tooLong)

        // The limit is per line: a long line that breaks later is still too
        // long, and one that fits keeps the lines after it.
        let longLine = tooLong + "\nNext line"
        XCTAssertEqual(LinkingService.complete(openAnchorText: longLine, choice: "Ward Rounds"), longLine)
        XCTAssertEqual(
            LinkingService.complete(openAnchorText: "x [[" + longest + "\nNext line", choice: "Ward Rounds"),
            "x [[Ward Rounds]]\nNext line")
    }

    func testCompleteWithoutOpenAnchorChangesNothing() {
        for text in ["no brackets", "See [[Ward Rounds]] today", "See [[Ward Rounds]]\nnext", ""] {
            XCTAssertEqual(LinkingService.complete(openAnchorText: text, choice: "Ward Rounds"), text)
        }
    }

    // MARK: - Linking at the caret ("|" marks it)

    func testOpenAnchorAtCaretWorksAnywhereInTheNote() {
        XCTAssertEqual(anchor("Plan: [[car|\nDiscussed with cardiology."), "car")
        XCTAssertEqual(
            completed("Plan: [[car|\nDiscussed with cardiology.", "Cardiology follow-up"),
            "Plan: [[Cardiology follow-up]]\nDiscussed with cardiology.")

        // Mid-line: the words after the caret are not part of the query.
        XCTAssertEqual(anchor("Follow up with [[cardio| in two weeks."), "cardio")
        XCTAssertEqual(
            completed("Follow up with [[cardio| in two weeks.", "Cardiology follow-up"),
            "Follow up with [[Cardiology follow-up]] in two weeks.")

        // Brackets typed just before existing words: an empty query, and
        // nothing already on the line is replaced.
        XCTAssertEqual(anchor("Follow up with [[|cardiology in two weeks."), "")
        XCTAssertEqual(
            completed("Follow up with [[|cardiology in two weeks.", "Cardiology follow-up"),
            "Follow up with [[Cardiology follow-up]]cardiology in two weeks.")

        // The caret decides which "[[" is open, not the note's end.
        XCTAssertEqual(anchor("[[war| rounds\nSee [[Cardiology follow-up]]"), "war")
        XCTAssertEqual(anchor("See [[Ward Rounds]] and [[wou| today"), "wou")
        XCTAssertEqual(anchor("Plan:  [[  Maria |"), "Maria")
    }

    func testCompletingInsideAnExistingLinkReplacesTheWholeLink() {
        XCTAssertEqual(anchor("See [[Ward Ro|unds]] today"), "Ward Ro")
        XCTAssertEqual(completed("See [[Ward Ro|unds]] today", "Ward Rounds"), "See [[Ward Rounds]] today")
        XCTAssertEqual(completed("See [[war|]]", "Ward Rounds"), "See [[Ward Rounds]]")
        // A "]]" further on that closes a later link is not this one's.
        XCTAssertEqual(
            completed("See [[war| and [[Wound Care]]", "Ward Rounds"),
            "See [[Ward Rounds]] and [[Wound Care]]")
        // Nor one on the next line.
        XCTAssertEqual(completed("See [[war|\nx]]", "Ward Rounds"), "See [[Ward Rounds]]\nx]]")
    }

    func testNoOpenAnchorAtCaret() {
        for marked in ["See [[Ward Rounds]]|", "See [[war\nnext| line", "|See [[war",
                       "See [|[war", "no brackets|", "|", "See [[war]]| [[x",
                       // Between the brackets of a "]]": past the link, not in it.
                       "See [[Ward Rounds]|] today", "See [[Ward Rounds]|]", "[[a]] and [[b]|] c",
                       // Between the brackets of a "[[": completing would swallow that link.
                       "See [[car[|[Ward Rounds]] today", "See [[|[Ward Rounds]] today"] {
            XCTAssertNil(anchor(marked), marked)
            let (text, caret) = caretText(marked)
            XCTAssertNil(LinkingService.completion(in: text, caretUTF16: caret, choice: "Ward Rounds"), marked)
        }
        // Typing the first "]" of a link is still inside it; a whole "[["
        // starting at the caret is the next link, not part of this one.
        XCTAssertEqual(completed("See [[Ward Rounds]|", "Ward Rounds"), "See [[Ward Rounds]]")
        XCTAssertEqual(completed("See [[|[[b]] x", "W"), "See [[W]][[b]] x")

        // A caret outside the text (a stale selection) is no caret.
        XCTAssertNil(LinkingService.openAnchor(in: "See [[war", caretUTF16: -1))
        XCTAssertNil(LinkingService.openAnchor(in: "See [[war", caretUTF16: 10))
    }

    func testOpenAnchorAtCaretLengthLimit() {
        let longest = String(repeating: "a", count: LinkingService.maxOpenAnchorLength)
        XCTAssertEqual(anchor("x [[\(longest)| tail"), longest)
        XCTAssertNil(anchor("x [[\(longest)b| tail"))
        // Inside a closed link the whole link counts: past the limit, only
        // the query is replaced and the rest is left as it was.
        XCTAssertEqual(completed("x [[a|\(longest)]] y", "W"), "x [[W]]\(longest)]] y")
    }

    /// The brackets are matched literally, as `extractAnchors` does: a
    /// combining mark after one must not hide a closed link.
    func testBracketsFollowedByACombiningMarkStillCloseALink() {
        let closed = "Seen [[Ward Rounds]]\u{301} and follow up"
        XCTAssertNil(anchor(closed + "|\nsecond line"))
        XCTAssertNil(LinkingService.openAnchor(in: closed))
        XCTAssertEqual(LinkingService.complete(openAnchorText: closed, choice: "W"), closed)
        XCTAssertEqual(LinkingService.extractAnchors(from: closed), ["Ward Rounds"])
    }

    /// The caret is a UTF-16 offset, as `NSTextView` gives it.
    func testOpenAnchorAtCaretCountsUTF16() {
        XCTAssertEqual(anchor("Βλ. 😀 [[Παπ|αδ"), "Παπ")
        XCTAssertEqual(
            completed("Βλ. 😀 [[Παπ|\nεπόμενη γραμμή", "Παπαδοπούλου Μαρία"),
            "Βλ. 😀 [[Παπαδοπούλου Μαρία]]\nεπόμενη γραμμή")
        XCTAssertEqual(completed("x [[a|\r\n[[b", "W"), "x [[W]]\r\n[[b")
        XCTAssertEqual(anchor("x [[a\r\n[[b|"), "b")
        // The limit is in Characters: 100 emoji, 200 UTF-16 units, still fit.
        let emoji = String(repeating: "😀", count: LinkingService.maxOpenAnchorLength)
        XCTAssertEqual(anchor("x [[\(emoji)|"), emoji)
        // Far back on a long line, an open "[[" is past the limit anyway.
        XCTAssertNil(anchor("[[" + String(repeating: "word ", count: 2_000) + "|"))
    }

    /// When the caret is unknown the editor falls back to the whole-text
    /// rule; at the note's end the two must agree.
    func testWholeTextRuleMatchesTheCaretAtTheEnd() throws {
        let texts = ["hello [[war", "[[nested [[deep", "Discussed.\nSee [[card", "See [[ Maria ",
                     "Plan: review.\nFollow up with [[cardiology in two weeks.", "Βλ. [[Παπαδ", "x [["]
        for text in texts {
            let end = (text as NSString).length
            let edit = try XCTUnwrap(LinkingService.completion(in: text, caretUTF16: end, choice: "Ward Rounds"), text)
            XCTAssertEqual(
                (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement),
                LinkingService.complete(openAnchorText: text, choice: "Ward Rounds"), text)
        }
    }

    /// `marked` without its "|", and the caret's UTF-16 offset.
    private func caretText(_ marked: String) -> (text: String, caret: Int) {
        let ns = marked as NSString
        let bar = ns.range(of: "|", options: .literal)
        return (ns.replacingCharacters(in: bar, with: ""), bar.location)
    }

    private func anchor(_ marked: String) -> String? {
        let (text, caret) = caretText(marked)
        return LinkingService.openAnchor(in: text, caretUTF16: caret)
    }

    private func completed(_ marked: String, _ choice: String) -> String? {
        let (text, caret) = caretText(marked)
        guard let edit = LinkingService.completion(in: text, caretUTF16: caret, choice: choice) else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testResolveIsStrict_ExactKeyNotesBeforePatients_NeverGuesses() {
        let nA = UUID().uuidString, nB = UUID().uuidString, pX = UUID().uuidString
        var index = LinkIndex.Index()
        index.noteIDsByKey = [
            WikiLinkParser.normalizedKey("Ward Rounds"): [nA],
            WikiLinkParser.normalizedKey("Wound Care"): [nB],
        ]
        index.noteKeyByID = [
            nA: WikiLinkParser.normalizedKey("Ward Rounds"),
            nB: WikiLinkParser.normalizedKey("Wound Care"),
        ]
        let maria = WikiLinkParser.normalizedKey("Maria Papadopoulou")
        index.patientIDsByKey = [maria: [pX]]
        index.patientKeysByID = [pX: [maria]]

        func resolve(_ text: String) -> LinkIndex.Resolution {
            let key = WikiLinkParser.normalizedKey(text)
            return LinkIndex.resolve(
                innerKey: key, targetKey: key, sourceID: UUID().uuidString, current: nil, index: index)
        }
        XCTAssertEqual(resolve("ward rounds"), .init(state: "resolved", kind: "note", id: nA))
        XCTAssertEqual(resolve("maria papadopoulou"), .init(state: "resolved", kind: "patient", id: pX))
        // The old rule resolved these by "unique contains"; they no longer do.
        XCTAssertEqual(resolve("woun").state, "unresolved")
        XCTAssertEqual(resolve("Papadopoulou").state, "unresolved")
        XCTAssertEqual(resolve("w").state, "unresolved")
    }

    func testRelinkWritesRowsAndBacklinksFlowThroughGraph() async throws {
        let root = try makeDataRoot()
        let store = try AppStore.testStore(dataRoot: root)

        let patient = Patient(profile: PatientProfile(firstName: "Maria", lastName: "Papadopoulou", dateOfBirth: Date(timeIntervalSince1970: -6e8)))
        try await store.patients.save(patient)

        let target = Note(title: "Insulin Protocol", content: "protocol body")
        let source = Note(
            title: "Morning note",
            content: "Per [[Insulin Protocol]] check on [[Maria Papadopoulou]] plus ghost [[Nobody Here]]")
        try await store.notes.save(target)
        try await store.notes.save(source)

        let backlinks = try await store.linking.backlinks(noteId: target.id)
        XCTAssertEqual(backlinks.map(\.noteId), [source.id])

        let outLinks = try await store.linking.linksFrom(noteId: source.id)
        XCTAssertEqual(outLinks.count, 2)

        let graph = try await store.linking.graph()
        XCTAssertTrue(graph.nodes.contains { $0.kind == .patient })
        XCTAssertTrue(graph.edges.contains {
            $0.sourceID == "n:\(source.id.uuidString)" && $0.targetID == "n:\(target.id.uuidString)"
        })

        // Editing away the mentions drops stale edges.
        let edited = Note(
            id: source.id, title: source.title, content: "cleared",
            createdAt: source.createdAt, updatedAt: source.updatedAt)
        try await store.notes.save(edited)
        let after = try await store.linking.linksFrom(noteId: source.id)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: - Templates

    func testFreshDatabaseSeedsClinicalTemplates() async throws {
        let root = try makeDataRoot()
        let store = try AppStore.testStore(dataRoot: root)
        let list = try await store.templates.allTemplates()
        XCTAssertTrue(list.contains { $0.kind == .soap && $0.name == String(localized: "SOAP Note") })
        XCTAssertTrue(list.contains { $0.kind == .admission })
        XCTAssertTrue(list.contains { $0.kind == .discharge })
    }

    func testTemplateRenderingSubstitutesTokens() {
        let template = TemplateService.builtIns[0]
        let rendered = template.rendered(patientName: "Maria P.")
        XCTAssertFalse(rendered.contains("{{date}}"))
        XCTAssertFalse(rendered.contains("{{time}}"))
        XCTAssertFalse(rendered.contains("{{patient}}"))
        XCTAssertTrue(rendered.contains("Maria P."))
    }

    // MARK: - Migration v1 → v2

    func testLegacyV1DatabaseUpgradesInPlace() async throws {
        let path = tempDir.appendingPathComponent("legacy.db").path

        // Build a genuine pre-v2 database by running only Schema.v1.
        let conn = try SQLConnection.testConnection(path: path)
        for statement in Schema.v1 {
            try conn.exec(statement)
        }
        try conn.exec("""
            INSERT INTO patients (id, date_of_birth, created_at, last_modified)
            VALUES ('11111111-1111-1111-1111-111111111111', '1980-05-05T00:00:00.000', '2024-01-01T00:00:00.000', '2024-01-01T00:00:00.000')
            """)
        try conn.exec("""
            INSERT INTO notes (id, title, content)
            VALUES ('22222222-2222-2222-2222-222222222222', 'Legacy note', 'body')
            """)
        try conn.exec("""
            INSERT INTO calendar_events (id, title, start_date, end_date, event_type)
            VALUES ('33333333-3333-3333-3333-333333333333', 'Legacy visit',
                    '2024-02-02T09:00:00.000', '2024-02-02T10:00:00.000', 'Appointment')
            """)
        try conn.exec("""
            INSERT INTO todo_items (id, title, created_at)
            VALUES ('44444444-4444-4444-4444-444444444444', 'Legacy todo', '2024-03-03T08:00:00.000')
            """)
        conn.close()

        // Reopening through the live migration path must upgrade AND preserve.
        let db = try Database.testDatabase(path: path)
        let note = try await db.loadNote(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        XCTAssertEqual(note?.title, "Legacy note")

        let events = try await db.loadAllEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.syncStatus, .localOnly)
        XCTAssertNil(events.first?.ekEventIdentifier)

        let templates = try await db.customTemplates()
        XCTAssertEqual(templates.count, 3)

        // v3: the todo gained its modification stamp, backfilled from created_at,
        // and its Reminders bookkeeping is still empty.
        let todo = try await db.loadTodo(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        XCTAssertEqual(todo?.title, "Legacy todo")
        XCTAssertEqual(todo?.updatedAt, todo?.createdAt)
        XCTAssertEqual(todo?.syncStatus, .localOnly)
        XCTAssertNil(todo?.reminderIdentifier)
        let marker = try SQLConnection.testConnection(path: path)
        let applied = try marker.prepare("SELECT COUNT(*) FROM migrations WHERE version = '3.0-reminders-sync'")
        XCTAssertTrue(try applied.step())
        XCTAssertEqual(applied.columnInt(0), 1)
        applied.finalize()
        marker.close()

        // Integrity + FK safety survived the upgrade.
        let integrity = try await db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
        let violations = try await db.foreignKeyCheck()
        XCTAssertEqual(violations, 0)
    }

    // MARK: - Calendar sync core

    private func fields(_ title: String = "T", start: Date = Date(timeIntervalSince1970: 100),
                        end: Date? = nil, notes: String = "", allDay: Bool = false) -> EventFields {
        EventFields(
            title: title,
            notes: notes,
            startDate: start,
            endDate: end ?? start.addingTimeInterval(1800),
            isAllDay: allDay)
    }

    func testPullDecisionTreatsUnchangedRemoteAsSame() {
        let local = CalendarEvent(updatedAt: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(CalendarSyncCore.decide(local: local, remote: CalendarSyncCore.fields(of: local)), .same)
    }

    func testPullDecisionCleanLocalRowAcceptsRemoteEditWithoutConflict() {
        var local = CalendarEvent(updatedAt: Date(timeIntervalSince1970: 100))
        local.lastSyncDate = Date(timeIntervalSince1970: 120)
        local.syncStatus = .synced
        let decision = CalendarSyncCore.decide(local: local, remote: fields("remote edit"))
        XCTAssertEqual(decision, .update(conflict: false))
    }

    func testPullDecisionDirtyLocalRowFlagsConflictButStillUpdates() {
        var local = CalendarEvent(updatedAt: Date(timeIntervalSince1970: 150))
        local.lastSyncDate = Date(timeIntervalSince1970: 100)
        local.syncStatus = .synced
        XCTAssertEqual(CalendarSyncCore.decide(local: local, remote: fields("remote edit")),
                       .update(conflict: true))
        // Never-synced but freshly edited locally is not a conflict either —
        // it simply means both sides hold independent rows until a push runs.
        local.lastSyncDate = nil
        local.syncStatus = .localOnly
        XCTAssertEqual(CalendarSyncCore.decide(local: local, remote: fields("brand new")),
                       .update(conflict: false))
    }

    func testMergingKeepsMedNotesOnlyConcepts() {
        let patientId = UUID()
        var merged = CalendarEvent(
            patientId: patientId,
            eventType: .surgery,
            updatedAt: Date(timeIntervalSince1970: 1))
        let base = fields("New Title", notes: "note text", allDay: true)
        CalendarSyncCore.merging(remote: base, into: &merged)
        XCTAssertEqual(merged.title, "New Title")
        XCTAssertEqual(merged.description, "note text")
        XCTAssertTrue(merged.isAllDay)
        // Compared against the id captured before the merge: asserting
        // merged.patientId against itself was a tautology that would still
        // pass if merging cleared the patient link it exists to protect.
        XCTAssertEqual(merged.patientId, patientId)
        XCTAssertEqual(merged.eventType, .surgery)
        XCTAssertGreaterThanOrEqual(merged.endDate, merged.startDate)
    }
}
