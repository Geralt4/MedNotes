import XCTest
@testable import MedNotes

/// Code spans and comments are read in the body of a note, not in its front matter.
final class LinkScannerFrontMatterTests: XCTestCase {
    // MARK: - Links and code spans start after the front matter

    private func targets(_ text: String) -> [String] {
        WikiLinkParser.scan(text).links.map(\.target)
    }

    /// A lone backtick in the front matter paired with one in the body, and the
    /// link between them was read as code.
    func testALoneBacktickInTheFrontMatterHidesNothingInTheBody() {
        let text = "---\nnote: run `ls\n---\nSee [[Patient A]] and `y`"
        XCTAssertEqual(targets(text), ["Patient A"])
        let protected = WikiLinkParser.scan(text).protectedRanges
        let bodyStart = (text as NSString).range(of: "See").location
        XCTAssertTrue(protected.allSatisfy { $0.location >= bodyStart },
                      "only the body's own code span is protected: \(protected)")
    }

    func testAPercentPairOpenedInTheFrontMatterHidesNothing() {
        let text = "---\nscore: 50%%\n---\nSee [[A]]\n\n%%a real comment%%\nthen [[B]]"
        XCTAssertEqual(targets(text), ["A", "B"])
    }

    func testALinkInsideAFrontMatterValueIsStillRead() {
        XCTAssertEqual(targets("---\nrelated: \"[[Patient A]]\"\n---\nBody"), ["Patient A"])
    }

    func testTheBodyStillHonoursItsOwnCodeAndComments() {
        let text = "---\nk: v\n---\n`[[not a link]]` and %%[[hidden]]%% and [[real]]"
        XCTAssertEqual(targets(text), ["real"])
    }

    func testTheRulesChangedSoStoredLinksAreDerivedAgain() {
        XCTAssertGreaterThanOrEqual(WikiLinkParser.version, 3)
    }
}
