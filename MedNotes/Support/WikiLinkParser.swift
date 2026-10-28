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
    static let version = 2

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
        let n = units.count
        guard n > 0 else { return Scan() }
        let ns = text as NSString

        // A ``` line inside the front matter is a value, not a fence; fences
        // are looked for in the body only.
        let bodyStart = FrontMatter.properties(in: ns).map { NSMaxRange($0.range) } ?? 0
        let fences = fenceRanges(units, ns, from: bodyStart)
        var protected = fences
        var links: [ParsedLink] = []
        var fenceIndex = 0
        // The index of the last character a backslash escaped.
        var escaped = -1
        var i = 0

        while i < n {
            while fenceIndex < fences.count, NSMaxRange(fences[fenceIndex]) <= i { fenceIndex += 1 }
            if fenceIndex < fences.count, fences[fenceIndex].location <= i {
                i = NSMaxRange(fences[fenceIndex])
                continue
            }
            switch units[i] {
            case 0x5C: // backslash
                if i + 1 < n, isASCIIPunctuation(units[i + 1]) {
                    escaped = i + 1
                    i += 2
                } else {
                    i += 1
                }
            case 0x60: // `
                var run = 0
                while i + run < n, units[i + run] == 0x60 { run += 1 }
                if let end = closingBackticks(units, from: i + run, length: run, fences: fences) {
                    protected.append(NSRange(location: i, length: end - i))
                    i = end
                } else {
                    i += run
                }
            case 0x25: // %
                if i + 1 < n, units[i + 1] == 0x25,
                   let end = find([0x25, 0x25], in: units, from: i + 2) {
                    protected.append(NSRange(location: i, length: end + 2 - i))
                    i = end + 2
                } else {
                    i += 1
                }
            case 0x3C: // <
                if hasPrefix([0x3C, 0x21, 0x2D, 0x2D], in: units, at: i),
                   let end = find([0x2D, 0x2D, 0x3E], in: units, from: i + 4) {
                    protected.append(NSRange(location: i, length: end + 3 - i))
                    i = end + 3
                } else {
                    i += 1
                }
            case 0x5B: // [
                guard i + 1 < n, units[i + 1] == 0x5B,
                      let parsed = parseLink(units, ns, at: i, escapedIndex: escaped) else {
                    i += 1
                    continue
                }
                links.append(parsed.link)
                i = parsed.end
            default:
                i += 1
            }
        }

        protected.sort { $0.location < $1.location }
        return Scan(links: links, protectedRanges: protected)
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

    // MARK: - Links

    private static func parseLink(
        _ units: [UInt16], _ ns: NSString, at start: Int, escapedIndex: Int
    ) -> (link: ParsedLink, end: Int)? {
        let n = units.count
        var j = start + 2
        let limit = min(n, start + 2 + maxInnerLength + 1)
        while j < limit {
            switch units[j] {
            case 0x5D: // ]
                guard j + 1 < n, units[j + 1] == 0x5D else { return nil }
                return finishLink(units, ns, start: start, close: j, escapedIndex: escapedIndex)
            case 0x5B, 0x0A, 0x0D, 0x60: // [ \n \r `
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

        let chars = Array(raw.utf16)
        var targetPart = raw
        var alias: String?
        if let bar = chars.firstIndex(of: 0x7C) {
            let escapedBar = bar > 0 && chars[bar - 1] == 0x5C
            let head = Array(chars[0..<(escapedBar ? bar - 1 : bar)])
            targetPart = String(decoding: head, as: UTF16.self)
            let tail = String(decoding: Array(chars[(bar + 1)...]), as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            alias = tail.isEmpty ? nil : tail
        }

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
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty || heading != nil || blockID != nil else { return nil }

        let isEmbed = start > 0 && units[start - 1] == 0x21 && escapedIndex != start - 1
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

    // MARK: - Code and comments

    /// Fenced code blocks as ranges of whole lines. A fence opens with three
    /// or more backticks or tildes (at most three spaces in), closes with at
    /// least as many of the same character and nothing else on the line, and
    /// runs to the end of the text when it never closes.
    private static func fenceRanges(_ units: [UInt16], _ ns: NSString, from bodyStart: Int) -> [NSRange] {
        let n = units.count
        var ranges: [NSRange] = []
        var open: (char: UInt16, length: Int, start: Int)?
        var location = min(max(bodyStart, 0), n)
        while location < n {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            var p = location
            while p < contentsEnd, units[p] == 0x20, p - location < 4 { p += 1 }
            if p - location <= 3, p < contentsEnd, units[p] == 0x60 || units[p] == 0x7E {
                let char = units[p]
                var q = p
                while q < contentsEnd, units[q] == char { q += 1 }
                let run = q - p
                if run >= 3 {
                    if let current = open {
                        if char == current.char, run >= current.length,
                           units[q..<contentsEnd].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                            ranges.append(NSRange(location: current.start, length: lineEnd - current.start))
                            open = nil
                        }
                    } else if char != 0x60 || !units[q..<contentsEnd].contains(0x60) {
                        open = (char, run, location)
                    }
                }
            }
            location = lineEnd
        }
        if let current = open {
            ranges.append(NSRange(location: current.start, length: n - current.start))
        }
        return ranges
    }

    /// The index just past the backtick run of exactly `length` that closes a
    /// code span opened before `from`. A span may cross a soft line break but
    /// not a blank line or a fence.
    private static func closingBackticks(
        _ units: [UInt16], from: Int, length: Int, fences: [NSRange]
    ) -> Int? {
        let n = units.count
        var p = from
        while p < n {
            let c = units[p]
            if c == 0x0A || c == 0x0D, isParagraphBreak(units, at: p) { return nil }
            if fences.contains(where: { $0.location == p }) { return nil }
            if c == 0x60 {
                var run = 0
                while p + run < n, units[p + run] == 0x60 { run += 1 }
                if run == length { return p + run }
                p += run
            } else {
                p += 1
            }
        }
        return nil
    }

    private static func isParagraphBreak(_ units: [UInt16], at p: Int) -> Bool {
        let n = units.count
        var q = p + 1
        if units[p] == 0x0D, q < n, units[q] == 0x0A { q += 1 }
        while q < n, units[q] == 0x20 || units[q] == 0x09 { q += 1 }
        return q < n && (units[q] == 0x0A || units[q] == 0x0D)
    }

    // MARK: - Helpers

    private static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit)
            || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    private static func hasPrefix(_ prefix: [UInt16], in units: [UInt16], at index: Int) -> Bool {
        guard index + prefix.count <= units.count else { return false }
        for (offset, unit) in prefix.enumerated() where units[index + offset] != unit { return false }
        return true
    }

    private static func find(_ needle: [UInt16], in units: [UInt16], from: Int) -> Int? {
        guard needle.count > 0, units.count >= needle.count else { return nil }
        var p = from
        while p + needle.count <= units.count {
            if units[p] == needle[0], hasPrefix(needle, in: units, at: p) { return p }
            p += 1
        }
        return nil
    }
}
