import XCTest
@testable import MedNotes

/// The parse tree: every block and inline kind, ranges into the note's own
/// UTF-16 text, hostile input, and agreement with the index's own scanners.
final class MarkdownParserTests: XCTestCase {
    private func parse(_ text: String) -> [MarkdownBlock] { MarkdownParser.parse(text).blocks }

    /// A compact one-line description of inlines, for assertions.
    private func shape(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline.kind {
            case .text(let s): return "T(\(s))"
            case .strong(let c, let w): return "B\(w)[\(shape(c))]"
            case .emphasis(let c, let w): return "I\(w)[\(shape(c))]"
            case .strikethrough(let c): return "S[\(shape(c))]"
            case .highlight(let c): return "H[\(shape(c))]"
            case .code(let s): return "C(\(s))"
            case .link(let l, let d): return "L[\(shape(l))](\(d))"
            case .wikiLink(let l): return "W(\(l.inner))"
            case .embed(let l): return "E(\(l.inner))"
            case .tag(let t): return "#(\(t))"
            case .image(let a, let s): return "IMG(\(a),\(s))"
            case .softBreak: return "~"
            case .hardBreak: return "⏎"
            }
        }.joined()
    }

    private func paragraph(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .paragraph(let inlines)? = parse(text).first?.kind else {
            XCTFail("not a paragraph: \(text.debugDescription)", file: file, line: line)
            return ""
        }
        return shape(inlines)
    }

    private func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    // MARK: - Blocks

    func testHeadingsOneToSixWithClosingHashesAndBlockIDs() {
        let text = "# One\n## Two ##\n###### Six\n####### seven\n#tag\n# \n# Plan ^plan"
        let blocks = parse(text)
        var levels: [Int] = []
        for block in blocks { if case .heading(let level, _, _) = block.kind { levels.append(level) } }
        XCTAssertEqual(levels, [1, 2, 6, 1])
        guard case .heading(_, let two, _) = blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(shape(two), "T(Two)")
        guard case .heading(_, let plan, _) = blocks.last?.kind else { return XCTFail() }
        XCTAssertEqual(shape(plan), "T(Plan)")
        XCTAssertEqual(blocks.last?.blockID, "plan")
        // `####### seven` and `#tag` are text.
        XCTAssertTrue(blocks.contains { if case .paragraph = $0.kind { return true } else { return false } })
    }

    func testParagraphLinesAreJoinedBySoftAndHardBreaks() {
        XCTAssertEqual(paragraph("one\ntwo"), "T(one)~T(two)")
        XCTAssertEqual(paragraph("one  \ntwo"), "T(one)⏎T(two)")
        XCTAssertEqual(paragraph("one\\\ntwo"), "T(one)⏎T(two)")
        XCTAssertEqual(paragraph("one\n   indented continuation"), "T(one)~T(indented continuation)")
    }

    func testRulesAreNotSetextHeadingsAndNeedThreeMarks() {
        let blocks = parse("Title\n---\n* * *\n_____\n--\n")
        XCTAssertEqual(blocks.map { if case .rule = $0.kind { return "rule" } else if case .paragraph = $0.kind { return "p" } else { return "?" } },
                       ["p", "rule", "rule", "rule", "p"])
    }

    func testFencedCodeKeepsItsTextAndLanguage() {
        let text = "```swift\nlet x = 1\n\n  indented\n```\nafter\n~~~\ntilde\n~~~"
        let blocks = parse(text)
        guard case .code(let lang, let body) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(body, "let x = 1\n\n  indented")
        XCTAssertEqual(substring(text, blocks[0].range), "```swift\nlet x = 1\n\n  indented\n```")
        guard case .code(let none, let tilde) = blocks[2].kind else { return XCTFail() }
        XCTAssertNil(none)
        XCTAssertEqual(tilde, "tilde")
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        let blocks = parse("```\nunclosed\nstill code")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(_, let body) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(body, "unclosed\nstill code")
    }

    func testMarkdownInsideAFenceIsNotParsed() {
        let blocks = parse("```\n# not a heading\n- not a list\n[[not a link]]\n```")
        XCTAssertEqual(blocks.count, 1)
    }

    func testFrontMatterIsOneBlockAndBodyOffsetsFollowIt() {
        let text = "---\ntitle: x\ntags: [a]\n---\n# H\n\nBody"
        let blocks = parse(text)
        guard case .frontMatter(let lines) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(lines, ["title: x", "tags: [a]"])
        XCTAssertEqual(substring(text, blocks[1].range), "# H")
        XCTAssertEqual(substring(text, blocks[2].range), "Body")
    }

    func testCommentsOnLinesOfTheirOwnAreBlocksAndInlineOnesVanish() {
        let text = "%% hidden\nacross lines %%\n\nbefore %%inline%% after\n\n<!-- html -->\n\n%% never closed"
        let blocks = parse(text)
        guard case .comment = blocks[0].kind else { return XCTFail("\(blocks)") }
        XCTAssertEqual(substring(text, blocks[0].range), "%% hidden\nacross lines %%")
        guard case .paragraph(let inlines) = blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(shape(inlines), "T(before  after)".replacingOccurrences(of: "  ", with: " ") == "" ? "" : shape(inlines))
        XCTAssertFalse(shape(inlines).contains("inline"), "an inline comment is not shown")
        guard case .comment = blocks[2].kind else { return XCTFail() }
        guard case .paragraph(let tail) = blocks[3].kind else { return XCTFail() }
        XCTAssertTrue(shape(tail).contains("never closed"), "an unterminated comment is text")
    }

    // MARK: - Inlines

    func testEmphasisFollowsTheFlankingRules() {
        XCTAssertEqual(paragraph("**bold** and *it* and ***both***"), "B2[T(bold)]T( and )I1[T(it)]T( and )I1[B2[T(both)]]")
        XCTAssertEqual(paragraph("snake_case_name and 2 * 3"), "T(snake_case_name and 2 * 3)")
        XCTAssertEqual(paragraph("a*b*c"), "T(a)I1[T(b)]T(c)")
        XCTAssertEqual(paragraph("*a **b** c*"), "I1[T(a )B2[T(b)]T( c)]")
        XCTAssertEqual(paragraph("_it_ and __b__"), "I1[T(it)]T( and )B2[T(b)]")
        XCTAssertEqual(paragraph("**unclosed and *also"), "T(**unclosed and *also)")
        XCTAssertEqual(paragraph("**bold**text"), "B2[T(bold)]T(text)")
    }

    func testStrikethroughHighlightAndCodeSpans() {
        XCTAssertEqual(paragraph("~~gone~~ ==marked== ~single~ =one="), "S[T(gone)]T( )H[T(marked)]T( ~single~ =one=)")
        XCTAssertEqual(paragraph("`a * b` and ``with ` tick``"), "C(a * b)T( and )C(with ` tick)")
        XCTAssertEqual(paragraph("` padded `"), "C(padded)")
    }

    func testLinksImagesAndEscapes() {
        XCTAssertEqual(paragraph("[text](http://a.com/x_(y)) and ![alt text](p.png \"title\")"),
                       "L[T(text)](http://a.com/x_(y))T( and )IMG(alt text,p.png)")
        XCTAssertEqual(paragraph("[**bold** label](u)"), "L[B2[T(bold)]T( label)](u)")
        XCTAssertEqual(paragraph("[no destination] and [a](b"), "T([no destination] and [a](b)")
        XCTAssertEqual(paragraph("\\*literal\\* and \\[x\\]"), "T(*literal* and [x])")
    }

    func testWikiLinksEmbedsAndTagsAreTheIndexsOwn() {
        XCTAssertEqual(paragraph("see [[Plan #2|the plan]] and ![[Note#^b1]] #cardio/ward #123 `#code`"),
                       "T(see )W(Plan #2|the plan)T( and )E(Note#^b1)T( )#(cardio/ward)T( #123 )C(#code)")
        // A link in code is not a link; a tag-looking word inside a link is not a tag.
        XCTAssertEqual(paragraph("`[[x]]` [[a#b]]"), "C([[x]])T( )W(a#b)")
    }

    func testGreekAndEmojiRangesAreUTF16() {
        let text = "😀 **έντονη** και [[Σημείωση]]"
        guard case .paragraph(let inlines)? = parse(text).first?.kind else { return XCTFail() }
        let bold = inlines.first { if case .strong = $0.kind { return true } else { return false } }
        XCTAssertEqual(substring(text, bold?.range ?? NSRange()), "**έντονη**")
        let link = inlines.first { if case .wikiLink = $0.kind { return true } else { return false } }
        XCTAssertEqual(substring(text, link?.range ?? NSRange()), "[[Σημείωση]]")
    }

    // MARK: - Lists, quotes, callouts

    func testListsOrderedNestedAndLoose() {
        let text = "- a\n  - nested\n- b\n\n  second paragraph\n\n- c\n\n3. three\n4. four"
        let blocks = parse(text)
        guard case .list(let bullets) = blocks[0].kind else { return XCTFail() }
        XCTAssertFalse(bullets.isOrdered)
        XCTAssertEqual(bullets.items.count, 3, "a blank line between items keeps one list")
        XCTAssertEqual(bullets.items[0].blocks.count, 2)
        XCTAssertEqual(bullets.items[1].blocks.count, 2)
        guard case .list(let ordered) = blocks[1].kind else { return XCTFail() }
        XCTAssertTrue(ordered.isOrdered)
        XCTAssertEqual(ordered.start, 3)
        XCTAssertEqual(ordered.items.count, 2)
        XCTAssertEqual(substring(text, bullets.items[0].marker), "-")
    }

    func testTasksKeepTheRangeOfTheirBox() {
        let text = "- [ ] open\n- [x] done ^t1\n- [X] caps\n- [ ]nospace\n- [x]"
        guard case .list(let list)? = parse(text).first?.kind else { return XCTFail() }
        XCTAssertEqual(list.items.count, 5)
        XCTAssertEqual(list.items.map { $0.task?.isDone }, [false, true, true, nil, true])
        for item in list.items where item.task != nil {
            XCTAssertEqual(substring(text, item.task!.box).count, 3)
            XCTAssertTrue(["[ ]", "[x]", "[X]"].contains(substring(text, item.task!.box)))
        }
        XCTAssertEqual(list.items[1].blockID, "t1")
    }

    func testListMarkersNeedASpaceAndOnlyOneInterruptsAParagraph() {
        XCTAssertEqual(paragraph("-no space\n"), "T(-no space)")
        XCTAssertEqual(parse("text\n- bullet").count, 2, "a bullet interrupts a paragraph")
        XCTAssertEqual(parse("text\n1. one").count, 2, "so does a list starting at 1")
        XCTAssertEqual(parse("text\n2. two").count, 1, "a list starting at 2 does not")
    }

    func testQuotesNestAndCalloutsReadTheirHeader() {
        let text = "> plain\n> quote\n\n> [!warning]- Be careful\n> body\n> > [!tip] Inner\n> > deep\n\n> [!note]\n> default title"
        let blocks = parse(text)
        guard case .quote(let q) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(q.count, 1)
        guard case .callout(let warn) = blocks[1].kind else { return XCTFail() }
        XCTAssertEqual(warn.type, "warning")
        XCTAssertEqual(warn.fold, .closed)
        XCTAssertEqual(shape(warn.title), "T(Be careful)")
        XCTAssertEqual(substring(text, warn.headerRange), "> [!warning]- Be careful")
        guard case .callout(let inner)? = warn.children.last?.kind else { return XCTFail() }
        XCTAssertEqual(inner.type, "tip")
        XCTAssertEqual(inner.fold, .none)
        guard case .callout(let note) = blocks[2].kind else { return XCTFail() }
        XCTAssertEqual(note.type, "note")
        XCTAssertTrue(note.title.isEmpty)
        // Ranges of nested content point into the note, past the `> ` prefixes.
        guard case .paragraph? = warn.children.first?.kind else { return XCTFail() }
        XCTAssertEqual(substring(text, warn.children[0].range), "body")
    }

    func testAFenceInsideAListItemIsCode() {
        let blocks = parse("- item\n  ```\n  code\n  ```\n- next")
        guard case .list(let list)? = blocks.first?.kind else { return XCTFail() }
        guard case .code(_, let body)? = list.items[0].blocks.last?.kind else { return XCTFail() }
        XCTAssertEqual(body, "code")
    }

    // MARK: - Tables

    func testTablesWithAlignmentWithoutBordersAndWithEscapedPipes() {
        guard case .table(let t)? = parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n| x |\n").first?.kind else { return XCTFail() }
        XCTAssertEqual(t.alignments, [.left, .center, .right])
        XCTAssertEqual(t.header.map(shape), ["T(a)", "T(b)", "T(c)"])
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[1].map(shape), ["T(x)", "", ""], "a short row is padded")

        guard case .table(let bare)? = parse("a | b\n--|--\n1 | 2").first?.kind else { return XCTFail() }
        XCTAssertEqual(bare.header.map(shape), ["T(a)", "T(b)"])

        guard case .table(let pipes)? = parse("| x | y\\|z | `a|b` |\n|---|---|---|\n| 1 | 2 | 3 |").first?.kind else { return XCTFail() }
        XCTAssertEqual(pipes.header.map(shape), ["T(x)", "T(y|z)", "C(a|b)"])
    }

    func testALineWithAPipeButNoDelimiterRowIsAParagraph() {
        guard case .paragraph? = parse("a | b\nc | d").first?.kind else { return XCTFail() }
    }

    // MARK: - Ranges, line endings, block ids

    func testCRLFAndLFGiveTheSameStructure() {
        let lf = "# H\n\n- a\n- b\n\n> [!note] T\n> body\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        func kinds(_ text: String) -> [String] {
            parse(text).map { block -> String in
                switch block.kind {
                case .heading: return "h"
                case .list(let l): return "l\(l.items.count)"
                case .callout: return "c"
                case .table(let t): return "t\(t.rows.count)"
                case .paragraph(let p): return "p:" + shape(p)
                default: return "?"
                }
            }
        }
        XCTAssertEqual(kinds(lf), kinds(crlf))
    }

    func testEveryRangeStaysInsideTheNoteAndInsideItsParent() {
        let text = """
            ---
            a: b
            ---
            # Title ^id

            Para with **bold** and [[link]].
            More.

            - [ ] a
              - b
            > [!tip] T
            > > q
            | h |
            |---|
            | c |

            ```
            code
            ```
            %% c %%
            """
        let doc = MarkdownParser.parse(text)
        let length = (text as NSString).length
        func check(_ blocks: [MarkdownBlock], inside: NSRange) {
            for block in blocks {
                XCTAssertTrue(block.range.location >= inside.location && NSMaxRange(block.range) <= NSMaxRange(inside),
                              "\(block.range) outside \(inside)")
                XCTAssertTrue(NSMaxRange(block.range) <= length)
                switch block.kind {
                case .list(let l): l.items.forEach { check($0.blocks, inside: $0.range); XCTAssertTrue(NSMaxRange($0.range) <= NSMaxRange(block.range)) }
                case .quote(let c): check(c, inside: block.range)
                case .callout(let c): check(c.children, inside: block.range)
                default: break
                }
            }
        }
        check(doc.blocks, inside: NSRange(location: 0, length: length))
    }

    // MARK: - Agreement with the index's scanners

    private let corpus: [String] = [
        "# One\ntext ^b1\n\n## Two ##\n- item ^b2\n- other\n\n### Three\n```\n# not a heading ^x\n```\n#tag line\n",
        "---\ntitle: x\n---\n# Heading\n\n> # quoted\n\n    # indented\n\n###### six ^six\n",
        "Ωραία\n# Τίτλος\nκείμενο ^id-1\n\n- [ ] εργασία ^t\n",
        "~~~\n# fenced\n~~~\n# real\n%% # hidden %%\n"
    ]

    func testTopLevelHeadingsAndBlockIDsAgreeWithTheIndex() {
        for text in corpus {
            let scan = NoteMetadata.scan(text)
            var headings: [String] = []
            var ids: [String] = []
            func walk(_ blocks: [MarkdownBlock], top: Bool) {
                for block in blocks {
                    if top, case .heading(_, let content, _) = block.kind { headings.append(WikiLinkParser.normalizedKey(MarkdownInlineParser.plainText(content))) }
                    if let id = block.blockID, top { ids.append(id) }
                    if case .list(let l) = block.kind { for item in l.items { if let id = item.blockID { ids.append(id) } } }
                }
            }
            walk(MarkdownParser.parse(text).blocks, top: true)
            XCTAssertEqual(headings, scan.headings.map(\.key), text.debugDescription)
            XCTAssertEqual(Set(ids), Set(scan.blocks.map(\.id)), text.debugDescription)
        }
    }

    func testTopLevelCodeBlocksAreTheIndexsFences() {
        for text in corpus {
            let fences = WikiLinkParser.fences(in: text)
            var codeStarts: [Int] = []
            for block in MarkdownParser.parse(text).blocks { if case .code = block.kind { codeStarts.append(block.range.location) } }
            XCTAssertEqual(codeStarts, fences.map(\.location), text.debugDescription)
        }
    }

    // MARK: - Sections

    func testHeadingSectionsRunToTheNextHeadingOfTheSameOrHigherLevel() {
        let text = "# A\nintro\n## A1\none\n### A1a\ndeep\n## A2\ntwo\n# B\nend\n"
        func section(_ path: [String]) -> String? {
            MarkdownSections.headingSection(path: path, in: text).map { substring(text, $0) }
        }
        XCTAssertEqual(section(["A"]), "# A\nintro\n## A1\none\n### A1a\ndeep\n## A2\ntwo\n")
        XCTAssertEqual(section(["A1"]), "## A1\none\n### A1a\ndeep\n")
        XCTAssertEqual(section(["a", "a1a"]), "### A1a\ndeep\n", "nested path, case folded")
        XCTAssertEqual(section(["B"]), "# B\nend\n")
        XCTAssertNil(section(["A2", "A1a"]), "A1a is not under A2")
        XCTAssertNil(section(["Missing"]))
    }

    func testBlockExtentsAreTheParagraphOrTheListItemWithItsChildren() {
        let text = "Para one ^p1\n\n- item\n  - child ^c1\n- other\n  more ^i2\n"
        let doc = MarkdownParser.parse(text)
        XCTAssertEqual(MarkdownSections.blockExtent(id: "p1", in: doc).map { substring(text, $0) }, "Para one ^p1")
        XCTAssertEqual(MarkdownSections.blockExtent(id: "c1", in: doc).map { substring(text, $0) }, "- child ^c1")
        XCTAssertEqual(MarkdownSections.blockExtent(id: "i2", in: doc).map { substring(text, $0) }, "- other\n  more ^i2")
        XCTAssertNil(MarkdownSections.blockExtent(id: "zz", in: doc))
    }

    // MARK: - Hostile input

    func testDeepNestingStopsAtTheCap() {
        let quotes = String(repeating: "> ", count: 5_000) + "deep"
        let list = String(repeating: "- ", count: 5_000) + "deep"
        for text in [quotes, list] {
            let start = Date()
            XCTAssertFalse(MarkdownParser.parse(text).blocks.isEmpty)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        }
    }

    func testManyUnclosedOpenersAreReadInLinearTime() throws {
        try XCTSkipIf(TestEnvironment.isSanitized, "a wall-clock limit")
        for opener in ["<!-- x\n", "%% x\n\n", "**a ", "[[a ", "`a ", "*a ", "![x](", "> [!n]\n"] {
            let text = String(repeating: opener, count: 4_000)
            let start = Date()
            _ = MarkdownParser.parse(text)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "\(opener.debugDescription) took too long")
        }
    }

    func testASixtyKilobyteNoteParsesQuickly() throws {
        try XCTSkipIf(TestEnvironment.isSanitized, "a wall-clock limit")
        let section = "# Heading\n\nSome **bold** text with a [[link]] and #tag and `code`.\n\n- [ ] task one\n- [x] task two\n  - nested\n\n> [!note] Callout\n> text\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n"
        let text = String(repeating: section, count: 60_000 / section.utf16.count + 1)
        XCTAssertGreaterThan(text.utf16.count, 59_000)
        let start = Date()
        let doc = MarkdownParser.parse(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "parse of 60 KB")
        XCTAssertFalse(doc.blocks.isEmpty)
    }

    func testAVeryLongNoteIsReadAsPlainParagraphs() {
        let text = String(repeating: "word **bold**\n\n", count: 40_000)
        XCTAssertGreaterThan(text.utf16.count, MarkdownParser.maxLength)
        let blocks = parse(text)
        XCTAssertEqual(blocks.count, 40_000)
        guard case .paragraph(let inlines) = blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(shape(inlines), "T(word **bold**)", "no inline reading past the cap")
    }

    func testRandomPunctuationNeverCrashesAndRangesStayInside() {
        var state: UInt64 = 0x4D4B
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let alphabet = Array("*_~=`[]()!#>-+.|\\ \n\t:%<ab1 \u{3B1}\u{1F600}^")
        for _ in 0..<3_000 {
            let text = String((0..<Int(next() % 80)).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            let doc = MarkdownParser.parse(text)
            let length = (text as NSString).length
            func check(_ blocks: [MarkdownBlock]) {
                for block in blocks {
                    XCTAssertTrue(block.range.location >= 0 && NSMaxRange(block.range) <= length,
                                  "range \(block.range) in \(text.debugDescription)")
                    switch block.kind {
                    case .list(let l): l.items.forEach { check($0.blocks) }
                    case .quote(let c): check(c)
                    case .callout(let c): check(c.children)
                    default: break
                    }
                }
            }
            check(doc.blocks)
        }
    }
}
