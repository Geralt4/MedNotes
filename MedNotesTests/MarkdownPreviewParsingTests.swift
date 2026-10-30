import XCTest
@testable import MedNotes

/// The preview is what a clinician reads a note in, so a line that disappears or
/// a list that runs together is a clinical risk, not a cosmetic one.
final class MarkdownPreviewParsingTests: XCTestCase {
    private func describe(_ source: String) -> [String] {
        MarkdownPreview.parseBlocks(source).map { block in
            switch block {
            case let .heading(level, text): return "h\(level):\(text)"
            case let .paragraph(text): return "p:\(text)"
            case let .bullet(text): return "b:\(text)"
            case let .numbered(number, text): return "n:\(number)|\(text)"
            case let .checklist(text, checked): return "c\(checked ? "x" : "_"):\(text)"
            case let .codeLine(text): return "code:\(text)"
            case .divider: return "rule"
            case let .frontMatter(lines): return "fm:\(lines.joined(separator: ";"))"
            }
        }
    }

    func testAllSixHeadingLevelsAreHeadings() {
        XCTAssertEqual(describe("##### Plan\n###### Detail\n####### seven"),
                       ["h5:Plan", "h6:Detail", "p:####### seven"],
                       "the editor and the outline treat five and six hashes as headings too")
    }

    // MARK: - Numbered lists

    /// A medication list used to read "1. Metformin 500mg 2. Ramipril 5mg" on one
    /// line, which makes the doses run into the next drug's name.
    func testNumberedLinesAreOneItemEach() {
        XCTAssertEqual(
            describe("1. Metformin 500mg\n2. Ramipril 5mg\n3) Aspirin 75mg"),
            ["n:1.|Metformin 500mg", "n:2.|Ramipril 5mg", "n:3)|Aspirin 75mg"])
    }

    func testNumbersThatAreNotListMarkersStayText() {
        XCTAssertEqual(describe("1.5 mg twice daily"), ["p:1.5 mg twice daily"])
        XCTAssertEqual(describe("12:30 appointment"), ["p:12:30 appointment"])
        XCTAssertEqual(describe("1."), ["p:1."], "a marker with no text is not an item")
        XCTAssertEqual(describe("1234567890. too many digits"), ["p:1234567890. too many digits"])
    }

    func testAListInterruptsAParagraph() {
        XCTAssertEqual(
            describe("Plan:\n1. Bloods\n2. ECG"),
            ["p:Plan:", "n:1.|Bloods", "n:2.|ECG"])
    }

    func testAPlusIsABulletToo() {
        XCTAssertEqual(describe("+ Rest\n- Fluids"), ["b:Rest", "b:Fluids"])
    }

    // MARK: - Fences

    /// "```ls``` output was normal" used to open a fence: the line vanished and
    /// everything after it showed as code until the next such line.
    func testALineWithBackticksInItIsTextNotAFence() {
        XCTAssertEqual(
            describe("```ls``` output was normal\nNext line is still text"),
            ["p:```ls``` output was normal Next line is still text"])
    }

    func testAFenceHoldsItsLinesAsCodeAndEndsAtItsCloser() {
        XCTAssertEqual(
            describe("Before\n```swift\nlet a = 1\n- not a bullet\n```\nAfter"),
            ["p:Before", "code:let a = 1", "code:- not a bullet", "p:After"])
    }

    func testTildeFencesWork() {
        XCTAssertEqual(
            describe("~~~\n1. not a list\n~~~\nAfter"),
            ["code:1. not a list", "p:After"])
    }

    func testAnInfoStringLineInsideAFenceDoesNotCloseIt() {
        XCTAssertEqual(
            describe("```\n```js\nstill code\n```\nout"),
            ["code:```js", "code:still code", "p:out"])
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(describe("```\nline one\nline two"), ["code:line one", "code:line two"])
    }

    func testALongerFenceNeedsAtLeastAsLongACloser() {
        XCTAssertEqual(
            describe("````\n```\n````\nout"),
            ["code:```", "p:out"])
    }
}
