import Foundation

/// Folds Greek text so that accents, capitals and the final sigma stop
/// mattering to a search: `ασθενής`, `ΑΣΘΕΝΉΣ` and `ασθενησ` are one word.
///
/// The full-text index cannot do this itself: FTS5's `unicode61` tokenizer
/// drops combining marks (so decomposed text already matches) and folds case,
/// but leaves the precomposed tonos (`ά`) and `ς` alone, and SQLite's
/// `lower()` only lowercases ASCII. So the text is folded where it enters the
/// index, by `replace()` calls in the triggers (`sql(_:)`), and the typed
/// query is folded the same way (`fold(_:)`). Both come from one table, which
/// a test runs against SQLite to keep them identical.
///
/// Polytonic Greek (`Ἀθῆναι`) is not covered. Pure and Foundation-only: the
/// import tool compiles it too.
enum GreekFold {
    /// Scalar replacements. No target is also a source, so the order does not
    /// matter. Written as numbers, so no source file can hold a different
    /// Unicode normalization of a letter than the one meant.
    static let pairs: [(from: Unicode.Scalar, to: Unicode.Scalar)] = {
        func scalar(_ value: UInt32) -> Unicode.Scalar { Unicode.Scalar(value)! }
        var out: [(Unicode.Scalar, Unicode.Scalar)] = []
        // Accented lowercase: ά έ ή ί ό ύ ώ ϊ ϋ ΐ ΰ
        let accented: [(UInt32, UInt32)] = [
            (0x03AC, 0x03B1), (0x03AD, 0x03B5), (0x03AE, 0x03B7), (0x03AF, 0x03B9),
            (0x03CC, 0x03BF), (0x03CD, 0x03C5), (0x03CE, 0x03C9), (0x03CA, 0x03B9),
            (0x03CB, 0x03C5), (0x0390, 0x03B9), (0x03B0, 0x03C5),
            // Accented capitals: Ά Έ Ή Ί Ό Ύ Ώ Ϊ Ϋ
            (0x0386, 0x03B1), (0x0388, 0x03B5), (0x0389, 0x03B7), (0x038A, 0x03B9),
            (0x038C, 0x03BF), (0x038E, 0x03C5), (0x038F, 0x03C9), (0x03AA, 0x03B9),
            (0x03AB, 0x03C5),
            // Final sigma ς
            (0x03C2, 0x03C3),
            // The same letters spelled with oxia (U+1F71 for ά, from older
            // sources and PDFs). Canonically equivalent to the tonos forms, but a
            // different byte sequence that SQL's replace() would not otherwise see.
            (0x1F71, 0x03B1), (0x1F73, 0x03B5), (0x1F75, 0x03B7), (0x1F77, 0x03B9),
            (0x1F79, 0x03BF), (0x1F7B, 0x03C5), (0x1F7D, 0x03C9),
            (0x1FD3, 0x03B9), (0x1FE3, 0x03C5),
            (0x1FBB, 0x03B1), (0x1FC9, 0x03B5), (0x1FCB, 0x03B7), (0x1FDB, 0x03B9),
            (0x1FF9, 0x03BF), (0x1FEB, 0x03C5), (0x1FFB, 0x03C9)
        ]
        for (from, to) in accented { out.append((scalar(from), scalar(to))) }
        // Plain capitals Α…Ω (U+0391…U+03A9, without the unassigned U+03A2).
        for value in UInt32(0x0391)...UInt32(0x03A9) where value != 0x03A2 {
            out.append((scalar(value), scalar(value + 0x20)))
        }
        return out
    }()

    private static let map: [Unicode.Scalar: Unicode.Scalar] = {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.from, $0.to) })
    }()

    /// NFC, then ASCII-only lowercase (what SQLite's `lower()` does), then
    /// the table. Not `lowercased()`: that also lowercases other scripts,
    /// which the SQL side would leave alone.
    static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.value >= 0x41, scalar.value <= 0x5A {
                scalars.append(Unicode.Scalar(scalar.value + 0x20)!)
            } else {
                scalars.append(map[scalar] ?? scalar)
            }
        }
        return String(scalars)
    }

    /// The same fold as a SQL expression over `expression`: `lower()` and a
    /// nested `replace()` per table entry. For trigger and refill statements.
    static func sql(_ expression: String) -> String {
        var result = "lower(\(expression))"
        for pair in pairs {
            result = "replace(\(result), '\(String(pair.from))', '\(String(pair.to))')"
        }
        return result
    }
}
