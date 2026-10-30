import XCTest
@testable import MedNotes

final class FrontMatterYAMLTests: XCTestCase {
    private func parse(_ lines: String...) -> PropertySet? {
        FrontMatterYAML.parse((["---"] + lines + ["---", "Body"]).joined(separator: "\n"))
    }

    private func value(_ key: String, _ lines: String...) -> PropertyValue? {
        let text = (["---"] + lines + ["---", "Body"]).joined(separator: "\n")
        return FrontMatterYAML.parse(text)?.property(forKey: key)?.value
    }

    // MARK: - Types

    func testEachKindOfValue() throws {
        let set = try XCTUnwrap(parse(
            "title: Visit",
            "count: 12",
            "ratio: -0.5",
            "done: true",
            "seen: 2026-10-27",
            "at: 2026-10-27T14:30",
            "empty:",
            "tags: [a, \"b c\", 'd']",
            "aliases:",
            "  - x",
            "  - \"y: z\""))
        let byKey = Dictionary(uniqueKeysWithValues: set.properties.map { ($0.key, $0.value) })
        XCTAssertEqual(byKey["title"], .text("Visit"))
        XCTAssertEqual(byKey["count"], .number("12"))
        XCTAssertEqual(byKey["ratio"], .number("-0.5"))
        XCTAssertEqual(byKey["done"], .checkbox(true))
        XCTAssertEqual(byKey["seen"], .date("2026-10-27"))
        XCTAssertEqual(byKey["at"], .dateTime("2026-10-27T14:30"))
        XCTAssertEqual(byKey["empty"], .empty)
        XCTAssertEqual(byKey["tags"], .list(["a", "b c", "d"]))
        XCTAssertEqual(byKey["aliases"], .list(["x", "y: z"]))
        XCTAssertTrue(set.properties.allSatisfy(\.isEditable))
    }

    func testANumberIsOnlyANumberIfItWritesBackIdentically() {
        for text in ["00123", "1.50", "+5", "1e3", "1_000", "-0", "1234567890123456", ".5", "5.", "0x10", "1,5"] {
            XCTAssertEqual(value("n", "n: \(text)"), .text(text), text)
        }
        for number in ["0", "7", "-7", "0.5", "-0.25", "123456789012345", "10"] {
            XCTAssertEqual(value("n", "n: \(number)"), .number(number), number)
        }
        XCTAssertEqual(value("n", "n: \"5\""), .text("5"), "a quoted number is text")
    }

    func testBooleansAreOnlyTrueAndFalse() {
        XCTAssertEqual(value("a", "a: TRUE"), .checkbox(true))
        XCTAssertEqual(value("a", "a: False"), .checkbox(false))
        XCTAssertEqual(value("a", "a: yes"), .text("yes"))
        XCTAssertEqual(value("a", "a: off"), .text("off"))
        XCTAssertEqual(value("a", "a: ~"), .empty)
        XCTAssertEqual(value("a", "a: null"), .empty)
    }

    func testDatesAreValidated() {
        XCTAssertEqual(value("d", "d: 2024-02-29"), .date("2024-02-29"))
        XCTAssertEqual(value("d", "d: 2026-02-29"), .text("2026-02-29"))
        XCTAssertEqual(value("d", "d: 2026-13-01"), .text("2026-13-01"))
        XCTAssertEqual(value("d", "d: 2026-10-27T09:05:30"), .dateTime("2026-10-27T09:05:30"))
        XCTAssertEqual(value("d", "d: 2026-10-27T25:00"), .text("2026-10-27T25:00"))
        XCTAssertEqual(value("d", "d: 2026-10-27T14:30Z"), .text("2026-10-27T14:30Z"))
        XCTAssertEqual(value("d", "d: 2026-10-27T14:30+02:00"), .text("2026-10-27T14:30+02:00"))
    }

    func testQuotedScalars() {
        XCTAssertEqual(value("q", "q: \"a\\nb \\\"c\\\" \\\\ \\u00e9\""), .text("a\nb \"c\" \\ é"))
        XCTAssertEqual(value("q", "q: 'it''s'"), .text("it's"))
        XCTAssertEqual(value("q", "q: \"unterminated"), .unsupported)
        XCTAssertEqual(value("q", "q: \"bad\\x\""), .unsupported)
        XCTAssertEqual(value("q", "q: \"a\" trailing"), .unsupported)
    }

