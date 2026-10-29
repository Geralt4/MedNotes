import XCTest
@testable import MedNotes

final class TextUnitsTests: XCTestCase {
    // MARK: - Characters

    func testNamedCharactersAreTheCharactersTheyName() {
        let named: [(UInt16, Character)] = [
            (ASCII.tab, "\t"), (ASCII.lineFeed, "\n"), (ASCII.carriageReturn, "\r"), (ASCII.space, " "),
            (ASCII.exclamation, "!"), (ASCII.doubleQuote, "\""), (ASCII.hash, "#"), (ASCII.percent, "%"),
            (ASCII.singleQuote, "'"), (ASCII.openParen, "("), (ASCII.closeParen, ")"), (ASCII.asterisk, "*"),
            (ASCII.plus, "+"), (ASCII.dash, "-"), (ASCII.period, "."), (ASCII.slash, "/"), (ASCII.zero, "0"),
            (ASCII.nine, "9"), (ASCII.colon, ":"), (ASCII.lessThan, "<"), (ASCII.equals, "="),
            (ASCII.greaterThan, ">"), (ASCII.atSign, "@"), (ASCII.upperX, "X"), (ASCII.openBracket, "["),
            (ASCII.backslash, "\\"), (ASCII.closeBracket, "]"), (ASCII.caret, "^"), (ASCII.underscore, "_"),
            (ASCII.backtick, "`"), (ASCII.lowerX, "x"), (ASCII.openBrace, "{"), (ASCII.pipe, "|"),
            (ASCII.tilde, "~"),
        ]
        for (unit, character) in named {
            XCTAssertEqual(Array(String(character).utf16), [unit], "\(character)")
        }
    }

    func testSpaceOrTabAndDigits() {
        XCTAssertTrue(ASCII.isSpaceOrTab(ASCII.space))
        XCTAssertTrue(ASCII.isSpaceOrTab(ASCII.tab))
        XCTAssertFalse(ASCII.isSpaceOrTab(ASCII.lineFeed))
        XCTAssertFalse(ASCII.isSpaceOrTab(0xA0))
        for unit in UInt16(0x2F)...0x3A {
            XCTAssertEqual(ASCII.isDigit(unit), (0x30...0x39).contains(unit), "\(unit)")
        }
        XCTAssertTrue(ASCII.isDigit("7"))
        XCTAssertFalse(ASCII.isDigit("a"))
        XCTAssertFalse(ASCII.isDigit("٣"), "Arabic-Indic three is not an ASCII digit")
        XCTAssertFalse(ASCII.isDigit("\u{FF11}"), "a full-width one is not an ASCII digit")
    }

    func testLettersAndPunctuationAgreeWithTheirDefinitions() {
        let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16)
        for unit in UInt16(0)...0x100 {
            let isLetter = (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            XCTAssertEqual(ASCII.isLetter(unit), isLetter, "\(unit)")
            XCTAssertEqual(ASCII.isLetterOrDigit(unit), isLetter || (0x30...0x39).contains(unit), "\(unit)")
            XCTAssertEqual(ASCII.isPunctuation(unit), punctuation.contains(unit), "\(unit)")
        }
    }

    // MARK: - Searching units

    func testHasPrefixAt() {
        let units = Array("a<!--b".utf16)
        let opener = Array("<!--".utf16)
        XCTAssertTrue(units.hasPrefix(opener, at: 1))
        XCTAssertFalse(units.hasPrefix(opener, at: 0))
        XCTAssertFalse(units.hasPrefix(opener, at: 3), "runs past the end")
        XCTAssertFalse(units.hasPrefix(opener, at: -1))
        XCTAssertTrue(units.hasPrefix([], at: 6), "an empty prefix is written everywhere")
    }

    func testFindFromAStart() {
        let units = Array("%%a%%b%%".utf16)
        let marks = Array("%%".utf16)
        XCTAssertEqual(units.find(marks), 0)
        XCTAssertEqual(units.find(marks, from: 1), 3)
        XCTAssertEqual(units.find(marks, from: 4), 6)
        XCTAssertNil(units.find(marks, from: 7))
        XCTAssertNil(units.find(marks, from: -1))
        XCTAssertNil(units.find([], from: 0), "an empty needle is never found")
        XCTAssertNil([UInt16]().find(marks))
    }

    // MARK: - Lines

    private func lines(_ text: String) -> [TextLine] {
        Array((text as NSString).lines())
    }

    private func texts(_ text: String) -> [String] {
        let ns = text as NSString
        return ns.lines().map { ns.substring(with: $0.contents) }
    }

    func testLinesSplitAtEveryBreakNSStringKnows() {
        XCTAssertEqual(texts("a\nb\r\nc\rd\u{2028}e\u{2029}f\u{0085}g"), ["a", "b", "c", "d", "e", "f", "g"])
    }

    func testBreaksAreKeptInTheRangeButNotInTheContents() {
        let found = lines("ab\r\ncd")
        XCTAssertEqual(found, [
            TextLine(start: 0, end: 4, contentsEnd: 2),
            TextLine(start: 4, end: 6, contentsEnd: 6),
        ])
        XCTAssertTrue(found[0].hasBreak)
        XCTAssertFalse(found[1].hasBreak)
        XCTAssertEqual(found[0].range, NSRange(location: 0, length: 4))
        XCTAssertEqual(found[0].contents, NSRange(location: 0, length: 2))
    }

    func testNothingAfterAFinalBreak() {
        XCTAssertEqual(texts("a\n"), ["a"])
        XCTAssertEqual(texts("a\n\n"), ["a", ""])
        XCTAssertEqual(texts(""), [])
        XCTAssertEqual(texts("\n"), [""])
    }

    func testARangeCutsTheLastLineAndStartsAtItsLocation() {
        let ns = "one\ntwo\nthree" as NSString
        let inner = Array(ns.lines(in: NSRange(location: 4, length: 5)))   // "two\nt"
        XCTAssertEqual(inner, [
            TextLine(start: 4, end: 8, contentsEnd: 7),
            TextLine(start: 8, end: 9, contentsEnd: 9),
        ])
        XCTAssertEqual(Array(ns.lines(from: 8)).map { ns.substring(with: $0.contents) }, ["three"])
    }

    func testARangeLongerThanTheTextIsClamped() {
        let ns = "a\nb" as NSString
        XCTAssertEqual(Array(ns.lines(in: NSRange(location: 0, length: 99))).count, 2)
        XCTAssertEqual(Array(ns.lines(in: NSRange(location: 5, length: 3))).count, 0)
    }

    func testLinesAreLazy() {
        // 200k lines: stopping at the first must not read the rest.
        let ns = String(repeating: "x\n", count: 200_000) as NSString
        var iterator = ns.lines()
        XCTAssertEqual(iterator.next(), TextLine(start: 0, end: 2, contentsEnd: 1))
    }
}
