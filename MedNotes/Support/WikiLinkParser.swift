import Foundation

/// One `[[wiki-link]]` as written in a note.
struct ParsedLink: Equatable, Sendable {
    /// The whole token in UTF-16 units, including a leading `!` for an embed.
    let range: NSRange
    let isEmbed: Bool
    /// Everything between the brackets, trimmed, with `\|` read as `|`. A
    /// note titled "Plan #2" is linked as `[[Plan #2]]`, so resolution tries
    /// this whole text as a title before it falls back to `target`.
    let inner: String
    /// The text before the alias separator, trimmed, `#heading` included: for
    /// `[[Plan #2|see]]` that is "Plan #2", the title the alias belongs to.
    /// Equal to `inner` when there is no alias.
    let head: String
    /// The note or patient name: the text before the first `#` or `|`,
    /// trimmed. Empty for a link to a heading of the note itself.
    let target: String
    let heading: String?
    let blockID: String?
    let alias: String?

    var isSameNote: Bool { target.isEmpty }
}

/// Finds `[[wiki-links]]` the way Obsidian reads them: `[[Note]]`,
/// `[[Note|alias]]`, `[[Note#Heading]]`, `[[Note#^block]]`, `[[#Heading]]` and
/// `![[embed]]`, skipping fenced code, inline code, comments and escaped
/// brackets.
///
/// Pure and Foundation-only: the note store, the editor's styling and the
/// command-line importer all read links through this one definition.
///
/// Deliberate differences from Obsidian, so a parser bug cannot hide text:
/// an unterminated `%%` or `<!--` is not a comment, and a backtick inside the
/// brackets disqualifies the link (a code span wins over a link, as in
/// CommonMark). A fence inside a list item or quote is not recognised.
enum WikiLinkParser {
    /// Bump when the parsing rules change; stored link rows with an older
    /// version are derived again on the next open.
    static let version = 3

    /// A link longer than this between its brackets is stray text.
    static let maxInnerLength = 500

    struct Scan: Equatable, Sendable {
        var links: [ParsedLink] = []
        /// Code and comments, in UTF-16 units, sorted by location. Text in
        /// them is not read for links or mentions.
        var protectedRanges: [NSRange] = []
    }

    static func scan(_ text: String) -> Scan {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return Scan() }
        let ns = text as NSString

