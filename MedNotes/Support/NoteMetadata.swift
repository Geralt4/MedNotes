import Foundation

/// What a note says about itself, read from its text: properties, headings,
/// block ids and `#tags`. Pure and Foundation-only, built on the same code
/// and comment ranges as `WikiLinkParser`, so a heading or tag in a code
/// block, a comment, the front matter or a link is never one.
///
/// Rules follow Obsidian's:
/// - A heading is `#` to `######`, a space, text; an optional closing run of
///   `#` is not part of the text. Setext headings are not read.
/// - A block id is `^id` ending a line (or alone on one), after whitespace,
///   with letters, digits and hyphens only.
/// - A tag is `#` at the start of a line or after whitespace, then letters
///   (any script, accents included), digits, `_`, `-` and `/`, with at least
///   one character that is not a digit. `#NOF` and `#E11` are tags, as in
///   Obsidian; `#3` and `a#b` are not.
enum NoteMetadata {
    /// Bump when the rules change; stored rows from an older version are
    /// derived again on the next open.
    static let version = 2

    struct Heading: Equatable, Sendable {
        let level: Int
        let text: String
        /// `WikiLinkParser.normalizedKey(text)`, what `[[Note#Heading]]` is
        /// matched against.
        let key: String
        /// Where the heading's line starts, UTF-16.
        let offset: Int
        let length: Int
    }

    struct BlockID: Equatable, Sendable {
        let id: String
        /// Where the line carrying the id starts.
        let offset: Int
    }

    struct InlineTag: Equatable, Sendable {
        /// Without the `#`, as written.
        let tag: String
        let key: String
        /// Including the `#`.
        let range: NSRange
    }

    struct Scan: Equatable, Sendable {
        var headings: [Heading] = []
        var blocks: [BlockID] = []
        var tags: [InlineTag] = []
        /// The front matter's properties, when the note opens with some.
        var properties: PropertySet?
    }

