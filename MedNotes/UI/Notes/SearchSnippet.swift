import Foundation

/// The line of a note that matched a search, as plain text with the matched
/// words marked, for the notes list. Pure.
///
/// A match is the start of a word: the same prefix reading the full-text
/// search uses, but case, accents (a Greek tonos) and width are folded by the
/// system's own string search, so a snippet is at least as loose as the
/// index. A note that matched through something else (a patient, a tag, a
/// property) has no such line and gets no snippet; the row then shows its
/// ordinary preview.
struct SearchSnippet: Equatable, Sendable {
    let text: String
    /// UTF-16 ranges in `text`.
    let highlights: [NSRange]

    /// Longest text shown, before the ellipses.
    static let window = 140
    /// How far into a note the first match is looked for.
    static let scanLimit = 40_000

    private static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func make(content: String, terms: [String]) -> SearchSnippet? {
        let terms = terms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let ns = content as NSString

        // Front matter is searched only when the body has no match.
        var bodyStart = 0
        var front: NSRange?
        if let block = FrontMatter.properties(in: content) {
            front = block.range
            bodyStart = NSMaxRange(block.range)
        }
        let body = NSRange(location: bodyStart, length: min(max(0, ns.length - bodyStart), scanLimit))
        // A raw hit can be in syntax the plain line drops (a link address, say).
        // Keep looking at later lines until one still shows a match.
        guard let visible = firstVisibleLine(ns, in: body, terms)
                ?? front.flatMap({ firstVisibleLine(ns, in: $0, terms) })
        else { return nil }

        let cleaned = visible.cleaned
        let cleanedNS = cleaned as NSString
        let all = visible.matches
        guard let first = all.first else { return nil }

        guard cleanedNS.length > window else { return SearchSnippet(text: cleaned, highlights: all) }

        // A long line: cut around the first match, on word boundaries.
        var start = max(0, first.location - 40)
        var end = min(cleanedNS.length, start + window)
        if start > 0 {
            let gap = cleanedNS.rangeOfCharacter(
                from: .whitespaces, range: NSRange(location: start, length: max(0, first.location - start)))
            if gap.location != NSNotFound { start = NSMaxRange(gap) }
        }
        if end < cleanedNS.length {
            let gap = cleanedNS.rangeOfCharacter(
                from: .whitespaces, options: .backwards,
                range: NSRange(location: NSMaxRange(first), length: max(0, end - NSMaxRange(first))))
            if gap.location != NSNotFound { end = gap.location }
        }
        // Never split a surrogate pair or a combined character.
        start = cleanedNS.rangeOfComposedCharacterSequence(at: min(start, cleanedNS.length - 1)).location
        if end > start, end < cleanedNS.length {
            end = NSMaxRange(cleanedNS.rangeOfComposedCharacterSequence(at: end - 1))
        }

        let lead = start > 0 ? "… " : ""
        let tail = end < cleanedNS.length ? " …" : ""
        let piece = cleanedNS.substring(with: NSRange(location: start, length: end - start))
        let shift = (lead as NSString).length - start
        let kept = all.compactMap { range -> NSRange? in
            guard range.location >= start, NSMaxRange(range) <= end else { return nil }
            return NSRange(location: range.location + shift, length: range.length)
        }
        return SearchSnippet(text: lead + piece + tail, highlights: kept)
    }

    // MARK: - Matching

    private struct VisibleLine {
        let cleaned: String
        let matches: [NSRange]
    }

    /// The first line in `range` whose plain text still contains a match.
    private static func firstVisibleLine(_ ns: NSString, in range: NSRange, _ terms: [String]) -> VisibleLine? {
        var search = range
        while search.length > 0, let hit = firstHit(ns, in: search, terms) {
            let line = ns.lineRange(for: hit)
            let cleaned = DisplayCopy.plainLine(
                ns.substring(with: line).trimmingCharacters(in: .newlines))
            let cleanedNS = cleaned as NSString
            let all = matches(cleanedNS, in: NSRange(location: 0, length: cleanedNS.length), terms)
            if !all.isEmpty { return VisibleLine(cleaned: cleaned, matches: all) }
            let next = max(NSMaxRange(line), hit.location + 1)
            guard next < NSMaxRange(range) else { break }
            search = NSRange(location: next, length: NSMaxRange(range) - next)
        }
        return nil
    }

    private static func isWordStart(_ ns: NSString, _ location: Int) -> Bool {
        guard location > 0 else { return true }
        let unit = ns.character(at: location - 1)
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    /// The first place in `range` where `term` starts a word.
    private static func firstWordStart(_ ns: NSString, _ term: String, in range: NSRange) -> NSRange? {
        var search = range
        while search.length > 0 {
            let found = ns.range(of: term, options: options, range: search)
            guard found.location != NSNotFound else { return nil }
            if isWordStart(ns, found.location) { return found }
            let next = found.location + 1
            search = NSRange(location: next, length: NSMaxRange(range) - next)
        }
        return nil
    }

    private static func firstHit(_ ns: NSString, in range: NSRange, _ terms: [String]) -> NSRange? {
        terms.compactMap { firstWordStart(ns, $0, in: range) }.min { $0.location < $1.location }
    }

    /// Every word-start match of any term, in order, overlaps merged.
    private static func matches(_ ns: NSString, in range: NSRange, _ terms: [String]) -> [NSRange] {
        var found: [NSRange] = []
        for term in terms {
            var search = range
            while search.length > 0, let hit = firstWordStart(ns, term, in: search) {
                found.append(hit)
                let next = max(NSMaxRange(hit), hit.location + 1)
                search = NSRange(location: next, length: NSMaxRange(range) - next)
            }
        }
        var merged: [NSRange] = []
        for range in found.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(
                    location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
