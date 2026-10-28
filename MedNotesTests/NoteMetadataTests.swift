import XCTest
@testable import MedNotes

final class NoteMetadataTests: XCTestCase {
    private func scan(_ text: String) -> NoteMetadata.Scan { NoteMetadata.scan(text) }
    private func tags(_ text: String) -> [String] { scan(text).tags.map(\.tag) }
    private func headings(_ text: String) -> [String] { scan(text).headings.map { "\($0.level):\($0.text)" } }
    private func blocks(_ text: String) -> [String] { scan(text).blocks.map(\.id) }

    // MARK: - Headings

    func testHeadingLevelsOneToSix() {
        let text = "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n####### Seven"
        XCTAssertEqual(headings(text), ["1:One", "2:Two", "3:Three", "4:Four", "5:Five", "6:Six"])
    }

    func testAHeadingNeedsASpaceAndText() {
        XCTAssertEqual(headings("#tag\n#\n# \n#\tTabbed"), ["1:Tabbed"])
    }

    func testAClosingRunOfHashesIsNotPartOfTheText() {
        XCTAssertEqual(headings("## Title ##\n# C#\n# Plan #2\n### ###"), ["2:Title", "1:C#", "1:Plan #2"])
    }

    func testIndentUpToThreeSpaces() {
        XCTAssertEqual(headings("   # Ok\n    # Code"), ["1:Ok"])
    }

    func testHeadingsInCodeCommentsAndFrontMatterAreNotHeadings() {
        let text = "---\n# yaml comment\n---\n```\n# in code\n```\n%% \n# in comment\n%%\n# Real"
        XCTAssertEqual(headings(text), ["1:Real"])
    }

