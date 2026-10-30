import XCTest
@testable import MedNotes

final class FrontMatterTests: XCTestCase {
    private func text(_ ns: NSString, _ range: NSRange) -> String {
        ns.substring(with: range)
    }

    // MARK: - Detection

    func testABlockBetweenTwoFences() throws {
        let source = "---\ntitle: Visit\ntags: [a]\n---\nBody"
        let ns = source as NSString
        let block = try XCTUnwrap(FrontMatter.block(in: source))
        XCTAssertEqual(text(ns, block.range), "---\ntitle: Visit\ntags: [a]\n---\n")
        XCTAssertEqual(text(ns, block.innerRange), "title: Visit\ntags: [a]\n")
        XCTAssertEqual(text(ns, block.openLine), "---\n")
        XCTAssertEqual(text(ns, block.closeLine), "---\n")
        XCTAssertEqual(block.lineEnding, "\n")
        XCTAssertTrue(block.isProperties)
    }

    func testEveryLineBreakStyleIsRead() throws {
        for (name, ending) in [("CRLF", "\r\n"), ("CR", "\r"), ("LS", "\u{2028}")] {
            let source = "---\(ending)k: v\(ending)---\(ending)Body"
            let block = try XCTUnwrap(FrontMatter.properties(in: source), name)
            XCTAssertEqual((source as NSString).substring(with: block.innerRange), "k: v\(ending)", name)
            XCTAssertEqual(block.lineEnding, ending, name)
        }
    }

    func testALeadingByteOrderMarkIsIgnored() throws {
        let source = "\u{FEFF}---\nk: v\n---\nBody"
        let block = try XCTUnwrap(FrontMatter.properties(in: source))
        XCTAssertEqual(block.range.location, 1)
        XCTAssertEqual((source as NSString).substring(from: NSMaxRange(block.range)), "Body")
    }

    func testTrailingSpacesAndTabsOnTheFencesAreAllowed() {
        XCTAssertNotNil(FrontMatter.properties(in: "--- \t\nk: v\n---  \nBody"))
    }

    func testOnlyThreeDashesAloneOnALineAreAFence() {
        XCTAssertNil(FrontMatter.block(in: " ---\nk: v\n---\n"), "an indented opener")
        XCTAssertNil(FrontMatter.block(in: "----\nk: v\n----\n"))
        XCTAssertNil(FrontMatter.block(in: "--- x\nk: v\n---\n"))
        XCTAssertNil(FrontMatter.block(in: "Intro\n---\nk: v\n---\n"), "not at the very start")
    }

    func testThreeDotsDoNotCloseTheBlock() {
        XCTAssertNil(FrontMatter.block(in: "---\nk: v\n...\nprose"))
    }

    func testAnUnclosedOrLoneFenceIsNotFrontMatter() {
        XCTAssertNil(FrontMatter.block(in: "---\nnever closed"))
        XCTAssertNil(FrontMatter.block(in: "---"))
        XCTAssertNil(FrontMatter.block(in: "---\n"))
        XCTAssertNil(FrontMatter.block(in: ""))
        XCTAssertNil(FrontMatter.block(in: "\u{FEFF}"))
    }

    func testAnEmptyPairIsValid() throws {
        let block = try XCTUnwrap(FrontMatter.properties(in: "---\n---\nBody"))
        XCTAssertEqual(block.innerRange.length, 0)
    }

    func testTheClosingFenceMayEndTheText() throws {
        let source = "---\nk: v\n---"
        let block = try XCTUnwrap(FrontMatter.properties(in: source))
        XCTAssertEqual(NSMaxRange(block.range), (source as NSString).length)
    }

    // MARK: - Properties or prose

    func testPropertyLinesComentsListsAndIndentedContinuations() {
        let block = """
        ---
        # a comment
        title: Visit

        tags:
          - cardio
          - ward 3
        aliases: [x, y]
        note: |
          kept as it is
        - bare item
        ---
        """
        XCTAssertNotNil(FrontMatter.properties(in: block))
    }

    func testProseBetweenTwoRulesIsNotFrontMatter() throws {
        let source = "---\nThe patient was seen on the ward and is stable.\n---\nPlan follows."
        let block = try XCTUnwrap(FrontMatter.block(in: source))
        XCTAssertFalse(block.isProperties)
        XCTAssertNil(FrontMatter.properties(in: source))
    }

    func testOneProseLineAmongPropertiesMakesTheWholeBlockText() {
        XCTAssertNil(FrontMatter.properties(in: "---\ntitle: Visit\nseen today\n---\n"))
    }

    func testAnOversizedBlockIsText() throws {
        let filler = (0..<4000).map { "key\($0): \(String(repeating: "x", count: 20))" }.joined(separator: "\n")
        let source = "---\n\(filler)\n---\nBody"
        let block = try XCTUnwrap(FrontMatter.block(in: source))
        XCTAssertGreaterThan(block.innerRange.length, FrontMatter.maxLength)
        XCTAssertFalse(block.isProperties)
    }

    // MARK: - The readers agree

    func testThePreviewHidesPropertiesInAnyLineEnding() {
        for ending in ["\n", "\r\n", "\r"] {
            let blocks = MarkdownPreview.parseBlocks("---\(ending)created: 2026-10-01\(ending)---\(ending)Seen today.")
            guard blocks.count == 2, case let .frontMatter(lines) = blocks[0],
                  case .paragraph("Seen today.") = blocks[1] else {
                XCTFail("got \(blocks) for \(ending.debugDescription)")
                continue
            }
            XCTAssertEqual(lines, ["created: 2026-10-01"])
        }
    }

    func testThePreviewKeepsProseBetweenTwoRules() {
        let blocks = MarkdownPreview.parseBlocks("---\nThe patient is stable.\n---\nPlan follows.")
        let paragraphs: [String] = blocks.compactMap {
            if case let .paragraph(text) = $0 { return text }
            return nil
        }
        XCTAssertEqual(paragraphs, ["The patient is stable.", "Plan follows."])
        XCTAssertFalse(blocks.contains { if case .frontMatter = $0 { return true } else { return false } })
    }

    func testThePreviewDoesNotLeaveCarriageReturnsInParagraphs() {
        let blocks = MarkdownPreview.parseBlocks("First line\r\nsecond line\r\n\r\nNext")
        guard blocks.count == 2, case .paragraph("First line second line") = blocks[0],
              case .paragraph("Next") = blocks[1] else {
            return XCTFail("got \(blocks)")
        }
    }

    func testTheListPreviewSkipsPropertiesButNotProse() {
        XCTAssertEqual(
            DisplayCopy.preview("---\r\ntitle: Visit\r\n---\r\nPatient is stable."), "Patient is stable.")
        XCTAssertEqual(
            DisplayCopy.preview("---\nThe patient is stable.\n---\nPlan follows."),
            "The patient is stable. Plan follows.")
    }

    func testTheStylerMarksPropertiesInAnyLineEnding() {
        for ending in ["\n", "\r\n"] {
            let source = "---\(ending)k: v\(ending)---\(ending)# Head"
            let styled = MarkdownStyler.spans(in: source)
            let front = styled.filter { $0.role == .frontMatter }
            XCTAssertEqual(front.count, 1, ending.debugDescription)
            XCTAssertEqual((source as NSString).substring(with: front[0].range), "---\(ending)k: v\(ending)---\(ending)")
            XCTAssertEqual(styled.filter { $0.role == .heading(level: 1) }.count, 1)
        }
        XCTAssertTrue(MarkdownStyler.spans(in: "---\nThe patient is stable.\n---\n").filter { $0.role == .frontMatter }.isEmpty)
    }
}
