import XCTest
@testable import MedNotes

/// The Greek fold: the Swift side used for typed queries and the SQL side
/// used by the full-text triggers must be the same function.
final class GreekFoldTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-greekfold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    func testTheTableIsSoundAndNoTargetIsAlsoASource() {
        let sources = Set(GreekFold.pairs.map(\.from))
        XCTAssertEqual(sources.count, GreekFold.pairs.count, "a letter is mapped once")
        for pair in GreekFold.pairs {
            XCTAssertFalse(sources.contains(pair.to), "\(pair.to) is both a target and a source")
            XCTAssertNotEqual(pair.from, pair.to)
            // A combining mark in the table would confuse the trigger-text canonicalizer.
            XCTAssertFalse((0x0300...0x036F).contains(pair.from.value), "\(pair.from) is a combining mark")
        }
        // 20 accented and the final sigma, 24 capitals.
        XCTAssertEqual(GreekFold.pairs.count, 21 + 24)
    }

    func testAccentsCapitalsAndFinalSigmaFoldAway() {
        XCTAssertEqual(GreekFold.fold("ασθενής"), "ασθενησ")
        XCTAssertEqual(GreekFold.fold("ΑΣΘΕΝΉΣ"), "ασθενησ")
        XCTAssertEqual(GreekFold.fold("Καρδιολογία"), "καρδιολογια")
        XCTAssertEqual(GreekFold.fold("ΐΰ ϊϋ"), "ιυ ιυ")
        XCTAssertEqual(GreekFold.fold("Hello World"), "hello world", "Latin is lowercased too")
        XCTAssertEqual(GreekFold.fold("Ünïcode"), "Ünïcode", "non-Greek, non-ASCII letters are left to the tokenizer")
    }

    func testDecomposedTextFoldsLikeTheComposedForm() {
        let decomposed = "α\u{0301}σθενη\u{0301}ς"
        XCTAssertEqual(GreekFold.fold(decomposed), "ασθενησ")
    }

    func testFoldingTwiceChangesNothing() {
        for sample in ["ασθενής", "ΚΑΡΔΙΟΛΟΓΊΑ", "mixed Ωμέγα 123", "", "ς"] {
            XCTAssertEqual(GreekFold.fold(GreekFold.fold(sample)), GreekFold.fold(sample))
        }
    }

    /// The SQL expression and the Swift function agree on every table
    /// character and on random composed strings.
    func testTheSQLFoldEqualsTheSwiftFold() throws {
        let path = tempDir.appendingPathComponent("fold.db").path
        let conn = try SQLConnection.testConnection(path: path)
        defer { conn.close() }

        // SQLite's lower() must stay ASCII-only: the Swift side relies on it.
        let lower = try conn.prepare("SELECT lower('Σ'), lower('Ά'), lower('ABC')")
        XCTAssertTrue(try lower.step())
        XCTAssertEqual(lower.columnText(0), "Σ")
        XCTAssertEqual(lower.columnText(1), "Ά")
        XCTAssertEqual(lower.columnText(2), "abc")
        lower.finalize()

        func sqlFold(_ text: String) throws -> String {
            let s = try conn.prepare("SELECT \(GreekFold.sql("?"))")
            defer { s.finalize() }
            s.bind(1, text)
            XCTAssertTrue(try s.step())
            return s.columnText(0) ?? "∅"
        }

        for pair in GreekFold.pairs {
            let text = String(pair.from)
            XCTAssertEqual(try sqlFold(text), GreekFold.fold(text), "U+\(String(pair.from.value, radix: 16))")
        }

        var rng = SplitMix64(seed: 0xF01D)
        let alphabet = Array("αβγδεζηθικλμνξοπρστυφχψωάέήίόύώϊϋΐΰΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩΆΈΉΊΌΎΏΪΫςabcXYZéÉüÜ 019-_#")
        for _ in 0..<600 {
            let length = Int(rng.next() % 24)
            let raw = String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            let text = raw.precomposedStringWithCanonicalMapping
            XCTAssertEqual(try sqlFold(text), GreekFold.fold(text), "for \(text.debugDescription)")
        }
    }

    // MARK: - Trigger text

    func testTriggerTextComparesByWhitespaceOutsideQuotesAndByBytesInsideThem() {
        let trusted = Schema.canonicalTriggerSQL("CREATE TRIGGER t AFTER INSERT ON n BEGIN SELECT replace(x, 'ά', 'α'); END")
        XCTAssertTrue(Schema.sameTriggerSQL(trusted, "CREATE TRIGGER t\n   AFTER INSERT ON n\n BEGIN\n SELECT   replace(x, 'ά', 'α');\n END"))
        XCTAssertFalse(Schema.sameTriggerSQL(trusted, "CREATE TRIGGER t AFTER INSERT ON n BEGIN SELECT replace(x, 'ά ', 'α'); END"),
                       "whitespace inside a literal counts")
        // The decomposed spelling of the same letter is a different literal.
        XCTAssertFalse(Schema.sameTriggerSQL(trusted, "CREATE TRIGGER t AFTER INSERT ON n BEGIN SELECT replace(x, 'α\u{0301}', 'α'); END"))
        XCTAssertFalse(Schema.sameTriggerSQL(nil, "CREATE TRIGGER t"))
    }
}

private struct SplitMix64 {
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
