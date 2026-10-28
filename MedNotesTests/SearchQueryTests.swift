import XCTest
@testable import MedNotes

final class SearchQueryTests: XCTestCase {
    private func root(_ text: String) -> SearchQuery.Node? { SearchQuery.parse(text).root }

    func testWordsAreAndedAndEachIsAPrefixWord() {
        XCTAssertEqual(root("cardio"), .word("cardio"))
        XCTAssertEqual(root("chest pain"), .and([.word("chest"), .word("pain")]))
        XCTAssertNil(root(""))
        XCTAssertNil(root("   "))
    }

    func testAWordWithPunctuationInsideIsOnePhrase() {
        XCTAssertEqual(root("C3-C4"), .phrase(["C3", "C4"], prefix: true))
        XCTAssertEqual(root("2024-05-01"), .phrase(["2024", "05", "01"], prefix: true))
        XCTAssertEqual(root("zzz-nothing-matches"), .phrase(["zzz", "nothing", "matches"], prefix: true))
    }

    func testAQuotedPhraseIsExactAndAnUnclosedOneIsStillBeingTyped() {
        XCTAssertEqual(root("\"chest pain\""), .phrase(["chest", "pain"], prefix: false))
        XCTAssertEqual(root("\"chest pa"), .phrase(["chest", "pa"], prefix: true))
        XCTAssertNil(root("\"\""))
        XCTAssertNil(root("\"???\""))
    }

    func testOrIsUpperCaseOnly() {
        XCTAssertEqual(root("a OR b"), .or([.word("a"), .word("b")]))
        XCTAssertEqual(root("a or b"), .and([.word("a"), .word("or"), .word("b")]))
        XCTAssertEqual(root("a b OR c"), .or([.and([.word("a"), .word("b")]), .word("c")]))
        XCTAssertEqual(root("OR a"), .word("a"))
        XCTAssertEqual(root("a OR"), .word("a"))
    }

    func testGroupsOverrideTheOrder() {
        XCTAssertEqual(
            root("a (b OR c)"),
            .and([.word("a"), .or([.word("b"), .word("c")])]))
        XCTAssertEqual(
            root("(a OR b) c"),
            .and([.or([.word("a"), .word("b")]), .word("c")]))
        XCTAssertEqual(root("(a"), .word("a"))                      // closes at the end
        XCTAssertEqual(root("a)"), .word("a"))                      // a stray bracket is ignored
        XCTAssertNil(root("()"))
    }

    func testAMinusExcludesOnlyAtTheStartOfATerm() {
        XCTAssertEqual(root("-digoxin"), .not(.word("digoxin")))
        XCTAssertEqual(root("a -b"), .and([.word("a"), .not(.word("b"))]))
        XCTAssertEqual(root("-(a OR b)"), .not(.or([.word("a"), .word("b")])))
        XCTAssertEqual(root("-tag:x"), .not(.tag("x")))
        XCTAssertEqual(root("a - b"), .and([.word("a"), .word("b")]))   // a lone dash is nothing
        XCTAssertEqual(root("--a"), .not(.not(.word("a"))))
        XCTAssertNil(root("-"))
    }

    func testTagOperator() {
        XCTAssertEqual(root("tag:cardio"), .tag("cardio"))
        XCTAssertEqual(root("tag:#cardio"), .tag("cardio"))
        XCTAssertEqual(root("TAG:Cardio/Ward"), .tag("cardio/ward"))
        XCTAssertEqual(root("tag:ΚΑΡΔΙΟΛΟΓΙΑ"), .tag("καρδιολογια"))
        XCTAssertNil(root("tag:"))
        XCTAssertNil(root("tag:#"))
    }

    func testPropertyOperatorAndBrackets() {
        XCTAssertEqual(root("property:status"), .property(key: "status", value: nil))
        XCTAssertEqual(root("property:Status:Active"), .property(key: "status", value: "active"))
        XCTAssertEqual(
            root("property:status:\"in progress\""),
            .property(key: "status", value: "in progress"))
        XCTAssertEqual(root("[status]"), .property(key: "status", value: nil))
        XCTAssertEqual(root("[status:active]"), .property(key: "status", value: "active"))
        XCTAssertEqual(root("[status:]"), .property(key: "status", value: nil))
        XCTAssertEqual(root("[status"), .property(key: "status", value: nil))
        XCTAssertNil(root("[]"))
        XCTAssertNil(root("property:"))
    }

    func testPatientAndLinkedOperators() {
        XCTAssertEqual(root("patient:nikos"), .patient(["nikos"]))
        XCTAssertEqual(root("patient:\"Nikos Georgiou\""), .patient(["Nikos", "Georgiou"]))
        XCTAssertEqual(root("linked:Plan"), .linked("plan"))
        XCTAssertEqual(root("linked:\"Cardiology Plan\""), .linked("cardiology plan"))
        XCTAssertEqual(root("linked:[[Plan]]"), .linked("plan"))
        XCTAssertEqual(root("linked:[[Ασθενής]]"), .linked("ασθενησ"), "keys fold a final sigma like link resolution")
        XCTAssertEqual(root("linked:[[Missing note]] x"), .and([.linked("missing note"), .word("x")]))
        XCTAssertEqual(root("linked:[[Open"), .linked("open"))
    }