    func testAHeadingRecordsItsLineAndKey() throws {
        let text = "Intro\n## Αξιολόγηση ΚΑΛΟΣ\nbody"
        let heading = try XCTUnwrap(scan(text).headings.first)
        XCTAssertEqual(heading.offset, 6)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: heading.offset, length: heading.length)), "## Αξιολόγηση ΚΑΛΟΣ")
        XCTAssertEqual(heading.key, WikiLinkParser.normalizedKey("αξιολογηση καλοσ"))
    }

    // MARK: - Block ids

    func testBlockIds() {
        XCTAssertEqual(blocks("A paragraph ^abc-1\n^alone\nx^2\nK^+\ntext ^bad_id\nmid ^id more"), ["abc-1", "alone"])
    }

    func testABlockIdRecordsItsLine() throws {
        let text = "one\ntwo ^id"
        XCTAssertEqual(scan(text).blocks, [NoteMetadata.BlockID(id: "id", offset: 4)])
    }

    func testBlockIdsInCodeAreIgnored() {
        XCTAssertEqual(blocks("```\ntext ^id\n```\nreal ^ok"), ["ok"])
    }

    // MARK: - Tags

    func testBasicTags() {
        XCTAssertEqual(tags("#a #b/c #tag_1 #tag-2 text #Last"), ["a", "b/c", "tag_1", "tag-2", "Last"])
    }

    func testGreekAccentedAndCombiningTags() {
        XCTAssertEqual(tags("#Έλεγχος και #κάρδια #ΐ"), ["Έλεγχος", "κάρδια", "ΐ"])
        XCTAssertEqual(tags("#ι\u{0308}\u{0301}x"), ["ι\u{0308}\u{0301}x"], "a decomposed letter is not cut short")
    }

    func testATagNeedsANonDigitAndAWhitespaceBefore() {
        XCTAssertEqual(tags("#123 #1a pt #3 a#b x#y (#paren) [a](#anchor) https://x/#frag"), ["1a"])
    }

    func testTagsStopAtPunctuation() {
        XCTAssertEqual(tags("#tag. #other, #third; #fourth)"), ["tag", "other", "third", "fourth"])
    }

    func testClinicalShorthandIndexesAsTagsLikeInObsidian() {
        XCTAssertEqual(tags("#NOF right hip, #E11 and bed #3B"), ["NOF", "E11", "3B"])
    }

    func testEscapedAndDoubledHashesAreNotTags() {
        XCTAssertEqual(tags("\\#escaped ##double # spaced"), [])
    }

    func testATagAfterAHeadingMarkerStillCounts() {
        let text = "# Heading #tag"
        XCTAssertEqual(headings(text), ["1:Heading #tag"])
        XCTAssertEqual(tags(text), ["tag"])
        XCTAssertEqual(tags("## Plan #follow-up"), ["follow-up"])
    }

    func testTagsInCodeCommentsLinksAndFrontMatterAreNotTags() {
        XCTAssertEqual(tags("`#a` and [[Note#head]] and [[#own]] #real"), ["real"])
        XCTAssertEqual(tags("```\n#fenced\n```\n%% #comment %%\n<!-- #html -->\n#ok"), ["ok"])
        XCTAssertEqual(tags("---\n# not #a tag\ntags: [x]\n---\n#body"), ["body"])
    }

    func testAnInlineCodeSpanOnAVeryShortNoteIsStillCode() {
        XCTAssertEqual(tags("`#a`"), [])
        XCTAssertEqual(tags("`#a` #b"), ["b"])
    }

    func testAFenceInsideFrontMatterDoesNotHideTheBody() {
        let text = "---\nnote: ```\nk: v\n---\n#body\n[[x]]"
        let result = scan(text)
        XCTAssertEqual(result.tags.map(\.tag), ["body"])
        XCTAssertEqual(WikiLinkParser.scan(text).links.map(\.target), ["x"])
    }

    func testTagRangesAndKeys() throws {
        let text = "see #Cardio/Έλεγχος now"
        let tag = try XCTUnwrap(scan(text).tags.first)
        XCTAssertEqual((text as NSString).substring(with: tag.range), "#Cardio/Έλεγχος")
        XCTAssertEqual(tag.key, WikiLinkParser.normalizedKey("cardio/ελεγχοσ"))
    }

    func testTagsAtTheStartAndEndOfText() {
        XCTAssertEqual(tags("#only"), ["only"])
        XCTAssertEqual(tags("end #last"), ["last"])
        XCTAssertEqual(tags("a\n#next\n\t#tabbed"), ["next", "tabbed"])
    }

    // MARK: - Properties travel with the scan

    func testPropertiesComeWithTheScan() throws {
        let result = scan("---\ntags: [a]\nstatus: draft\n---\nBody")
        XCTAssertEqual(result.properties?.properties.map(\.key), ["tags", "status"])
        XCTAssertNil(scan("---\nThe patient is stable.\n---\n#x").properties)
        XCTAssertEqual(scan("---\nThe patient is stable.\n---\n#x").tags.map(\.tag), ["x"], "prose between rules is text")
    }

    func testTheLinkParserFixes() throws {
        // The alias belongs to the title before it.
        let link = try XCTUnwrap(WikiLinkParser.scan("[[Plan #2|see]]").links.first)
        XCTAssertEqual(link.head, "Plan #2")
        XCTAssertEqual(link.inner, "Plan #2|see")
        XCTAssertEqual(try XCTUnwrap(WikiLinkParser.scan("[[A]]").links.first).head, "A")
        // Short notes are scanned too.
        XCTAssertEqual(WikiLinkParser.scan("`[[a]]`").links, [])
        XCTAssertEqual(WikiLinkParser.scan("`x`").protectedRanges.count, 1)
    }

    func testAHeadingWithABlockIDIsTheHeadingWithoutIt() {
        let scan = NoteMetadata.scan("## Plan ^plan\n\ntext ^t\n# ^only")
        XCTAssertEqual(scan.headings.map(\.text), ["Plan", "^only"])
        XCTAssertEqual(scan.headings.first?.key, "plan")
        XCTAssertEqual(Set(scan.blocks.map(\.id)), ["plan", "t", "only"], "the id is still a block id")
    }
}

