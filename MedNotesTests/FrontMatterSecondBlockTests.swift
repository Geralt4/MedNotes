import XCTest
@testable import MedNotes

/// "Add property" on a note whose front matter the reader cannot follow.
final class FrontMatterSecondBlockTests: XCTestCase {
    private func addStatus(to text: String) -> String? {
        FrontMatterEditor.edit(.set(key: "status", value: .text("done")), in: text)
            .map { FrontMatterEditor.apply($0, to: text) }
    }

    // MARK: - "Add property" must not write a second block

    /// The reader cannot follow a quoted value that runs over lines from column 0,
    /// so the block looked like prose. Adding a property wrote a new block above
    /// it, and the real one became body text: its properties stopped being
    /// properties in the app and in exported Markdown.
    func testNoSecondBlockIsWrittenOverYAMLTheReaderCannotFollow() {
        let text = "---\ntitle: Visit\nsummary: \"first line\nsecond line\"\n---\nBody"
        XCTAssertNil(FrontMatterYAML.parse(text), "precondition: the reader cannot follow it")
        XCTAssertTrue(FrontMatterEditor.hasUnreadableBlock(in: text))
        XCTAssertNil(addStatus(to: text), "there is no safe place to put a property")
    }

    func testALineSeparatorInsideAValueIsTheSame() {
        let text = "---\ntitle: a\u{2028}b\n---\nBody"
        XCTAssertNil(FrontMatterYAML.parse(text))
        XCTAssertTrue(FrontMatterEditor.hasUnreadableBlock(in: text))
        XCTAssertNil(addStatus(to: text))
    }

    func testProseBetweenTwoRulesIsStillOrdinaryText() {
        let text = "---\nJust some prose here\nand more of it\n---\nBody"
        XCTAssertFalse(FrontMatterEditor.hasUnreadableBlock(in: text))
        let result = addStatus(to: text)
        XCTAssertEqual(result, "---\nstatus: done\n---\n" + text,
                       "a note that merely opens with a rule gets its properties at the top, as before")
    }

    func testANoteWithNoBlockAndOneThatParsesAreUnchanged() {
        XCTAssertEqual(addStatus(to: "Body only"), "---\nstatus: done\n---\nBody only")
        XCTAssertFalse(FrontMatterEditor.hasUnreadableBlock(in: "Body only"))
        let parsed = "---\ntitle: Visit\n---\nBody"
        XCTAssertFalse(FrontMatterEditor.hasUnreadableBlock(in: parsed))
        XCTAssertEqual(addStatus(to: parsed), "---\ntitle: Visit\nstatus: done\n---\nBody")
    }
}