    func testALinkPastedFromANoteSearchesForNotesLinkingToIt() {
        XCTAssertEqual(root("[[Cardiology plan]]"), .linked("cardiology plan"))
        XCTAssertEqual(root("[[Plan|alias]] x"), .and([.linked("plan"), .word("x")]))
        XCTAssertEqual(root("[[Open"), .linked("open"))
        XCTAssertNil(root("[[]]"))
    }

    func testUnknownOperatorsAreText() {
        XCTAssertEqual(root("foo:bar"), .phrase(["foo", "bar"], prefix: true))
        XCTAssertEqual(root("http://x"), .phrase(["http", "x"], prefix: true))
    }

    func testOperatorsCombineWithText() {
        XCTAssertEqual(
            root("tag:cardio -digoxin ward"),
            .and([.tag("cardio"), .not(.word("digoxin")), .word("ward")]))
    }

    func testHighlightTermsLeaveOutNegationsAndOperators() {
        let q = SearchQuery.parse("chest \"acute pain\" -digoxin tag:cardio patient:nikos (x OR y)")
        XCTAssertEqual(q.highlightTerms, ["chest", "acute", "pain", "x", "y"])
    }

    func testUsesTags() {
        XCTAssertTrue(SearchQuery.parse("a -tag:b").usesTags)
        XCTAssertFalse(SearchQuery.parse("a b").usesTags)
        XCTAssertFalse(SearchQuery.parse("").usesTags)
    }

    func testGreekWords() {
        XCTAssertEqual(root("ασθενής πόνος"), .and([.word("ασθενής"), .word("πόνος")]))
        XCTAssertEqual(root("-ασθενής"), .not(.word("ασθενής")))
    }

    func testMatchStringIsAlwaysQuotedLettersAndDigits() {
        XCTAssertEqual(SearchQuery.matchString(tokens: ["chest"], prefix: true), "\"chest\"*")
        XCTAssertEqual(SearchQuery.matchString(tokens: ["a", "b"], prefix: false), "\"a b\"")
        XCTAssertEqual(SearchQuery.matchString(tokens: ["a\"b", "c*"], prefix: true), "\"a b c\"*")
        XCTAssertNil(SearchQuery.matchString(tokens: ["???"], prefix: true))
        XCTAssertNil(SearchQuery.matchString(tokens: [], prefix: false))
    }

    func testLimitsKeepOverlongOrDeeplyNestedInputBounded() {
        let deep = String(repeating: "(", count: 5_000) + "a" + String(repeating: ")", count: 5_000)
        _ = SearchQuery.parse(deep)   // must return, whatever it finds
        let nested = String(repeating: "(", count: 40) + "a" + String(repeating: ")", count: 40)
        XCTAssertEqual(SearchQuery.parse(nested).root, .word("a"))
        let long = String(repeating: "word ", count: 5_000)
        let node = SearchQuery.parse(long).root
        if case .and(let items)? = node { XCTAssertLessThanOrEqual(items.count, SearchQuery.maxTokens) }
        else { XCTFail("expected an AND of words") }
    }

    /// Random punctuation never crashes, and every MATCH string that could be
    /// produced from the result is made only of quoted letters and digits.
    func testFuzzNeverCrashesAndOnlyEverProducesSafeMatchStrings() throws {
        var rng = SplitMix(seed: 0x5EA7C4)
        let alphabet = Array("ab Cd1 \"()[]:-#*^\\|OR tag:property:patient:linked: ασ ή€\n\t'")
        let safe = try NSRegularExpression(pattern: #"^"[\p{L}\p{N}]+( [\p{L}\p{N}]+)*"\*?$"#)
        for _ in 0..<4_000 {
            let count = Int(rng.next() % 40)
            let text = String((0..<count).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            let query = SearchQuery.parse(text)
            var strings: [String] = []
            func walk(_ node: SearchQuery.Node) {
                switch node {
                case .and(let items), .or(let items): items.forEach(walk)
                case .not(let inner): walk(inner)
                case .word(let token):
                    if let s = SearchQuery.matchString(tokens: [token], prefix: true) { strings.append(s) }
                case .phrase(let tokens, let prefix):
                    if let s = SearchQuery.matchString(tokens: tokens, prefix: prefix) { strings.append(s) }
                case .patient(let tokens):
                    if let s = SearchQuery.matchString(tokens: tokens, prefix: true) { strings.append(s) }
                case .tag, .property, .linked: break
                }
            }
            if let root = query.root { walk(root) }
            for s in strings {
                let range = NSRange(s.startIndex..., in: s)
                XCTAssertNotNil(safe.firstMatch(in: s, range: range), "unsafe MATCH string \(s) from \(text.debugDescription)")
            }
        }
    }
}

/// Small seeded generator so a failing fuzz case can be replayed.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