    static func scan(_ text: String, links: WikiLinkParser.Scan? = nil) -> Scan {
        let ns = text as NSString
        let length = ns.length
        var result = Scan()
        guard length > 0 else { return result }

        let linkScan = links ?? WikiLinkParser.scan(text)
        let properties = FrontMatterYAML.parse(ns)
        result.properties = properties

        var lineBlockers = linkScan.protectedRanges
        if let block = properties?.block { lineBlockers.append(block.range) }
        let linesBlocked = merged(lineBlockers)
        let tagsBlocked = merged(lineBlockers + linkScan.links.map(\.range))

        var location = 0
        while location < length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            defer { location = lineEnd > location ? lineEnd : length }

            // A heading or block id is skipped when the line sits inside code,
            // a comment or the front matter that runs across lines. A code
            // span that opens and closes on the line (`` `x` `` at its start)
            // does not make the line code.
            let covering = containing(linesBlocked, location)
            let insideMultiLine = covering.map { $0.location < location || NSMaxRange($0) > contentsEnd } ?? false
            if !insideMultiLine {
                if let heading = heading(ns, from: location, to: contentsEnd) {
                    result.headings.append(heading)
                }
                if let block = blockID(ns, from: location, to: contentsEnd) {
                    result.blocks.append(block)
                }
            }
            // Tags are checked one `#` at a time against the same ranges.
            tags(ns, from: location, to: contentsEnd, blocked: tagsBlocked, into: &result.tags)
        }
        return result
    }

    // MARK: - Headings

    private static func heading(_ ns: NSString, from start: Int, to end: Int) -> Heading? {
        var p = start
        while p < end, ns.character(at: p) == ASCII.space, p - start < 4 { p += 1 }
        guard p - start <= 3 else { return nil }
        var hashes = 0
        while p < end, ns.character(at: p) == ASCII.hash { hashes += 1; p += 1 }
        guard (1...6).contains(hashes), p < end,
              ASCII.isSpaceOrTab(ns.character(at: p)) else { return nil }
        var text = ns.substring(with: NSRange(location: p, length: end - p))
            .trimmingCharacters(in: .whitespaces)
        // A closing run of #s, set off by a space, is not part of the text.
        if let closing = text.range(of: #"(^|[ \t])#+[ \t]*$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // `## Plan ^plan` is the heading "Plan" carrying the block id `plan`.
        if let (trimmed, _) = splitTrailingBlockID(Array(text.utf16)), !trimmed.isEmpty {
            text = String(decoding: trimmed, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        return Heading(level: hashes, text: text, key: WikiLinkParser.normalizedKey(text),
                       offset: start, length: end - start)
    }

    // MARK: - Block ids

    /// `^id` as the last word of a line, after a space or at the start: the
    /// line without it (trailing blanks off), and the id.
    static func splitTrailingBlockID(_ units: [UInt16]) -> (trimmed: [UInt16], id: String)? {
        var stop = units.count
        while stop > 0, ASCII.isSpaceOrTab(units[stop - 1]) { stop -= 1 }
        var p = stop
        while p > 0, isIDChar(units[p - 1]) { p -= 1 }
        guard p > 0, stop - p >= 1, units[p - 1] == ASCII.caret else { return nil }
        let caret = p - 1
        guard caret == 0 || ASCII.isSpaceOrTab(units[caret - 1]) else { return nil }
        var keep = caret
        while keep > 0, ASCII.isSpaceOrTab(units[keep - 1]) { keep -= 1 }
        return (Array(units[0..<keep]), String(decoding: units[p..<stop], as: UTF16.self))
    }

    private static func blockID(_ ns: NSString, from start: Int, to end: Int) -> BlockID? {
        var stop = end
        while stop > start, ASCII.isSpaceOrTab(ns.character(at: stop - 1)) { stop -= 1 }
        var p = stop
        while p > start, isIDChar(ns.character(at: p - 1)) { p -= 1 }
        guard p > start, stop - p >= 1, ns.character(at: p - 1) == ASCII.caret else { return nil }   // ^
        let caret = p - 1
        guard caret == start || ASCII.isSpaceOrTab(ns.character(at: caret - 1)) else { return nil }
        return BlockID(id: ns.substring(with: NSRange(location: p, length: stop - p)), offset: start)
    }

    private static func isIDChar(_ unit: unichar) -> Bool {
        ASCII.isLetterOrDigit(unit) || unit == ASCII.dash
    }

    // MARK: - Tags

    private static func tags(
        _ ns: NSString, from start: Int, to end: Int, blocked: [NSRange], into out: inout [InlineTag]
    ) {
        var p = start
        while p < end {
            guard ns.character(at: p) == ASCII.hash else { p += 1; continue }
            let hash = p
            p += 1
            if hash > start, !isWhitespace(ns.character(at: hash - 1)) { continue }
            if isInside(blocked, hash) { continue }
            var q = p
            var hasNonDigit = false
            while q < end, isTagChar(ns.character(at: q)) {
                let unit = ns.character(at: q)
                if !ASCII.isDigit(unit) { hasNonDigit = true }
                q += 1
            }
            guard q > p, hasNonDigit else { continue }
            let tag = ns.substring(with: NSRange(location: p, length: q - p))
            out.append(InlineTag(
                tag: tag, key: WikiLinkParser.normalizedKey(tag),
                range: NSRange(location: hash, length: q - hash)))
            p = q
        }
    }

    private static func isTagChar(_ unit: unichar) -> Bool {
        if unit == ASCII.underscore || unit == ASCII.dash || unit == ASCII.slash { return true }   // _ - /
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }   // not a lone surrogate
        let props = scalar.properties
        if props.isAlphabetic || props.numericType != nil { return true }
        switch props.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    // MARK: - Ranges and characters

    /// Sorted, non-overlapping ranges covering the same units.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = out.last, range.location <= NSMaxRange(last) {
                out[out.count - 1] = NSRange(
                    location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// The merged range that contains `location`, if any.
    private static func containing(_ ranges: [NSRange], _ location: Int) -> NSRange? {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            let range = ranges[mid]
            if location < range.location {
                high = mid
            } else if location >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return range
            }
        }
        return nil
    }

    private static func isInside(_ ranges: [NSRange], _ location: Int) -> Bool {
        containing(ranges, location) != nil
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        ASCII.isSpaceOrTab(unit) || unit == ASCII.lineFeed || unit == ASCII.carriageReturn || unit == 0xA0
            || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }
}