    func testCommentsAreKeptApart() throws {
        let set = try XCTUnwrap(parse("k: v # note", "u: \"a # b\" # c", "tags: #a"))
        XCTAssertEqual(set.property(forKey: "k")?.value, .text("v"))
        XCTAssertEqual(set.property(forKey: "k")?.comment, "note")
        XCTAssertEqual(set.property(forKey: "u")?.value, .text("a # b"))
        XCTAssertEqual(set.property(forKey: "u")?.comment, "c")
        // `tags: #a` is a YAML comment, so the value is empty, as in Obsidian.
        XCTAssertEqual(set.property(forKey: "tags")?.value, .list([]))
    }

    func testAQuoteInAFlowListAndADoubledSingleQuoteHideAHash() throws {
        let set = try XCTUnwrap(parse("tags: [a, \"b #c\"] # note", "t: 'it''s #1'"))
        XCTAssertEqual(set.property(forKey: "tags")?.value, .list(["a", "b #c"]))
        XCTAssertEqual(set.property(forKey: "tags")?.comment, "note")
        XCTAssertEqual(set.property(forKey: "t")?.value, .text("it's #1"))
    }

    func testListKeys() throws {
        let set = try XCTUnwrap(parse(
            "tags: a, b",
            "aliases: single",
            "cssclasses:",
            "tag: x"))
        XCTAssertEqual(set.property(forKey: "tags")?.value, .list(["a", "b"]))
        XCTAssertEqual(set.property(forKey: "aliases")?.value, .list(["single"]))
        XCTAssertEqual(set.property(forKey: "cssclasses")?.value, .list([]))
        XCTAssertEqual(set.property(forKey: "tag")?.value, .list(["x"]))
        XCTAssertEqual(set.property(forKey: "tag")?.isEditable, false, "the singular spellings are read-only")
        let hashed = FrontMatterYAML.parse("---\ntags:\n  - \"#cardio\"\n  - ward\n---\n")
        XCTAssertEqual(hashed?.property(forKey: "tags")?.value, .list(["cardio", "ward"]))
        let flow = FrontMatterYAML.parse("---\ntags: [cardio, \"#ward\"]\n---\n")
        XCTAssertEqual(flow?.property(forKey: "tags")?.value, .list(["cardio", "ward"]), "a flow list drops the # too")
    }

    // MARK: - What it will not touch

    func testUnsupportedEntriesKeepTheirLines() throws {
        let text = """
        ---
        meta:
          a: 1
          b: 2
        note: |
          block scalar
        flow: [a,
          b]
        anchor: &x value
        map: {a: 1}
        after: ok
        ---
        Body
        """
        let set = try XCTUnwrap(FrontMatterYAML.parse(text))
        XCTAssertEqual(set.properties.map(\.key), ["meta", "note", "flow", "anchor", "map", "after"])
        XCTAssertEqual(set.properties.map(\.isEditable), [false, false, false, false, false, true])
        XCTAssertEqual(set.property(forKey: "meta")?.text, "meta:\n  a: 1\n  b: 2\n")
        XCTAssertEqual(set.property(forKey: "flow")?.text, "flow: [a,\n  b]\n")
    }

    func testDuplicateKeysAreReadOnly() throws {
        let set = try XCTUnwrap(parse("a: 1", "b: 2", "A: 3"))
        XCTAssertEqual(set.properties.map(\.isEditable), [false, true, false])
        XCTAssertEqual(set.properties.map(\.id), ["a#0", "b#0", "a#1"])
    }

    func testAQuotedKeyIsReadButNotEdited() throws {
        let set = try XCTUnwrap(parse("\"a b\": 1"))
        XCTAssertEqual(set.properties.first?.isEditable, false)
    }

    func testStrayIndentedLinesAtTheTopMakeEverythingReadOnly() throws {
        let set = try XCTUnwrap(parse("  orphan", "k: v"))
        XCTAssertTrue(set.properties.allSatisfy { !$0.isEditable })
    }

    func testACommentInsideAListMakesTheEntryReadOnly() throws {
        let set = try XCTUnwrap(parse("tags:", "  - a", "# between", "  - b"))
        XCTAssertEqual(set.property(forKey: "tags")?.isEditable, false)
        XCTAssertEqual(set.property(forKey: "tags")?.text, "tags:\n  - a\n# between\n  - b\n")
    }

    func testTooManyEntriesAreTruncatedAndNotEditable() throws {
        let lines = (0..<250).map { "k\($0): v" }
        let text = (["---"] + lines + ["---", ""]).joined(separator: "\n")
        let set = try XCTUnwrap(FrontMatterYAML.parse(text))
        XCTAssertTrue(set.truncated)
        XCTAssertEqual(set.properties.count, FrontMatterYAML.maxProperties)
        XCTAssertTrue(set.properties.allSatisfy { !$0.isEditable })
        XCTAssertNil(FrontMatterEditor.edit(.set(key: "k0", value: .text("x")), in: text))
    }

