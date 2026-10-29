import XCTest
@testable import MedNotes

/// Text values that another YAML parser would not read as text.
final class FrontMatterQuotingTests: XCTestCase {
    // MARK: - Values another YAML parser would read as numbers

    private func rendered(_ value: String) -> String {
        FrontMatterYAML.scalarText(value)
    }

    /// Notes leave the app as Markdown. An AMKA written as 01018012345 is the
    /// integer 1018012345 to anything else, and its leading zero is gone.
    func testValuesOtherParsersReadAsNonStringsAreQuoted() {
        for value in ["01018012345", "+302101234567", "1.50", "1e5", "1E-3", "0x1F", "0o17", "0b101",
                      ".inf", "-.inf", ".nan", "12:30", "1:02:03", "1_000", ".5", "~", "null", "True", "FALSE"] {
            XCTAssertTrue(rendered(value).hasPrefix("\""), "\(value) was written unquoted: \(rendered(value))")
        }
    }

    func testOrdinaryTextIsNotQuoted() {
        for value in ["5 mg", "twice daily", "Penicillin", "1.5.3", "2026 plan", "Ward 4B", "10 mg twice daily"] {
            XCTAssertEqual(rendered(value), value, "\(value) did not need quotes")
        }
    }

    func testAQuotedValueReadsBackAsTheSameText() throws {
        for value in ["01018012345", "+302101234567", "1.50", "12:30", "0x1F", ".inf", "null"] {
            let note = "---\nid: \(rendered(value))\n---\n"
            let set = try XCTUnwrap(FrontMatterYAML.parse(note), value)
            XCTAssertEqual(set.properties.first?.value, .text(value))
        }
    }
}
