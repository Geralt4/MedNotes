import XCTest
@testable import MedNotes

final class WikiLinkParserTests: XCTestCase {
    private func links(_ text: String) -> [ParsedLink] {
        WikiLinkParser.scan(text).links
    }

    private func targets(_ text: String) -> [String] {
        links(text).map(\.target)
    }

    /// The token a link's range covers, read from the source text.
    private func token(_ link: ParsedLink, in text: String) -> String {
        (text as NSString).substring(with: link.range)
    }

    // MARK: - Grammar

    func testPlainLinkAndItsRange() {
        let text = "See [[Ward Rounds]] now"
        let found = links(text)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].target, "Ward Rounds")
        XCTAssertEqual(token(found[0], in: text), "[[Ward Rounds]]")
        XCTAssertNil(found[0].heading)
        XCTAssertNil(found[0].blockID)
        XCTAssertNil(found[0].alias)
        XCTAssertFalse(found[0].isEmbed)
    }

    func testAliasHeadingAndBlock() {
        let a = links("[[Note#Heading|shown]]")[0]
        XCTAssertEqual(a.target, "Note")
        XCTAssertEqual(a.heading, "Heading")
        XCTAssertEqual(a.alias, "shown")

        let b = links("[[Note#^abc123]]")[0]
        XCTAssertEqual(b.target, "Note")
        XCTAssertEqual(b.blockID, "abc123")
        XCTAssertNil(b.heading)

        let c = links("[[Note#A#B]]")[0]
        XCTAssertEqual(c.heading, "A#B", "further # stay in the heading")
    }

    func testAliasIsSplitBeforeTheHeading() {
        let link = links("[[A|see #2]]")[0]
        XCTAssertEqual(link.target, "A")
        XCTAssertEqual(link.alias, "see #2")
        XCTAssertNil(link.heading)
    }

    func testEscapedPipeIsTheAliasSeparator() {
        let link = links("| [[Note\\|shown]] |")[0]
        XCTAssertEqual(link.target, "Note")
        XCTAssertEqual(link.alias, "shown")
        XCTAssertEqual(link.inner, "Note|shown")
    }

    func testInnerKeepsTheWholeTextForTitlesWithHashesAndPipes() {
        XCTAssertEqual(links("[[Plan #2]]")[0].inner, "Plan #2")
        XCTAssertEqual(links("[[Plan #2]]")[0].target, "Plan")
        XCTAssertEqual(links("[[A | B]]")[0].inner, "A | B")
    }

    func testEmbed() {
        let text = "![[Scan note]] and ![[img.png]]"
        let found = links(text)
        XCTAssertEqual(found.map(\.isEmbed), [true, true])
        XCTAssertEqual(token(found[0], in: text), "![[Scan note]]")
        XCTAssertEqual(found[1].target, "img.png")
    }

    func testEscapedBangIsNotAnEmbed() {
        let text = "\\![[x]]"
        let found = links(text)
        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].isEmbed)
        XCTAssertEqual(token(found[0], in: text), "[[x]]")
    }

    func testLinkToAHeadingOfTheSameNote() {
        let link = links("see [[#Plan]]")[0]
        XCTAssertTrue(link.isSameNote)
        XCTAssertEqual(link.heading, "Plan")
    }

    func testShapesThatAreNotLinks() {
        XCTAssertEqual(links("[[]] [[ ]] [[|x]] [[#]] [[#^]] [[ | ]]"), [])
    }

    func testThreeBracketsGiveTheInnerLink() {
        let text = "[[[x]]]"
        let found = links(text)
        XCTAssertEqual(found.map(\.target), ["x"])
        XCTAssertEqual(token(found[0], in: text), "[[x]]")
    }

    func testNestedOpenersRestartAtTheInnerOne() {
        XCTAssertEqual(targets("[[a[[b]]c]]"), ["b"])
    }

    func testLinksDoNotSpanLines() {
        XCTAssertEqual(links("[[a\nb]]"), [])
        XCTAssertEqual(links("[[a\r\nb]]"), [])
        XCTAssertEqual(links("[[a\rb]]"), [])
    }

    func testUnterminatedAndOversizedAreNotLinks() {
        XCTAssertEqual(links("tail [[Unclosed"), [])
        XCTAssertEqual(links("[[a]b]]"), [])
        XCTAssertEqual(links("[[" + String(repeating: "x", count: 600) + "]]"), [])
        XCTAssertEqual(links("[[" + String(repeating: "x", count: 400) + "]]").count, 1)
    }

    func testOccurrencesAreKeptInOrderWithoutDeduplication() {
        XCTAssertEqual(targets("[[A]] then [[B]] then [[A]]"), ["A", "B", "A"])
    }

    func testBackslashEscapedOpenerIsNotALink() {
        XCTAssertEqual(links("\\[[x]]"), [])
    }

    // MARK: - Code and comments

    func testFencedCodeIsSkipped() {
        let text = "```\n[[x]]\n```\n[[y]]"
        XCTAssertEqual(targets(text), ["y"])
        XCTAssertEqual(targets("~~~\n[[x]]\n~~~\n[[y]]"), ["y"])
        XCTAssertEqual(targets("```swift\n[[x]]\n```"), [])
    }

    func testUnterminatedFenceRunsToTheEnd() {
        let scan = WikiLinkParser.scan("[[a]]\n```\n[[x]]\nmore")
        XCTAssertEqual(scan.links.map(\.target), ["a"])
        XCTAssertEqual(scan.protectedRanges.count, 1)
    }

    func testFenceClosesOnlyWithAtLeastAsManyOfTheSameCharacter() {
        let text = "~~~~\n[[x]]\n~~~\n[[y]]\n~~~~\n[[z]]"
        XCTAssertEqual(targets(text), ["z"])
        XCTAssertEqual(targets("```\n[[x]]\n~~~\n[[y]]\n```\n[[z]]"), ["z"])
    }

    func testCRLFFencesClose() {
        XCTAssertEqual(targets("```\r\n[[x]]\r\n```\r\n[[y]]"), ["y"])
        XCTAssertEqual(targets("```\r[[x]]\r```\r[[y]]"), ["y"])
    }

    func testBacktickFenceWithABacktickInItsInfoStringIsNotAFence() {
        XCTAssertEqual(targets("```a`b\n[[x]]"), ["x"])
    }

    func testFourSpaceIndentIsNotCode() {
        XCTAssertEqual(targets("- item\n    - nested [[x]]\n    [[y]]"), ["x", "y"])
    }

    func testIndentedFenceUpToThreeSpaces() {
        XCTAssertEqual(targets("   ```\n[[x]]\n   ```\n[[y]]"), ["y"])
        XCTAssertEqual(targets("    ```\n[[x]]"), ["x"])
    }

    func testInlineCodeIsSkipped() {
        XCTAssertEqual(targets("`[[x]]` and [[y]]"), ["y"])
        XCTAssertEqual(targets("``a ` [[x]]`` [[y]]"), ["y"])
        XCTAssertEqual(targets("`[[x]]"), ["x"], "an unmatched backtick is just a character")
        XCTAssertEqual(targets("`a`` [[x]]"), ["x"], "the closing run must be the same length")
        XCTAssertEqual(targets("`a`` [[x]] ``b`"), [], "a single-backtick span can contain longer runs")
    }

    func testCodeSpanDoesNotCrossABlankLine() {
        XCTAssertEqual(targets("`a\n\n[[x]]`"), ["x"])
        XCTAssertEqual(targets("`a\n[[x]]`"), [], "a soft break does not end a span")
    }

    func testABacktickInsideTheBracketsIsNotALink() {
        XCTAssertEqual(links("[[a `]]` b"), [])
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(targets("%% [[x]] %% [[y]]"), ["y"])
        XCTAssertEqual(targets("<!-- [[x]] --> [[y]]"), ["y"])
        XCTAssertEqual(targets("%% line\n[[x]]\nmore %% [[y]]"), ["y"])
    }

    func testUnterminatedCommentIsNotAComment() {
        XCTAssertEqual(targets("%% [[x]]"), ["x"])
        XCTAssertEqual(targets("<!-- [[x]]"), ["x"])
    }

    func testLinksInFrontMatterAreRead() {
        XCTAssertEqual(targets("---\nrelated: \"[[x]]\"\n---\nbody [[y]]"), ["x", "y"])
    }

    // MARK: - Positions

    func testRangesAreUTF16AndRoundTripThroughEmojiAndAccents() {
        let samples = [
            "😀 [[Ωμέγα]] tail",
            "👨‍⚕️ ward [[x]] 👩🏽‍🔬 [[y z]]",
            "e\u{301} [[café]] a\u{301}",
            "🇬🇷🇬🇷[[flag]]",
        ]
        for text in samples {
            for link in links(text) {
                let read = token(link, in: text)
                XCTAssertTrue(read.hasPrefix("[[") && read.hasSuffix("]]"), "\(read) in \(text)")
                XCTAssertTrue(read.contains(link.target), "\(read) in \(text)")
            }
        }
        XCTAssertEqual(links("😀 [[Ωμέγα]]")[0].range, NSRange(location: 3, length: 9))
    }

    func testACombiningMarkAfterTheBracketsStillClosesTheLink() {
        XCTAssertEqual(targets("[[x]]\u{301} tail"), ["x"])
        XCTAssertEqual(targets("[[x]\u{301}]"), [], "a mark between the brackets is text, not a closer")
    }

    // MARK: - Keys

    func testNormalizedKeyFoldsCaseAccentsFinalSigmaWidthAndSpace() {
        let key = WikiLinkParser.normalizedKey
        XCTAssertEqual(key("Καλός Γιατρός"), key("ΚΑΛΟΣ ΓΙΑΤΡΟΣ"))
        XCTAssertEqual(key("ΚΑΛΟΣ"), key("καλοσ"), "final sigma and sigma are one letter")
        XCTAssertEqual(key("ϊ"), key("ι"))
        XCTAssertEqual(key("ΐ"), key("ι"))
        XCTAssertEqual(key("e\u{301}"), key("é"), "NFD against NFC")
        XCTAssertEqual(key("ＡＢ"), key("ab"))
        XCTAssertEqual(key("  Ward   Rounds \n"), key("ward rounds"))
        XCTAssertNotEqual(key("Ward"), key("Wound"))
        XCTAssertEqual(key("   "), "")
    }
}