    func testRangesCoverTheirLinesExactly() throws {
        let text = "---\r\na: 1\r\n\r\n# gap\r\nb:\r\n  - x\r\n  - y\r\nc: 3\r\n---\r\nBody"
        let ns = text as NSString
        let set = try XCTUnwrap(FrontMatterYAML.parse(text))
        XCTAssertEqual(set.properties.map(\.text), ["a: 1\r\n", "b:\r\n  - x\r\n  - y\r\n", "c: 3\r\n"])
        for property in set.properties {
            XCTAssertEqual(ns.substring(with: property.range), property.text)
        }
    }

    // MARK: - Editing

    private func edit(_ operation: FrontMatterEditor.Operation, _ text: String, expecting: String? = nil) -> String? {
        FrontMatterEditor.edit(operation, in: text, expecting: expecting)
            .map { FrontMatterEditor.apply($0, to: text) }
    }

    func testSetChangesOnlyThatEntryAndKeepsItsComment() {
        let text = "---\n# keep\nstatus: draft # in review\n\nowner: Dr. Ana\n---\nBody"
        XCTAssertEqual(
            edit(.set(key: "status", value: .text("final")), text),
            "---\n# keep\nstatus: final # in review\n\nowner: Dr. Ana\n---\nBody")
    }

    func testSetAListUsesBlockStyleAndReplacesAnOldList() {
        let text = "---\ntags: [a, b]\nx: 1\n---\n"
        XCTAssertEqual(
            edit(.set(key: "tags", value: .list(["a", "b c", "yes"])), text),
            "---\ntags:\n  - a\n  - b c\n  - \"yes\"\nx: 1\n---\n")
        let block = "---\ntags:\n  - a\n  - b\nx: 1\n---\n"
        XCTAssertEqual(
            edit(.set(key: "tags", value: .list(["z"])), block),
            "---\ntags:\n  - z\nx: 1\n---\n")
        XCTAssertEqual(edit(.set(key: "tags", value: .list([])), block), "---\ntags: []\nx: 1\n---\n")
    }

    func testRemove() {
        let text = "---\na: 1\nb:\n  - x\nc: 3\n---\nBody"
        XCTAssertEqual(edit(.remove(key: "b"), text), "---\na: 1\nc: 3\n---\nBody")
        XCTAssertNil(edit(.remove(key: "missing"), text))
    }

    func testAddingAKeyGoesBeforeTheClosingFence() {
        XCTAssertEqual(
            edit(.set(key: "new", value: .checkbox(true)), "---\na: 1\n---\nBody"),
            "---\na: 1\nnew: true\n---\nBody")
        XCTAssertEqual(
            edit(.set(key: "new", value: .empty), "---\n---\nBody"),
            "---\nnew:\n---\nBody")
    }

    func testCreatingFrontMatterWhereThereIsNone() {
        XCTAssertEqual(edit(.set(key: "k", value: .text("v")), "Body"), "---\nk: v\n---\nBody")
        XCTAssertEqual(edit(.set(key: "k", value: .text("v")), ""), "---\nk: v\n---\n")
        XCTAssertEqual(edit(.set(key: "k", value: .text("v")), "Line one\r\nLine two"),
                       "---\r\nk: v\r\n---\r\nLine one\r\nLine two")
        XCTAssertEqual(edit(.set(key: "k", value: .text("v")), "\u{FEFF}Body"), "\u{FEFF}---\nk: v\n---\nBody")
    }

    func testCreatingAboveTwoRulesAroundProseLeavesTheProseAlone() throws {
        let body = "---\nThe patient is stable.\n---\nPlan."
        let result = try XCTUnwrap(edit(.set(key: "k", value: .text("v")), body))
        XCTAssertEqual(result, "---\nk: v\n---\n" + body)
        XCTAssertEqual(FrontMatterYAML.parse(result)?.properties.map(\.key), ["k"])
    }

    func testACRLFBlockKeepsCRLF() {
        let text = "---\r\na: 1\r\nb: 2\r\n---\r\nBody"
        XCTAssertEqual(edit(.set(key: "a", value: .number("9")), text), "---\r\na: 9\r\nb: 2\r\n---\r\nBody")
        XCTAssertEqual(edit(.set(key: "c", value: .list(["x"])), text),
                       "---\r\na: 1\r\nb: 2\r\nc:\r\n  - x\r\n---\r\nBody")
    }