        // A ``` line inside the front matter is a value, not a fence; fences
        // are looked for in the body only. For the same reason a backtick, a `%%` or
        // a `<!--` there opens nothing: a lone one paired with a closer in the body
        // and hid its links, tags and headings from the index. `[[links]]` in a
        // value are still read.
        let bodyStart = FrontMatter.properties(in: ns).map { NSMaxRange($0.range) } ?? 0
        var scanner = Scanner(units: units, ns: ns, fences: fenceRanges(units, ns, from: bodyStart),
                              bodyStart: bodyStart)
        return scanner.run()
    }

    /// The fenced code blocks of a note's body (front matter excluded) exactly
    /// as `scan` reads them, so a block parser and the index agree on what is code.
    static func fences(in text: String) -> [NSRange] {
        let ns = text as NSString
        let bodyStart = FrontMatter.properties(in: ns).map { NSMaxRange($0.range) } ?? 0
        return fenceRanges(Array(text.utf16), ns, from: bodyStart)
    }

    // MARK: - Keys

    /// What two spellings of a name must share to count as the same: NFC,
    /// case, diacritics (a Greek tonos) and width folded, whitespace
    /// collapsed. Final sigma folds to sigma.
    static func normalizedKey(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        let folded = composed.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{03C2}", with: "\u{03C3}")
        return folded
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    // MARK: - Scanner

    /// Walks the text once, left to right. Fenced code is jumped over; at every
    /// other character the matching `skip...` or `readLink` function looks for
    /// a code span, a comment or a link and returns where to go on.
    private struct Scanner {
        let units: [UInt16]
        let ns: NSString
        let fences: [NSRange]
        let fenceStarts: Set<Int>
        /// Where the note's body begins. A code span or comment cannot open
        /// before it, in the front matter.
        let bodyStart: Int
        /// Code and comments found so far, fences included.
        var protectedRanges: [NSRange]
        var links: [ParsedLink] = []
        /// The index of the last character a backslash escaped (`\!` is not an embed marker).
        var escaped = -1

        // A search that found no closer once will find none later in the same
        // stretch, so a text full of unclosed openers is still read in linear
        // time (a hostile note took seconds without this).
        /// Code-span run length -> where the failed search stopped.
        var backtickSearchFailedUntil: [Int: Int] = [:]
        var noPercentCloser = false
        var noHTMLCloser = false

        static let percentMarks: [UInt16] = [ASCII.percent, ASCII.percent]
        static let htmlOpen = Array("<!--".utf16)
        static let htmlClose = Array("-->".utf16)

        init(units: [UInt16], ns: NSString, fences: [NSRange], bodyStart: Int) {
            self.units = units
            self.ns = ns
            self.fences = fences
            self.bodyStart = bodyStart
            self.fenceStarts = Set(fences.map(\.location))
            self.protectedRanges = fences
        }

        mutating func run() -> Scan {
            var fenceIndex = 0
            var i = 0
            while i < units.count {
                // Fenced code is jumped over whole.
                while fenceIndex < fences.count, NSMaxRange(fences[fenceIndex]) <= i { fenceIndex += 1 }
                if fenceIndex < fences.count, fences[fenceIndex].location <= i {
                    i = NSMaxRange(fences[fenceIndex])
                    continue
                }
                switch units[i] {
                case ASCII.backslash: i = skipEscape(at: i)
                case ASCII.backtick where i >= bodyStart: i = skipCodeSpan(at: i)
                case ASCII.percent where i >= bodyStart: i = skipPercentComment(at: i)
                case ASCII.lessThan where i >= bodyStart: i = skipHTMLComment(at: i)
                case ASCII.openBracket: i = readLink(at: i)
                default: i += 1
                }
            }
            protectedRanges.sort { $0.location < $1.location }
            return Scan(links: links, protectedRanges: protectedRanges)
        }

        /// A backslash before punctuation escapes it.
        mutating func skipEscape(at i: Int) -> Int {
            guard i + 1 < units.count, ASCII.isPunctuation(units[i + 1]) else { return i + 1 }
            escaped = i + 1
            return i + 2
        }

        /// A run of backticks and the run of the same length that closes it.
        mutating func skipCodeSpan(at i: Int) -> Int {
            var run = 0
            while i + run < units.count, units[i + run] == ASCII.backtick { run += 1 }
            guard let end = WikiLinkParser.closingBackticks(
                units, from: i + run, length: run, fenceStarts: fenceStarts,
                failedUntil: &backtickSearchFailedUntil) else { return i + run }
            protectedRanges.append(NSRange(location: i, length: end - i))
            return end
        }

        /// `%% ... %%`; an unterminated `%%` is not a comment.
        mutating func skipPercentComment(at i: Int) -> Int {
            guard !noPercentCloser, units.hasPrefix(Scanner.percentMarks, at: i) else { return i + 1 }
            guard let end = units.find(Scanner.percentMarks, from: i + 2) else {
                noPercentCloser = true
                return i + 1
            }
            protectedRanges.append(NSRange(location: i, length: end + 2 - i))
            return end + 2
        }

        /// `<!-- ... -->`; an unterminated `<!--` is not a comment.
        mutating func skipHTMLComment(at i: Int) -> Int {
            guard !noHTMLCloser, units.hasPrefix(Scanner.htmlOpen, at: i) else { return i + 1 }
            guard let end = units.find(Scanner.htmlClose, from: i + Scanner.htmlOpen.count) else {
                noHTMLCloser = true
                return i + 1
            }
            protectedRanges.append(NSRange(location: i, length: end + Scanner.htmlClose.count - i))
            return end + Scanner.htmlClose.count
        }

        /// `[[...]]`; when it is not a link the `[` is ordinary text.
        mutating func readLink(at i: Int) -> Int {
            guard i + 1 < units.count, units[i + 1] == ASCII.openBracket,
                  let parsed = WikiLinkParser.parseLink(units, ns, at: i, escapedIndex: escaped) else { return i + 1 }
            links.append(parsed.link)
            return parsed.end
        }
    }

    // MARK: - Links

    private static func parseLink(
        _ units: [UInt16], _ ns: NSString, at start: Int, escapedIndex: Int
    ) -> (link: ParsedLink, end: Int)? {
        let n = units.count
        var j = start + 2
        let limit = min(n, start + 2 + maxInnerLength + 1)
        while j < limit {
            switch units[j] {
            case ASCII.closeBracket:
                guard j + 1 < n, units[j + 1] == ASCII.closeBracket else { return nil }
                return finishLink(units, ns, start: start, close: j, escapedIndex: escapedIndex)
            case ASCII.openBracket, ASCII.lineFeed, ASCII.carriageReturn, ASCII.backtick: // [ \n \r `
                return nil
            default:
                j += 1
            }
        }
        return nil
    }

    private static func finishLink(
        _ units: [UInt16], _ ns: NSString, start: Int, close: Int, escapedIndex: Int
    ) -> (link: ParsedLink, end: Int)? {
        let raw = ns.substring(with: NSRange(location: start + 2, length: close - (start + 2)))
        let whole = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return nil }

        let (targetPart, alias) = splitAlias(raw)
        let (target, heading, blockID) = splitHeading(targetPart)
        guard !target.isEmpty || heading != nil || blockID != nil else { return nil }

        let isEmbed = start > 0 && units[start - 1] == ASCII.exclamation && escapedIndex != start - 1
        let first = isEmbed ? start - 1 : start
        let link = ParsedLink(
            range: NSRange(location: first, length: close + 2 - first),
            isEmbed: isEmbed,
            inner: whole.replacingOccurrences(of: "\\|", with: "|"),
            head: targetPart.trimmingCharacters(in: .whitespacesAndNewlines),
            target: target,
            heading: heading,
            blockID: blockID,
            alias: alias)
        return (link, close + 2)
    }

    /// Splits `Note#Heading|alias` at the first `|`. A backslash in front of it
    /// (the way a table cell needs it written) is dropped. An empty alias is none.
    private static func splitAlias(_ raw: String) -> (targetPart: String, alias: String?) {
        let chars = Array(raw.utf16)
        guard let bar = chars.firstIndex(of: ASCII.pipe) else { return (raw, nil) }
        let escapedBar = bar > 0 && chars[bar - 1] == ASCII.backslash
        let head = String(decoding: chars[0..<(escapedBar ? bar - 1 : bar)], as: UTF16.self)
        let tail = String(decoding: chars[(bar + 1)...], as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, tail.isEmpty ? nil : tail)
    }

    /// Splits `Note#Heading` or `Note#^block` at the first `#`.
    private static func splitHeading(_ targetPart: String) -> (target: String, heading: String?, blockID: String?) {
        var heading: String?
        var blockID: String?
        var target = targetPart
        if let hash = targetPart.firstIndex(of: "#") {
            target = String(targetPart[..<hash])
            let after = String(targetPart[targetPart.index(after: hash)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if after.hasPrefix("^") {
                let id = String(after.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                blockID = id.isEmpty ? nil : id
            } else if !after.isEmpty {
                heading = after
            }
        }
        return (target.trimmingCharacters(in: .whitespacesAndNewlines), heading, blockID)
    }

    // MARK: - Code and comments

    /// Fenced code blocks as ranges of whole lines. A fence opens with three
    /// or more backticks or tildes (at most three spaces in), closes with at
    /// least as many of the same character and nothing else on the line, and
    /// runs to the end of the text when it never closes.
    private static func fenceRanges(_ units: [UInt16], _ ns: NSString, from bodyStart: Int) -> [NSRange] {
        let n = units.count
        var ranges: [NSRange] = []
        var open: (char: UInt16, length: Int, start: Int)?
        for line in ns.lines(from: min(max(bodyStart, 0), n)) {
            let location = line.start, contentsEnd = line.contentsEnd, lineEnd = line.end
            var p = location
            while p < contentsEnd, units[p] == ASCII.space, p - location < 4 { p += 1 }
            if p - location <= 3, p < contentsEnd, units[p] == ASCII.backtick || units[p] == ASCII.tilde {
                let char = units[p]
                var q = p
                while q < contentsEnd, units[q] == char { q += 1 }
                let run = q - p
                if run >= 3 {
                    if let current = open {
                        if char == current.char, run >= current.length,
                           units[q..<contentsEnd].allSatisfy(ASCII.isSpaceOrTab) {
                            ranges.append(NSRange(location: current.start, length: lineEnd - current.start))
                            open = nil
                        }
                    } else if char != ASCII.backtick || !units[q..<contentsEnd].contains(ASCII.backtick) {
                        open = (char, run, location)
                    }
                }
            }
        }
        if let current = open {
            ranges.append(NSRange(location: current.start, length: n - current.start))
        }
        return ranges
    }

    /// The index just past the backtick run of exactly `length` that closes a
    /// code span opened before `from`. A span may cross a soft line break but
    /// not a blank line or a fence. When none is found, `failedUntil[length]`
    /// remembers where the search stopped: an opener of the same length before
    /// that point has no closer either.
    private static func closingBackticks(
        _ units: [UInt16], from: Int, length: Int, fenceStarts: Set<Int>, failedUntil: inout [Int: Int]
    ) -> Int? {
        if let limit = failedUntil[length], from <= limit { return nil }
        let n = units.count
        var p = from
        while p < n {
            let c = units[p]
            if c == ASCII.lineFeed || c == ASCII.carriageReturn, isParagraphBreak(units, at: p) { break }
            if fenceStarts.contains(p) { break }
            if c == ASCII.backtick {
                var run = 0
                while p + run < n, units[p + run] == ASCII.backtick { run += 1 }
                if run == length { return p + run }
                p += run
            } else {
                p += 1
            }
        }
        failedUntil[length] = p
        return nil
    }

    private static func isParagraphBreak(_ units: [UInt16], at p: Int) -> Bool {
        let n = units.count
        var q = p + 1
        if units[p] == ASCII.carriageReturn, q < n, units[q] == ASCII.lineFeed { q += 1 }
        while q < n, ASCII.isSpaceOrTab(units[q]) { q += 1 }
        return q < n && (units[q] == ASCII.lineFeed || units[q] == ASCII.carriageReturn)
    }

    // MARK: - Helpers

}
