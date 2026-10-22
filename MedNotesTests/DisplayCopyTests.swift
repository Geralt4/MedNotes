import XCTest
@testable import MedNotes

/// The row-rendering helpers behind the note list. `preview` is pure string
/// work and is the half of the UI polish that needs no eyes at all.
final class DisplayCopyTests: XCTestCase {

    func testPreviewStripsMarkdownStructure() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("front-matter",
             "---\ntitle: Visit\ntags: [cardio]\n---\n\n# Follow-up\n\nPatient reports **improved** dyspnea.",
             "Follow-up Patient reports improved dyspnea."),
            ("wiki-links",
             "Discussed [[Hypertension protocol]] with [[Jane Doe]] today.",
             "Discussed Hypertension protocol with Jane Doe today."),
            ("code fence",
             "Plan:\n\n```sql\nSELECT * FROM labs;\n```\n\nRepeat panel in 6 weeks.",
             "Plan: Repeat panel in 6 weeks."),
            ("task list and ordered items",
             "- [ ] Order CBC\n- [x] Renew lisinopril\n1. Schedule echo",
             "Order CBC Renew lisinopril Schedule echo"),
            ("markdown link and inline code",
             "See [the guideline](https://example.invalid/x) and set `dose = 5mg` daily.",
             "See the guideline and set dose = 5mg daily."),
            ("rules and quotes",
             "---\n> Prior note said stable.\n\n***\n## Assessment\nStable.",
             "Prior note said stable. Assessment Stable."),
            ("image dropped",
             "![chart](chart.png)\n\nDe-escalate within 48h.",
             "De-escalate within 48h."),
            ("strikethrough",
             "~~Ceftriaxone by default~~ is no longer policy.",
             "Ceftriaxone by default is no longer policy."),
            ("empty", "", ""),
            ("whitespace only", "\n\n   \n", "")
        ]

        for testCase in cases {
            XCTAssertEqual(
                DisplayCopy.preview(testCase.input), testCase.expected,
                "preview mismatch for \(testCase.name)")
        }
    }

    /// `#tag` is content; only `# ` opens a heading. Losing this would quietly
    /// eat the first word of every note that opens on a tag.
    func testPreviewKeepsHashTagsButDropsHeadings() {
        XCTAssertEqual(
            DisplayCopy.preview("#cardiology follow-up needed"),
            "#cardiology follow-up needed")
        XCTAssertEqual(DisplayCopy.preview("### Deep heading\nBody"), "Deep heading Body")
    }

    func testPreviewNeverLeaksSyntaxIntoARow() {
        let messy = """
        ---
        id: 1
        ---
        # Heading with **bold**
        > quoted [[link]] and [label](url)
        - [ ] task with `code`
        ```
        fenced
        ```
        """
        let preview = DisplayCopy.preview(messy)
        for marker in ["[[", "](", "**", "```", "# ", "> "] {
            XCTAssertFalse(preview.contains(marker), "preview leaked \(marker): \(preview)")
        }
        XCTAssertFalse(preview.contains("fenced"), "fenced code leaked into the preview")
    }

    /// Locale is injected rather than pinned on the shared formatter, which
    /// would otherwise ship English stamps to this app's Greek users.
    func testRelativeUsesInjectedReferenceAndLocale() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let enUS = Locale(identifier: "en_US")

        // `.abbreviated` is the whole point of the stamp: "2h ago", not the
        // "2 hours ago" of `.full` or the "2 hr. ago" of `.short`.
        XCTAssertEqual(
            DisplayCopy.relative(reference.addingTimeInterval(-10 * 60),
                                 to: reference, locale: enUS),
            "10m ago")
        XCTAssertEqual(
            DisplayCopy.relative(reference.addingTimeInterval(-2 * 3600),
                                 to: reference, locale: enUS),
            "2h ago")
        XCTAssertEqual(
            DisplayCopy.relative(reference.addingTimeInterval(-3 * 86_400),
                                 to: reference, locale: enUS),
            "3d ago")
    }

    func testRelativeIsPastFacingForBackdatedRows() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let enUS = Locale(identifier: "en_US")
        let stamp = DisplayCopy.relative(reference.addingTimeInterval(-600),
                                         to: reference, locale: enUS)
        XCTAssertTrue(stamp.hasSuffix("ago"), "expected a past-facing stamp, got \(stamp)")
    }

    func testTitleAndPatientFallbacks() {
        XCTAssertEqual(DisplayCopy.title("   "), "Untitled")
        XCTAssertEqual(DisplayCopy.title("  Real title "), "Real title")
        XCTAssertEqual(DisplayCopy.patient(""), "Unnamed Patient")
        XCTAssertEqual(DisplayCopy.initials(first: "Γεώργιος", last: "Παπαδόπουλος"), "ΓΠ")
        XCTAssertEqual(DisplayCopy.initials(first: "", last: ""), "?")
    }
}