    func testEditingAroundAnUnsupportedBlockLeavesItByteIdentical() throws {
        let text = "---\nmeta:\n  a: 1\nnote: |\n  keep me\nstatus: draft\n---\nBody"
        let result = try XCTUnwrap(edit(.set(key: "status", value: .text("final")), text))
        XCTAssertEqual(result, "---\nmeta:\n  a: 1\nnote: |\n  keep me\nstatus: final\n---\nBody")
        XCTAssertNil(edit(.set(key: "meta", value: .text("x")), text))
        XCTAssertNil(edit(.remove(key: "note"), text))
    }

    func testAnEditIsRefusedWhenTheLinesChangedUnderIt() {
        let text = "---\nstatus: draft\n---\n"
        XCTAssertNotNil(edit(.set(key: "status", value: .text("x")), text, expecting: "status: draft\n"))
        XCTAssertNil(edit(.set(key: "status", value: .text("x")), text, expecting: "status: other\n"))
        XCTAssertNil(edit(.remove(key: "status"), text, expecting: "status: other\n"))
    }

    func testAKeyThatDiffersOnlyInCaseIsNotAddedBesideTheExistingOne() {
        let text = "---\nstatus: draft\n---\n"
        XCTAssertNil(edit(.set(key: "Status", value: .text("x")), text),
                     "it would make both entries duplicates, and so read-only")
        XCTAssertNotNil(edit(.set(key: "status", value: .text("x")), text))
    }

    func testKeysWithLineSeparatorsAreRefused() {
        for key in ["a\u{2028}b", "a\u{85}b", "a\u{2029}b"] {
            XCTAssertNil(edit(.set(key: key, value: .text("v")), "---\n---\n"), key.debugDescription)
        }
    }

    func testKeysThatCannotBeWrittenAreRefused() {
        for key in ["", " a", "a ", "a: b", "- a", "#a", "\"a\"", "a #b", "?a", "[a]", "a\nb"] {
            XCTAssertNil(edit(.set(key: key, value: .text("v")), "---\n---\n"), key.debugDescription)
        }
        XCTAssertNotNil(edit(.set(key: "patient id", value: .text("v")), "---\n---\n"), "a key with a space is fine")
    }

    func testTrickyTextSurvivesAWriteAndARead() throws {
        let samples = [
            "plain", "", " leading", "trailing ", "yes", "No", "true", "null", "~", "123", "00123", "1.5",
            "2026-10-27", "2026-10-27T10:00", "- dash", "? q", ": colon", "a: b", "a #b", "#hash", "&anchor",
            "*star", "!tag", "|pipe", ">fold", "'single'", "\"double\"", "%pct", "@at", "`tick`", "[x]", "{x}",
            "line\nbreak", "cr\rhere", "tab\there", "a\u{2028}b", "a\u{2029}b", "a\u{85}b", "back\\slash", "unicode é ΐ 😀", "ends with:", "---", "a\n---\nb",
        ]
        for sample in samples {
            let text = try XCTUnwrap(edit(.set(key: "k", value: .text(sample)), "---\n---\nBody"), sample)
            XCTAssertEqual(FrontMatterYAML.parse(text)?.property(forKey: "k")?.value, .text(sample), sample.debugDescription)
            // However the value is written, the front matter still closes where it should.
            XCTAssertEqual(FrontMatter.properties(in: text).map { (text as NSString).substring(from: NSMaxRange($0.range)) }, "Body")
        }
    }

    func testAPhoneNumberKeepsItsLeadingZero() throws {
        let text = try XCTUnwrap(edit(.set(key: "phone", value: .number("0691234567")), "---\n---\n"))
        XCTAssertEqual(FrontMatterYAML.parse(text)?.property(forKey: "phone")?.value, .text("0691234567"))
    }

    // MARK: - Fuzz

