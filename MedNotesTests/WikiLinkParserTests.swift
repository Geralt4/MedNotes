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

    // MARK: - Hostile input (the security review's M1)

    /// Many unclosed openers used to cost "openers x paragraph x fences": a 54 KB
    /// note took seconds on every save and every open.
    func testManyUnclosedBacktickOpenersAreReadInLinearTime() throws {
        try XCTSkipIf(TestEnvironment.isSanitized, "a wall-clock limit")
        var text = ""
        for length in 1...100 { text += String(repeating: "`", count: length) + "x " }
        text += String(repeating: "word ", count: 5_000)
        text += "\n\n" + String(repeating: "```\n```\n", count: 3_000)
        XCTAssertGreaterThan(text.utf16.count, 40_000)
        let start = Date()
        let scan = WikiLinkParser.scan(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "a hostile 50 KB note took too long")
        XCTAssertFalse(scan.protectedRanges.isEmpty)
    }

    func testManyUnclosedCommentOpenersAreReadInLinearTime() throws {
        try XCTSkipIf(TestEnvironment.isSanitized, "a wall-clock limit")
        for opener in ["<!-- ", "%% x "] {
            // An even count of %% would pair up; the odd one out is the point.
            let text = String(repeating: opener, count: opener == "%% x " ? 20_001 : 12_000)
            let start = Date()
            _ = WikiLinkParser.scan(text)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "\(opener) openers took too long")
        }
    }

    func testAFailedBacktickSearchDoesNotHideACloserInTheNextParagraph() {
        let text = "`unclosed here\n\n`closed`"
        let scan = WikiLinkParser.scan(text)
        let ns = text as NSString
        XCTAssertEqual(scan.protectedRanges.map { ns.substring(with: $0) }, ["`closed`"])
    }

    func testAnUnclosedRunOfOneLengthDoesNotStopACloserOfAnotherLength() {
        let text = "`one ``two`` three"
        let ns = text as NSString
        let scan = WikiLinkParser.scan(text)
        // The lone ` never closes (the run of two is not a run of one); the `` pair does.
        XCTAssertEqual(scan.protectedRanges.map { ns.substring(with: $0) }, ["``two``"])
    }

    func testRandomTextKeepsProtectedRangesSortedAndLinksOutsideThem() {
        var state: UInt64 = 0xBAC7
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let alphabet = Array("`[]%<!->~\n \\ab#")
        for _ in 0..<1_500 {
            let text = String((0..<Int(next() % 60)).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            let scan = WikiLinkParser.scan(text)
            XCTAssertEqual(scan.protectedRanges, scan.protectedRanges.sorted { $0.location < $1.location })
            for link in scan.links {
                XCTAssertFalse(scan.protectedRanges.contains { NSIntersectionRange($0, link.range).length > 0 },
                               "link inside protected text: \(text.debugDescription)")
            }
        }
    }
}
