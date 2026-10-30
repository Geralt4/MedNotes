import XCTest
@testable import MedNotes

final class SearchSnippetTests: XCTestCase {
    private func marked(_ snippet: SearchSnippet) -> [String] {
        let ns = snippet.text as NSString
        return snippet.highlights.map { ns.substring(with: $0) }
    }

    func testTheMatchedLineWithItsWordMarked() throws {
        let snippet = try XCTUnwrap(SearchSnippet.make(
            content: "Intro line\nPatient reports chest pain on exertion\nLast line", terms: ["pain"]))
        XCTAssertEqual(snippet.text, "Patient reports chest pain on exertion")
        XCTAssertEqual(marked(snippet), ["pain"])
    }

    func testAMatchIsTheStartOfAWordNotTheMiddle() throws {
        XCTAssertNil(SearchSnippet.make(content: "Holiday in Spain", terms: ["pain"]))
        let snippet = try XCTUnwrap(SearchSnippet.make(content: "painful swallowing", terms: ["pain"]))
        XCTAssertEqual(marked(snippet), ["pain"], "a prefix, as the full-text search reads it")
    }

    func testCaseAccentsAndTheGreekTonosAreFolded() throws {
        let snippet = try XCTUnwrap(SearchSnippet.make(content: "Ο ασθενής ήρθε σήμερα", terms: ["ΑΣΘΕΝΗΣ"]))
        XCTAssertEqual(marked(snippet), ["ασθενής"])
        let other = try XCTUnwrap(SearchSnippet.make(content: "CARDIO review", terms: ["cardio"]))
        XCTAssertEqual(marked(other), ["CARDIO"])
    }

    func testMarkdownSyntaxIsStripped() throws {
        let snippet = try XCTUnwrap(SearchSnippet.make(
            content: "## **Plan**: see [[Cardiology plan|the plan]] and `digoxin`", terms: ["digoxin", "plan"]))
        XCTAssertEqual(snippet.text, "Plan: see Cardiology plan|the plan and digoxin")
        XCTAssertTrue(marked(snippet).contains("digoxin"))
        XCTAssertFalse(snippet.text.contains("**"))
        XCTAssertFalse(snippet.text.contains("[["))
    }

    func testFrontMatterIsSkippedUnlessItIsTheOnlyMatch() throws {
        let note = "---\nstatus: urgent\n---\nUrgent review needed"
        let body = try XCTUnwrap(SearchSnippet.make(content: note, terms: ["urgent"]))
        XCTAssertEqual(body.text, "Urgent review needed")

        let only = try XCTUnwrap(SearchSnippet.make(content: "---\nstatus: urgent\n---\nnothing here", terms: ["urgent"]))
        XCTAssertEqual(only.text, "status: urgent")
    }

    func testNoMatchInTheTextGivesNoSnippet() {
        XCTAssertNil(SearchSnippet.make(content: "nothing relevant", terms: ["digoxin"]))
        XCTAssertNil(SearchSnippet.make(content: "text", terms: []))
        XCTAssertNil(SearchSnippet.make(content: "", terms: ["a"]))
        // The match is in a link address, which the plain line drops.
        XCTAssertNil(SearchSnippet.make(content: "see [docs](https://example.com/digoxin)", terms: ["digoxin"]))
    }

    func testALongLineIsCutAroundTheMatchOnWordBoundaries() throws {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 12)
        let content = filler + "digoxin level raised " + filler
        let snippet = try XCTUnwrap(SearchSnippet.make(content: content, terms: ["digoxin"]))
        XCTAssertTrue(snippet.text.hasPrefix("… "))
        XCTAssertTrue(snippet.text.hasSuffix(" …"))
        XCTAssertLessThanOrEqual(snippet.text.count, SearchSnippet.window + 6)
        XCTAssertEqual(marked(snippet), ["digoxin"])
        XCTAssertFalse(snippet.text.contains("  "))
    }

    func testEveryOccurrenceOnTheLineIsMarkedAndOverlapsMerge() throws {
        let snippet = try XCTUnwrap(SearchSnippet.make(content: "pain, more pain and painful", terms: ["pain", "pai"]))
        XCTAssertEqual(marked(snippet), ["pain", "pain", "pain"])
    }

    func testHighlightRangesAreUTF16AndSurviveEmoji() throws {
        let snippet = try XCTUnwrap(SearchSnippet.make(content: "😀 fever 😀 high", terms: ["high"]))
        XCTAssertEqual(marked(snippet), ["high"])
        let long = String(repeating: "😀 ", count: 80) + "fever" + String(repeating: " 😀", count: 80)
        let cut = try XCTUnwrap(SearchSnippet.make(content: long, terms: ["fever"]))
        XCTAssertEqual(marked(cut), ["fever"])
    }

    func testAHugeNoteWithoutAMatchStaysQuick() throws {
        // `measure` without a stored baseline never fails; this does.
        try XCTSkipIf(TestEnvironment.isSanitized, "a wall-clock limit")
        let content = String(repeating: "word ", count: 40_000)
        let started = Date()
        _ = SearchSnippet.make(content: content, terms: ["zzz"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testTheRowHighlightMarksTheSameWords() throws {
        let snippet = try XCTUnwrap(SearchSnippet.make(content: "chest pain today", terms: ["pain"]))
        let text = NoteRowView.highlighted(snippet)
        XCTAssertEqual(String(text.characters), "chest pain today")
        let marked = text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
        XCTAssertEqual(marked, ["pain"])
    }

    /// The per-word colour must survive the row's own secondary style: count
    /// the pixels that are tinted rather than grey (anti-aliased text rarely
    /// reaches the full accent colour, so the threshold is low).
    @MainActor
    func testTheMatchedWordIsDrawnInTheAccentColour() throws {
        // Graphite or another near-grey accent cannot be told from the text.
        let accent = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        let spread = max(accent.redComponent, accent.greenComponent, accent.blueComponent)
            - min(accent.redComponent, accent.greenComponent, accent.blueComponent)
        try XCTSkipIf(spread < 0.3, "the system accent colour is grey")
        func colouredPixels(snippet: SearchSnippet?) throws -> Int {
            let host = OffscreenHost()
            defer { host.tearDown() }
            let view = host.host(
                NoteRowView(note: Note(title: "T", content: "chest pain today"), snippet: snippet)
                    .padding(8), width: 320, height: 90)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let spread = max(c.redComponent, c.greenComponent, c.blueComponent)
                        - min(c.redComponent, c.greenComponent, c.blueComponent)
                    if spread > 0.12 { count += 1 }
                }
            }
            return count
        }
        let plain = try colouredPixels(snippet: nil)
        let marked = try colouredPixels(snippet: SearchSnippet.make(content: "chest pain today", terms: ["pain"]))
        XCTAssertGreaterThan(marked, plain + 20, "plain \(plain), marked \(marked)")
    }
}
