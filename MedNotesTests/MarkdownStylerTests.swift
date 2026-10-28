import XCTest
@testable import MedNotes

/// Which parts of a note body the editor draws differently.
final class MarkdownStylerTests: XCTestCase {
    private typealias Role = MarkdownStyler.Span.Role

    /// The text each span of `role` covers, in order.
    private func texts(_ role: Role, in text: String) -> [String] {
        let ns = text as NSString
        return MarkdownStyler.spans(in: text).filter { $0.role == role }.map { ns.substring(with: $0.range) }
    }

    func testHeadingLevels() {
        for level in 1...6 {
            let text = String(repeating: "#", count: level) + " Title"
            XCTAssertEqual(texts(.heading(level: level), in: text), [text])
            XCTAssertEqual(texts(.syntaxMarker, in: text), [String(repeating: "#", count: level)])
        }
        XCTAssertTrue(MarkdownStyler.spans(in: "####### seven").isEmpty)
        XCTAssertEqual(texts(.heading(level: 1), in: "#hashtag"), [], "a heading needs the space")
        XCTAssertEqual(texts(.tag, in: "#hashtag"), ["#hashtag"], "without the space it is a tag")
    }

    func testBoldAndItalic() {
        let text = "Patient reports **improved** dyspnea, _mild_ cough and *dry* skin."
        XCTAssertEqual(texts(.bold, in: text), ["improved"])
        XCTAssertEqual(texts(.italic, in: text), ["mild", "dry"])
        XCTAssertEqual(texts(.syntaxMarker, in: text), ["**", "**", "_", "_", "*", "*"])
    }

    func testBoldIsNotAlsoItalic() {
        XCTAssertEqual(texts(.italic, in: "**strong**"), [])
        XCTAssertEqual(texts(.italic, in: "__strong__"), [])
    }

    func testItalicInsideBoldAndBoldInsideHeading() {
        XCTAssertEqual(texts(.italic, in: "**very *much* so**"), ["much"])
        let heading = "## Plan **today**"
        XCTAssertEqual(texts(.heading(level: 2), in: heading), [heading])
        XCTAssertEqual(texts(.bold, in: heading), ["today"])
    }

    func testUnclosedAndInWordMarkersStayPlain() {
        XCTAssertTrue(MarkdownStyler.spans(in: "half **open").isEmpty)
        XCTAssertTrue(MarkdownStyler.spans(in: "lab_value_high and 2 * 3 * 4").isEmpty)
        XCTAssertTrue(MarkdownStyler.spans(in: "** spaced **").isEmpty)
    }

    func testWikiLink() {
        let text = "See [[Γεώργιος Παπαδόπουλος]] today"
        XCTAssertEqual(texts(.wikiLink, in: text), ["Γεώργιος Παπαδόπουλος"])
        XCTAssertEqual(texts(.syntaxMarker, in: text), ["[[", "]]"])
    }

    func testWikiLinkStylingFollowsTheLinkIndex() {
        let text = "a [[One]] `[[In code]]`\n```\n[[Fenced]]\n```\n![[Embed|alias]] [[Plan #2|see]]"
        let parsed = WikiLinkParser.scan(text).links
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(texts(.wikiLink, in: text), ["One", "Embed|alias", "Plan #2|see"],
                       "links in code are not styled, because they are not indexed")
        XCTAssertEqual(texts(.syntaxMarker, in: "![[x]]"), ["![[", "]]"])
        let styled = MarkdownStyler.spans(in: text).filter { $0.role == .wikiLink }
        for (span, link) in zip(styled, parsed) {
            XCTAssertEqual(NSIntersectionRange(span.range, link.range), span.range)
        }
    }

    func testTagsAreStyledWhereTheyAreIndexed() {
        XCTAssertEqual(texts(.tag, in: "seen #cardio/ward and #Έλεγχος, not a#b or `#code`"), ["#cardio/ward", "#Έλεγχος"])
        XCTAssertEqual(texts(.tag, in: "```\n#fenced\n```\n#real"), ["#real"])
        XCTAssertEqual(texts(.tag, in: "## Plan #follow-up"), ["#follow-up"])
        XCTAssertEqual(texts(.tag, in: "---\n# yaml comment\n---\n#body"), ["#body"])
    }

    func testMarkdownInsideAFenceIsNotStyled() {
        let text = "# Real\n```\n# not a heading\n**not bold**\n```\n## Also real"
        XCTAssertEqual(texts(.heading(level: 1), in: text), ["# Real"])
        XCTAssertEqual(texts(.heading(level: 2), in: text), ["## Also real"])
        XCTAssertEqual(texts(.bold, in: text), [])
    }

    func testFrontMatterOnlyAtTheVeryStart() {
        let text = "---\ntitle: Cardiology\ntags: [cardio]\n---\n\n# Assessment"
        XCTAssertEqual(texts(.frontMatter, in: text), ["---\ntitle: Cardiology\ntags: [cardio]\n---\n"])
        XCTAssertEqual(texts(.heading(level: 1), in: text), ["# Assessment"])

        XCTAssertEqual(texts(.frontMatter, in: "Intro\n---\nkey: value\n---\n"), [])
        XCTAssertEqual(texts(.frontMatter, in: "---\nnever closed"), [], "an unclosed block is a rule")
    }

    func testCRLFLines() {
        let text = "# One\r\n**two**\r\n"
        XCTAssertEqual(texts(.heading(level: 1), in: text), ["# One"])
        XCTAssertEqual(texts(.bold, in: text), ["two"])
    }

    func testGreekOffsetsAreUTF16() {
        let text = "Ασθενής: **βελτίωση** σήμερα 😀 *ήπια*"
        let ns = text as NSString
        let bold = MarkdownStyler.spans(in: text).first { $0.role == .bold }
        XCTAssertEqual(bold.map { ns.substring(with: $0.range) }, "βελτίωση")
        XCTAssertEqual(texts(.italic, in: text), ["ήπια"], "an emoji before must not shift the range")
    }
}