    /// A deterministic generator, so a failure can be reproduced.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private static let pieces = [
        "---", "---", "---", "\n", "\n", "\r\n", "\r", "\u{2028}", " ", "  ", "\t", ":", ": ", "#", " #", "- ",
        "[", "]", "{", "}", "\"", "'", "\\", "|", ">", "&", "*", "!", "%", "@", "`", "```", "~~~", "%%", "<!--", "-->",
        "[[", "]]", "![[", "^", "^id", "a", "key", "tags", "aliases", "1", "0", "-0.5", "true", "yes", "~", "2026-10-27",
        "2026-10-27T10:00", "é", "ΐ", "ς", "😀", "\u{FEFF}", "\u{0301}", "\u{0}", "\u{7F}", "#tag", "# Head", "## ",
    ]

    private func randomText(_ rng: inout SplitMix64) -> String {
        var s = rng.int(4) == 0 ? "---\n" : ""
        for _ in 0..<rng.int(60) { s += Self.pieces[rng.int(Self.pieces.count)] }
        if rng.int(3) == 0 { s += "\n---\n" }
        return s
    }

    private static let lineTemplates = [
        "title: Visit", "k:", "empty:", "n: 12", "x: -0.5", "b: true", "d: 2026-10-27", "dt: 2026-10-27T10:30",
        "tags: [a, \"b c\", 'd']", "tags:", "  - cardio", "  - \"ward 3\"", "aliases: one, two", "q: \"quoted\"",
        "s: 'single'", "note: text # comment", "# a comment", "", "mrn: 00123", "name: Dr. Ana", "path: a/b",
        "colon: a: b", "meta:", "  nested: 1", "blk: |", "  kept", "pt id: 7", "e: é ΐ 😀", "url: https://x/#f",
    ]

    /// A front matter block built from YAML-looking lines, then roughened.
    private func randomProperties(_ rng: inout SplitMix64) -> String {
        let ending = ["\n", "\n", "\r\n"][rng.int(3)]
        var lines = (0..<(1 + rng.int(8))).map { _ in Self.lineTemplates[rng.int(Self.lineTemplates.count)] }
        if rng.int(3) == 0 {
            let at = rng.int(lines.count)
            lines[at] += Self.pieces[rng.int(Self.pieces.count)]
        }
        return (["---"] + lines + ["---", "Body #tag [[x]]"]).joined(separator: ending)
    }

    func testNothingTrapsOnArbitraryText() {
        var rng = SplitMix64(state: 20261028)
        for _ in 0..<4000 {
            let text = randomText(&rng)
            let ns = text as NSString
            _ = FrontMatter.block(in: text)
            let scan = NoteMetadata.scan(text)
            _ = WikiLinkParser.scan(text)
            _ = MarkdownStyler.spans(in: text)
            _ = MarkdownPreview.parseBlocks(text)
            _ = DisplayCopy.preview(text)

            for heading in scan.headings {
                XCTAssertTrue(heading.offset >= 0 && heading.offset + heading.length <= ns.length, text.debugDescription)
            }
            for tag in scan.tags {
                XCTAssertTrue(tag.range.location >= 0 && NSMaxRange(tag.range) <= ns.length, text.debugDescription)
                XCTAssertEqual(ns.substring(with: tag.range), "#" + tag.tag)
            }
            if let set = scan.properties {
                var last = set.block.innerRange.location
                for property in set.properties {
                    XCTAssertTrue(property.range.location >= last && NSMaxRange(property.range) <= NSMaxRange(set.block.innerRange), text.debugDescription)
                    XCTAssertEqual(ns.substring(with: property.range), property.text)
                    last = NSMaxRange(property.range)
                }
            }
        }
    }

    func testAnEditChangesNothingOutsideItsRangeAndReadsBack() {
        var rng = SplitMix64(state: 77)
        var edited = 0
        for round in 0..<4000 {
            let text = round % 2 == 0 ? randomProperties(&rng) : randomText(&rng)
            guard let before = FrontMatterYAML.parse(text) else { continue }
            for property in before.properties where property.isEditable && property.value != .unsupported {
                guard let edit = FrontMatterEditor.edit(.set(key: property.key, value: property.value), in: text) else { continue }
                edited += 1
                let ns = text as NSString
                let after = FrontMatterEditor.apply(edit, to: text)
                XCTAssertEqual((after as NSString).substring(to: edit.range.location), ns.substring(to: edit.range.location))
                XCTAssertEqual(
                    (after as NSString).substring(from: edit.range.location + (edit.replacement as NSString).length),
                    ns.substring(from: NSMaxRange(edit.range)))
                let reparsed = FrontMatterYAML.parse(after)?.property(forKey: property.key)
                XCTAssertEqual(reparsed?.value, property.value, "\(text.debugDescription) -> \(after.debugDescription)")
                // Every other entry is exactly as it was.
                let others = before.properties.filter { $0.id != property.id }.map(\.text)
                let othersAfter = (FrontMatterYAML.parse(after)?.properties ?? []).filter { $0.id != property.id }.map(\.text)
                XCTAssertEqual(othersAfter, others, text.debugDescription)
            }
        }
        XCTAssertGreaterThan(edited, 100, "the fuzz should actually exercise edits")
    }
}
