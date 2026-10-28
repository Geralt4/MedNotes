import XCTest
@testable import MedNotes

/// Tags, properties, headings and aliases as the rest of the app reads them.
final class MetadataQueriesTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-queries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeStore() throws -> AppStore {
        try AppStore.testStore(dataRoot: DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true)))
    }

    // MARK: - Tags

    func testTagsAreTheUnionOfTheFieldTheTextAndTheProperty() async throws {
        let store = try makeStore()
        let a = Note(title: "A", content: "---\ntags: [Cardio, ward]\n---\nSeen #cardio today", tags: ["#cardio", "field-only"])
        let b = Note(title: "B", content: "#Cardio/Ward and #Cardio again")
        let c = Note(title: "C", content: "#Cardio", tags: [])
        for note in [a, b, c] { try await store.notes.save(note) }

        let counts = try await store.notes.tagCounts()
        let byKey = Dictionary(uniqueKeysWithValues: counts.map { ($0.key, $0) })
        XCTAssertEqual(byKey["cardio"]?.count, 3, "a note counts once however many sources name the tag")
        XCTAssertEqual(byKey["cardio/ward"]?.count, 1)
        XCTAssertEqual(byKey["ward"]?.count, 1)
        XCTAssertEqual(byKey["field-only"]?.count, 1)
        // The commonest spelling is shown: "Cardio" appears most.
        XCTAssertEqual(byKey["cardio"]?.display, "Cardio")
        XCTAssertEqual(byKey["cardio/ward"]?.display, "Cardio/Ward")
        await store.close()
    }

    func testFilteringByATagIncludesNestedTagsAndAgreesWithTheCounts() async throws {
        let store = try makeStore()
        let parent = Note(title: "Parent", content: "#cardio")
        let child = Note(title: "Child", content: "#cardio/ward")
        let other = Note(title: "Other", content: "#cardiology")
        for note in [parent, child, other] { try await store.notes.save(note) }

        let cardio = try await store.notes.list(search: "", tagKey: "cardio")
        XCTAssertEqual(Set(cardio.map(\.id)), [parent.id, child.id], "#cardiology is a different tag")
        let nested = try await store.notes.list(search: "", tagKey: "cardio/ward")
        XCTAssertEqual(nested.map(\.id), [child.id])
        let counts = try await store.notes.tagCounts()
        XCTAssertEqual(counts.first { $0.key == "cardio" }?.count, 2)
        await store.close()
    }

    func testAnUnderscoreInATagIsNotAWildcard() async throws {
        let store = try makeStore()
        let literal = Note(title: "Literal", content: "#a_b")
        let lookalike = Note(title: "Lookalike", content: "#axb")
        for note in [literal, lookalike] { try await store.notes.save(note) }
        let found = try await store.notes.list(search: "", tagKey: "a_b")
        XCTAssertEqual(found.map(\.id), [literal.id])
        await store.close()
    }

    func testAFilterIsCombinedWithASearchText() async throws {
        let store = try makeStore()
        let both = Note(title: "Both", content: "digoxin dose #cardio")
        let onlyTag = Note(title: "Tag", content: "#cardio alone")
        let onlyText = Note(title: "Text", content: "digoxin elsewhere")
        for note in [both, onlyTag, onlyText] { try await store.notes.save(note) }

        let result = try await store.notes.list(search: "digoxin", tagKey: "cardio")
        XCTAssertEqual(result.map(\.id), [both.id])
        let everything = try await store.notes.list(search: "", tagKey: nil)
        XCTAssertEqual(everything.count, 3)
        await store.close()
    }

    func testGreekTagsMatchAcrossCaseAndAccents() async throws {
        let store = try makeStore()
        let note = Note(title: "Greek", content: "Ο ασθενής #Έλεγχος")
        try await store.notes.save(note)
        let found = try await store.notes.list(search: "", tagKey: WikiLinkParser.normalizedKey("ΕΛΕΓΧΟΣ"))
        XCTAssertEqual(found.map(\.id), [note.id])
        await store.close()
    }

    // MARK: - Properties, headings, aliases

    func testPropertyKeysAlreadyInUse() async throws {
        let store = try makeStore()
        try await store.notes.save(Note(title: "1", content: "---\nstatus: draft\ncount: 2\nmeta:\n  a: 1\n---\n"))
        try await store.notes.save(Note(title: "2", content: "---\nStatus: final\ndone: true\n---\n"))
        let keys = try await store.notes.propertyKeys()
        XCTAssertEqual(keys.first, PropertyKeyUsage(key: "Status", kind: "text", notes: 2),
                       "names match without regard to case; the first spelling in order is shown")
        XCTAssertEqual(Set(keys.map(\.kind)), ["text", "number", "checkbox"], "unsupported values are not offered")
        XCTAssertEqual(keys.first { $0.kind == "number" }?.key, "count")
        await store.close()
    }

    func testHeadingsOfANote() async throws {
        let store = try makeStore()
        let note = Note(title: "H", content: "# One\ntext\n## Two")
        try await store.notes.save(note)
        let headings = try await store.notes.headings(noteId: note.id)
        XCTAssertEqual(headings, [HeadingRow(level: 1, text: "One", offset: 0), HeadingRow(level: 2, text: "Two", offset: 11)])
        await store.close()
    }

    func testAliasMatchesAndKeys() async throws {
        let store = try makeStore()
        let note = Note(title: "Hypertension protocol", content: "---\naliases: [HTN, \"High Blood Pressure\"]\n---\n")
        try await store.notes.save(note)
        let hit = try await store.notes.aliasMatches("htn")
        XCTAssertEqual(hit, [AliasMatch(noteId: note.id, title: "Hypertension protocol", alias: "HTN")])
        let partial = try await store.notes.aliasMatches("blood pres")
        XCTAssertEqual(partial.map(\.alias), ["High Blood Pressure"])
        let none = try await store.notes.aliasMatches("zzz")
        XCTAssertTrue(none.isEmpty)
        let keys = try await store.db.aliasKeys(noteId: note.id)
        XCTAssertEqual(keys, ["htn", "high blood pressure"])
        await store.close()
    }

    func testUnlinkedMentionsAlsoMatchAnAliasButNotAnotherNotesAliasLine() async throws {
        let store = try makeStore()
        let target = Note(title: "Hypertension protocol", content: "---\naliases: [HTN]\n---\nbody")
        let mentions = Note(title: "Mentions", content: "Follow up HTN next week")
        let alsoAlias = Note(title: "Also", content: "---\naliases: [HTN]\n---\nnothing else")
        let linked = Note(title: "Linked", content: "see [[Hypertension protocol|HTN]]")
        for note in [target, mentions, alsoAlias, linked] { try await store.notes.save(note) }
        let found = try await store.linking.unlinkedMentions(noteId: target.id)
        XCTAssertEqual(found.map(\.noteId), [mentions.id])
        await store.close()
    }

    // MARK: - Heading and block warnings

    func testALinkToAMissingHeadingOrBlockIsFlaggedPerLink() async throws {
        let store = try makeStore()
        let target = Note(title: "A", content: "# H1\ntext ^b1\n# Plan #2\n")
        let source = Note(title: "S", content: "[[A#H1]] [[A#Nope]] [[A#^b1]] [[A#^zz]] [[A#Plan #2]] [[#Own]]")
        let ok = Note(title: "Ok", content: "[[A#H1]] [[A#^b1]]")
        let patient = {
            var profile = PatientProfile(firstName: "Maria", lastName: "Papadopoulou", dateOfBirth: Date(timeIntervalSince1970: 0))
            profile.amka = "70000000001"
            return Patient(profile: profile)
        }()
        let viaPatient = Note(title: "P", content: "[[Maria Papadopoulou#nothing]]")
        try await store.patients.save(patient)
        for note in [target, source, ok, viaPatient] { try await store.notes.save(note) }

        // `[[A#H1]]` and `[[A#Nope]]` point at one note; the warning is per link, merged.
        let links = try await store.linking.outgoingLinks(noteId: source.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.warning, .missingHeading)

        let clean = try await store.linking.outgoingLinks(noteId: ok.id)
        XCTAssertEqual(clean.count, 1)
        XCTAssertNil(clean.first?.warning)

        let patientLinks = try await store.linking.outgoingLinks(noteId: viaPatient.id)
        XCTAssertNil(patientLinks.first?.warning, "a patient has no headings to check")
        await store.close()
    }

    func testEachMissingTargetOfOneNoteIsCheckedOnItsOwn() async throws {
        let store = try makeStore()
        let target = Note(title: "A", content: "# H1\ntext ^b1\n# Plan #2\n")
        let onlyGood = Note(title: "Good", content: "[[A#H1]] [[A#^b1]] [[A#Plan #2]]")
        let blockMissing = Note(title: "Block", content: "[[A#H1]] [[A#^zz]]")
        for note in [target, onlyGood, blockMissing] { try await store.notes.save(note) }
        let good = try await store.linking.outgoingLinks(noteId: onlyGood.id)
        XCTAssertNil(good.first?.warning, "H1, ^b1 and a heading containing a # all exist")
        let bad = try await store.linking.outgoingLinks(noteId: blockMissing.id)
        XCTAssertEqual(bad.first?.warning, .missingBlock)
        await store.close()
    }
}
