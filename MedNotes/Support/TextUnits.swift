import Foundation

/// Names for the ASCII characters the Markdown and YAML readers look at.
///
/// Those readers walk a note as UTF-16 code units (`[UInt16]`, `unichar`), the
/// same units `NSRange` counts in. A comparison against `0x23` says nothing to
/// a reader; `ASCII.hash` does. Pure and Foundation-only.
enum ASCII {
    static let tab: UInt16 = 0x09
    static let lineFeed: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let doubleQuote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let percent: UInt16 = 0x25
    static let singleQuote: UInt16 = 0x27
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let dash: UInt16 = 0x2D
    static let period: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39
    static let colon: UInt16 = 0x3A
    static let lessThan: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greaterThan: UInt16 = 0x3E
    static let atSign: UInt16 = 0x40
    static let upperX: UInt16 = 0x58
    static let openBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let closeBracket: UInt16 = 0x5D
    static let caret: UInt16 = 0x5E
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowerX: UInt16 = 0x78
    static let openBrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E

    /// A space or a tab: the blanks Markdown and YAML allow inside a line.
    static func isSpaceOrTab(_ unit: UInt16) -> Bool {
        unit == space || unit == tab
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        unit >= zero && unit <= nine
    }

    /// Whether the scalar is `0`...`9`. Digits of other scripts are not.
    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && isDigit(UInt16(scalar.value))
    }

    static func isLetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    static func isLetterOrDigit(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit)
    }

    /// Any of ``!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~``: the characters a backslash
    /// can escape.
    static func isPunctuation(_ unit: UInt16) -> Bool {
        (exclamation...slash).contains(unit) || (colon...atSign).contains(unit)
            || (openBracket...backtick).contains(unit) || (openBrace...tilde).contains(unit)
    }
}

extension Array where Element == UInt16 {
    /// Whether `prefix` is written at `index`.
    func hasPrefix(_ prefix: [UInt16], at index: Int) -> Bool {
        guard index >= 0, index + prefix.count <= count else { return false }
        for (offset, unit) in prefix.enumerated() where self[index + offset] != unit { return false }
        return true
    }

    /// The first index at or after `start` where `needle` is written.
    func find(_ needle: [UInt16], from start: Int = 0) -> Int? {
        guard let first = needle.first, count >= needle.count, start >= 0 else { return nil }
        var index = start
        while index + needle.count <= count {
            if self[index] == first, hasPrefix(needle, at: index) { return index }
            index += 1
        }
        return nil
    }
}

/// One line of an `NSString`, as `getLineStart` counts them: a line ends at LF,
/// CRLF, CR, U+0085, U+2028 or U+2029.
struct TextLine: Equatable, Sendable {
    /// Where the line begins.
    let start: Int
    /// Just past the line break, or the end of the text (or of the range being
    /// read) when there is none.
    let end: Int
    /// Just past the last character before the break.
    let contentsEnd: Int

    /// The line with its break.
    var range: NSRange { NSRange(location: start, length: end - start) }
    /// The line without its break.
    var contents: NSRange { NSRange(location: start, length: contentsEnd - start) }
    var hasBreak: Bool { end > contentsEnd }
}

extension NSString {
    /// The lines that begin inside `range`, in order. `start` must be where a
    /// line begins. A line that runs past the end of `range` is cut there, and
    /// an empty last line (after a final break) is not produced.
    ///
    /// Lazy: a caller that stops early reads no further.
    func lines(in range: NSRange) -> TextLines {
        TextLines(text: self, location: range.location, limit: min(NSMaxRange(range), length))
    }

    /// The lines from `start` to the end of the text.
    func lines(from start: Int = 0) -> TextLines {
        lines(in: NSRange(location: start, length: max(0, length - start)))
    }
}

struct TextLines: Sequence, IteratorProtocol {
    fileprivate let text: NSString
    fileprivate var location: Int
    fileprivate let limit: Int

    mutating func next() -> TextLine? {
        guard location >= 0, location < limit else { return nil }
        var lineEnd = 0, contentsEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                          for: NSRange(location: location, length: 0))
        let line = TextLine(
            start: location, end: Swift.min(lineEnd, limit),
            contentsEnd: Swift.max(location, Swift.min(contentsEnd, limit)))
        // A line that does not move forward must not repeat.
        location = lineEnd > location ? lineEnd : limit
        return line
    }
}
