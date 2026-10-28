import XCTest
@testable import MedNotes

/// The notes search as the list uses it: operators, phrases and negation over
/// a real store. The plain `searchNotes` (quick open, `[[` completion) is
/// pinned elsewhere and must keep its meaning.
final class SearchEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeStore() throws -> AppStore {
        try AppStore.testStore(dataRoot: DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true)))
    }

    private func patient(_ first: String, _ last: String, amka: String = "12345678901",
                         fathers: String? = nil, archived: Bool = false) -> Patient {
        var profile = PatientProfile(
            firstName: first, lastName: last,
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -40, to: Date())!,
            gender: .male, amka: amka, phone: "", email: "")
        profile.fathersName = fathers
        var p = Patient(profile: profile)
        p.isArchived = archived
        return p
    }

    private func search(_ store: AppStore, _ text: String, tag: String? = nil) async throws -> [String] {
        try await store.notes.list(search: text, tagKey: tag).map(\.title)
    }

    private func expect(_ store: AppStore, _ text: String, tag: String? = nil, equals expected: [String],
                        sorted: Bool = false, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        var found = try await search(store, text, tag: tag)
        var want = expected
        if sorted { found.sort(); want.sort() }
        XCTAssertEqual(found, want, message, file: file, line: line)
    }

    private func expectCount(_ store: AppStore, _ text: String, tag: String? = nil, equals count: Int,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let found = try await search(store, text, tag: tag)
        XCTAssertEqual(found.count, count, message, file: file, line: line)
    }

    // MARK: - Text

    func testWordsPhrasesAndPrefixes() async throws {
        let store = try makeStore()
        for (title, body) in [
            ("One", "acute chest pain on exertion"),
            ("Two", "pain in the chest, not acute"),
            ("Three", "painful swallowing"),
        ] { try await store.notes.save(Note(title: title, content: body)) }

        try await expect(store, "chest pain", equals: ["One", "Two"], sorted: true)
        try await expect(store, "pain", equals: ["One", "Three", "Two"], sorted: true, "a word is a prefix")
        try await expect(store, "\"chest pain\"", equals: ["One"], "a closed phrase is exact and ordered")
        try await expect(store, "\"chest pa", equals: ["One"], "an unclosed phrase is still being typed")
        await store.close()
    }

    func testAnExactPhraseDoesNotMatchALongerWord() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Long", content: "painful swallowing"))
        try await store.notes.save(Note(title: "Exact", content: "chest pain today"))
        try await expect(store, "\"pain\"", equals: ["Exact"])
        await store.close()
    }

    func testPunctuationInsideAWordIsAPhrase() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Spine", content: "fracture at C3-C4 level"))
        try await store.notes.save(Note(title: "Other", content: "C3 normal, C4 normal"))
        try await expect(store, "C3-C4", equals: ["Spine"])
        await store.close()
    }

    func testNegationAndOrAndGroups() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "A", content: "digoxin and warfarin"))
        try await store.notes.save(Note(title: "B", content: "warfarin only"))
        try await store.notes.save(Note(title: "C", content: "apixaban"))

        try await expect(store, "warfarin -digoxin", equals: ["B"])
        try await expect(store, "digoxin OR apixaban", equals: ["A", "C"], sorted: true)
        try await expect(store, "(digoxin OR apixaban) -warfarin", equals: ["C"], sorted: true)
        try await expect(store, "-digoxin", equals: ["B", "C"], sorted: true, "only a negation: everything else")
        await store.close()
    }

    func testNothingSearchableReturnsNothing() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "A", content: "text"))
        for text in ["???", "tag:", "()", "\"\"", "[]", "- -"] {
            let found = try await search(store, text)
            XCTAssertTrue(found.isEmpty, "\(text) found \(found)")
        }
        await store.close()
    }

    func testHalfTypedQueriesNeverThrow() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "A", content: "text"))
        for text in ["tag:", "\"unclosed", "(a OR", "a OR OR b", "*", "^a", "NEAR(a b)", "a AND b", "col:x", "-\"", "[a", "property::", "patient:", "linked:[["] {
            _ = try await search(store, text)
        }
        await store.close()
    }

    func testAnOperatorTypedInsideAWordIsJustText() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Odd", content: "zzz-nothing-matches here"))
        try await store.notes.save(Note(title: "No", content: "zzz is not nothing"))
        try await expect(store, "zzz-nothing-matches", equals: ["Odd"])
        await store.close()
    }

    func testPinnedNotesComeFirstThenTheNewest() async throws {
        let store = try makeStore()
        let old = Note(title: "Old", content: "word", updatedAt: Date(timeIntervalSince1970: 1_000))
        let new = Note(title: "New", content: "word", updatedAt: Date(timeIntervalSince1970: 2_000))
        let pinned = Note(title: "Pinned", content: "word", updatedAt: Date(timeIntervalSince1970: 500), isPinned: true)
        for note in [old, new, pinned] { try await store.notes.save(note) }
        try await expect(store, "word", equals: ["Pinned", "New", "Old"])
        await store.close()
    }

    func testGreekWordsAndAccentsAreFolded() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Πόνος", content: "ασθενής με θωρακικό πόνο"))
        try await expect(store, "ασθενής", equals: ["Πόνος"])
        try await expect(store, "ΑΣΘΕΝΗΣ", equals: ["Πόνος"])
        try await expect(store, "ασθενης", equals: ["Πόνος"], "the full-text index folds the tonos")
        try await expect(store, "θωρακικο πονο", equals: ["Πόνος"])
        await store.close()
    }

    func testASavedLargeNoteIsStillQuick() async throws {
        let store = try makeStore()
        let paragraph = "Ο ασθενής ήρθε σήμερα με θωρακικό πόνο και δύσπνοια. "
        let note = Note(title: "Big", content: String(repeating: paragraph, count: 1_100))   // ~60 KB
        let start = Date()
        for _ in 0..<5 { try await store.notes.save(note) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "five saves of a 60 KB note")
        try await expect(store, "δυσπνοια", equals: ["Big"])
        await store.close()
    }

    // MARK: - tag:

    func testTagOperatorIsHierarchicalAndUsesAllSources() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Inline", content: "#cardio/ward round"))
        try await store.notes.save(Note(title: "Field", content: "body", tags: ["#Cardio"]))
        try await store.notes.save(Note(title: "Prop", content: "---\ntags: [cardio]\n---\nbody"))
        try await store.notes.save(Note(title: "Other", content: "#cardiology"))

        try await expect(store, "tag:cardio", equals: ["Field", "Inline", "Prop"], sorted: true)
        try await expect(store, "tag:#cardio/ward", equals: ["Inline"])
        try await expect(store, "tag:cardio -tag:cardio/ward", equals: ["Field", "Prop"], sorted: true)
        try await expect(store, "tag:cardiology", equals: ["Other"])
        await store.close()
    }

    func testGreekTagOperator() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Κ", content: "#Καρδιολογία σήμερα"))
        try await expect(store, "tag:καρδιολογια", equals: ["Κ"])
        await store.close()
    }

    func testATagFilterFromTheMenuIsAndedWithTheQuery() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Both", content: "#cardio digoxin"))
        try await store.notes.save(Note(title: "Only text", content: "digoxin"))
        try await store.notes.save(Note(title: "Only tag", content: "#cardio"))
        try await expect(store, "digoxin", tag: "cardio", equals: ["Both"])
        try await expect(store, "-digoxin", tag: "cardio", equals: ["Only tag"])
        await store.close()
    }

    // MARK: - property:

    func testPropertyOperators() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Active", content: "---\nstatus: active\nage: 42\n---\nx"))
        try await store.notes.save(Note(title: "Inactive", content: "---\nstatus: inactive\n---\nx"))
        try await store.notes.save(Note(title: "Phrase", content: "---\nstatus: in progress today\n---\nx"))
        try await store.notes.save(Note(title: "List", content: "---\naliases: [Alpha, Beta Gamma]\n---\nx"))
        try await store.notes.save(Note(title: "Flag", content: "---\nreviewed: true\n---\nx"))
        try await store.notes.save(Note(title: "None", content: "no front matter"))

        try await expect(store, "property:status", equals: ["Active", "Inactive", "Phrase"], sorted: true)
        try await expect(store, "property:status:active", equals: ["Active"], "a whole word, not a part of one")
        try await expect(store, "[status:active]", equals: ["Active"])
        try await expect(store, "[STATUS:\"in progress\"]", equals: ["Phrase"])
        try await expect(store, "property:status:\"in progress\"", equals: ["Phrase"])
        try await expect(store, "property:age:42", equals: ["Active"])
        try await expect(store, "property:aliases:\"beta gamma\"", equals: ["List"])
        try await expect(store, "[reviewed:true]", equals: ["Flag"])
        try await expect(store, "-property:status", equals: ["Flag", "List", "None"], sorted: true)
        await store.close()
    }

    func testAGreekPropertyKeyAndValueMatchAcrossAccents() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Ν", content: "---\n\"x\": 1\n---\n"))   // read-only key, ignored
        try await store.notes.save(Note(title: "Γ", content: "---\nτμήμα: Καρδιολογία\n---\nx"))
        try await expect(store, "property:τμημα:καρδιολογια", equals: ["Γ"])
        await store.close()
    }

    // MARK: - patient:

    func testPatientOperatorFindsMentionsAndLinksAndArchivedPatients() async throws {
        let store = try makeStore()
        let nikos = patient("Nikos", "Georgiou")
        let old = patient("Maria", "Pappa", amka: "22222222222", archived: true)
        try await store.db.savePatient(nikos)
        try await store.db.savePatient(old)

        var mention = Note(title: "Mention", content: "no name here")
        mention.mentionedPatients = [nikos.id]
        try await store.notes.save(mention)
        try await store.notes.save(Note(title: "Link", content: "Saw [[Nikos Georgiou]] today"))
        var archivedMention = Note(title: "Archived", content: "x")
        archivedMention.mentionedPatients = [old.id]
        try await store.notes.save(archivedMention)
        try await store.notes.save(Note(title: "Unrelated", content: "other"))

        try await expect(store, "patient:nikos", equals: ["Link", "Mention"], sorted: true)
        try await expect(store, "patient:\"Nikos Georgiou\"", equals: ["Link", "Mention"], sorted: true)
        try await expect(store, "patient:maria", equals: ["Archived"], "archived patients count")
        try await expectCount(store, "patient:nikos -patient:maria", equals: 2)
        try await expect(store, "patient:zzz", equals: [])
        await store.close()
    }

    func testAPlainWordStillFindsANoteThroughItsPatient() async throws {
        let store = try makeStore()
        let nikos = patient("Nikos", "Georgiou", amka: "55555555555")
        try await store.db.savePatient(nikos)
        var note = Note(title: "Follow-up", content: "no name in body")
        note.mentionedPatients = [nikos.id]
        try await store.notes.save(note)
        try await store.notes.save(Note(title: "Unrelated", content: "other"))

        try await expect(store, "nikos", equals: ["Follow-up"])
        try await expect(store, "55555555555", equals: ["Follow-up"], "an AMKA keeps finding the patient's notes")
        // Each term is matched on its own: one through the text, one through the patient.
        var withText = Note(title: "With text", content: "digoxin")
        withText.mentionedPatients = [nikos.id]
        try await store.notes.save(withText)
        try await expect(store, "nikos digoxin", equals: ["With text"])
        await store.close()
    }

    // MARK: - linked:

    func testLinkedOperatorCountsResolvedAndUnresolvedLinks() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Plan", content: "the plan"))
        try await store.notes.save(Note(title: "Resolved", content: "see [[Plan]]"))
        try await store.notes.save(Note(title: "Section", content: "see [[Plan#Dosing]] and [[plan|the plan]]"))
        try await store.notes.save(Note(title: "Dangling", content: "see [[Missing note]]"))
        try await store.notes.save(Note(title: "None", content: "no links"))

        try await expect(store, "linked:plan", equals: ["Resolved", "Section"], sorted: true)
        try await expect(store, "linked:[[Missing note]]", equals: ["Dangling"])
        try await expect(store, "linked:\"missing note\"", equals: ["Dangling"])
        try await expect(store, "[[Missing note]]", equals: ["Dangling"], "a link pasted from a note")
        try await expectCount(store, "linked:plan -linked:dosing", equals: 2, "#Dosing is a heading, not a title")
        try await expect(store, "linked:nothing", equals: [])
        await store.close()
    }

    // MARK: - The plain search is untouched

    func testThePlainSearchStillTreatsOperatorsAsWords() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "Digoxin note", content: "digoxin 0.125"))
        // Quick open and [[ completion go through search(); `-digoxin` is just the word.
        let plain = try await store.notes.search("-digoxin")
        XCTAssertEqual(plain.map(\.title), ["Digoxin note"])
        await store.close()
    }
}
