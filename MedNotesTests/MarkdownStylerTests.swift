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
        XCTAssertTrue(MarkdownStyler.spans(in: "#hashtag").isEmpty, "a heading needs the space")
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
