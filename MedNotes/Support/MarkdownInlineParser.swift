import Foundation

/// The inline half of `MarkdownParser`: emphasis, strikethrough, highlight,
/// code spans, links, images, wiki-links, embeds and tags in one paragraph.
///
/// Code spans, comments, wiki-links and tags are read by the same parsers the
/// index uses (`WikiLinkParser`, `NoteMetadata`), so a link or tag is the same
/// thing here as in the link table. Emphasis follows CommonMark's flanking
/// rules in a single left-to-right pass with a stack per delimiter, so it runs
/// in linear time on any input; the rule-of-three refinement is not applied.
///
/// Pure and Foundation-only.
enum MarkdownInlineParser {
    /// Nesting of links inside links stops here; deeper text stays plain.
    static let maxDepth = 3

    /// - Parameters:
    ///   - text: the paragraph's text, lines joined with `\n`.
    ///   - offsets: for each UTF-16 index of `text` (and one past the end) the
    ///     offset it has in the note, so ranges point into the note.
    static func parse(_ text: String, offsets: [Int], depth: Int = 0) -> [MarkdownInline] {
        var parser = Parser(text: text, offsets: offsets, depth: depth)
        return parser.run()
    }

    /// The readable text of some inlines, markers and links removed.
    static func plainText(_ inlines: [MarkdownInline]) -> String {
        var out = ""
        for inline in inlines {
            switch inline.kind {
            case .text(let s), .code(let s), .tag(let s): out += s
            case .strong(let c, _), .emphasis(let c, _), .strikethrough(let c), .highlight(let c): out += plainText(c)
            case .link(let label, _): out += plainText(label)
            case .wikiLink(let link): out += link.alias ?? (link.heading.map { link.target.isEmpty ? $0 : "\(link.target) > \($0)" } ?? link.target)
            case .embed(let link): out += link.alias ?? link.inner
            case .image(let alt, _): out += alt
            case .softBreak: out += " "
            case .hardBreak: out += "\n"
            }
        }
        return out
    }

    // MARK: - Parser

    private struct Delim {
        var char: UInt16
        var count: Int
        /// Logical index of the first character still in the run.
        var start: Int
        var canOpen: Bool
        var canClose: Bool
    }

    private enum Item {
        case text(String, NSRange)
        case node(MarkdownInline)
        case delim(Delim)
    }

    private struct Atom {
        let range: NSRange
        let inline: MarkdownInline?   // nil: dropped (a comment)
    }

    private struct Parser {
        let units: [UInt16]
        let offsets: [Int]
        let depth: Int
        var items: [Item] = []
        var bufferStart = 0
        /// Item indices of the delimiters that can still open, per character.
        var stacks: [UInt16: [Int]] = [:]
        var atoms: [Atom] = []

        init(text: String, offsets: [Int], depth: Int) {
            self.units = Array(text.utf16)
            self.offsets = offsets
            self.depth = depth
        }

        func source(_ index: Int) -> Int {
            offsets[min(max(index, 0), offsets.count - 1)]
        }

        func sourceRange(_ start: Int, _ end: Int) -> NSRange {
            let a = source(start), b = source(end)
            return NSRange(location: a, length: max(0, b - a))
        }

        mutating func run() -> [MarkdownInline] {
            let n = units.count
            guard n > 0 else { return [] }
            atoms = readAtoms()
            var atomIndex = 0
            var i = 0
            while i < n {
                while atomIndex < atoms.count, atoms[atomIndex].range.location < i { atomIndex += 1 }
                if atomIndex < atoms.count, atoms[atomIndex].range.location == i {
                    let atom = atoms[atomIndex]
                    flushText(upTo: i)
                    if let inline = atom.inline {
                        items.append(.node(MarkdownInline(
                            range: sourceRange(i, NSMaxRange(atom.range)), kind: inline.kind)))
                    }
                    i = NSMaxRange(atom.range)
                    bufferStart = i
                    atomIndex += 1
                    continue
                }
                let c = units[i]
                switch c {
                case 0x5C: // backslash
                    if i + 1 < n, units[i + 1] == 0x0A {
                        flushText(upTo: i)
                        items.append(.node(MarkdownInline(range: sourceRange(i, i + 2), kind: .hardBreak)))
                        i += 2
                        bufferStart = i
                    } else if i + 1 < n, isASCIIPunctuation(units[i + 1]) {
                        // The escaped character is plain text, without its backslash.
                        flushText(upTo: i)
                        appendText(String(decoding: [units[i + 1]], as: UTF16.self), sourceRange(i, i + 2))
                        i += 2
                        bufferStart = i
                    } else {
                        i += 1
                    }
                case 0x0A:
                    var trailing = 0
                    var k = i - 1
                    while k >= bufferStart, k >= 0, units[k] == 0x20 { trailing += 1; k -= 1 }
                    if trailing >= 2 {
                        flushText(upTo: i - trailing)
                        items.append(.node(MarkdownInline(range: sourceRange(i - trailing, i + 1), kind: .hardBreak)))
                    } else {
                        flushText(upTo: i)
                        items.append(.node(MarkdownInline(range: sourceRange(i, i + 1), kind: .softBreak)))
                    }
                    i += 1
                    bufferStart = i
                case 0x2A, 0x5F, 0x7E, 0x3D: // * _ ~ =
                    var run = 0
                    while i + run < n, units[i + run] == c { run += 1 }
                    if (c == 0x7E || c == 0x3D) && run != 2 {
                        i += run
                        continue
                    }
                    flushText(upTo: i)
                    let (canOpen, canClose) = flanking(at: i, run: run, char: c)
                    if canOpen || canClose {
                        handleDelimiter(Delim(char: c, count: run, start: i, canOpen: canOpen, canClose: canClose))
                    } else {
                        items.append(.text(String(decoding: [UInt16](repeating: c, count: run), as: UTF16.self),
                                           sourceRange(i, i + run)))
                    }
                    i += run
                    bufferStart = i
                case 0x5B, 0x21: // [ !
                    if let parsed = linkOrImage(at: i) {
                        flushText(upTo: i)
                        items.append(.node(parsed.node))
                        i = parsed.end
                        bufferStart = i
                    } else {
                        i += 1
                    }
                default:
                    i += 1
                }
            }
            flushText(upTo: n)
            return finish()
        }

        // MARK: Text

        mutating func flushText(upTo end: Int) {
            guard end > bufferStart, bufferStart < units.count else { return }
            let slice = Array(units[bufferStart..<min(end, units.count)])
            guard !slice.isEmpty else { return }
            appendText(String(decoding: slice, as: UTF16.self), sourceRange(bufferStart, min(end, units.count)))
        }

        mutating func appendText(_ string: String, _ range: NSRange) {
            if case .text(let existing, let r)? = items.last {
                items[items.count - 1] = .text(existing + string, NSRange(location: r.location, length: NSMaxRange(range) - r.location))
            } else {
                items.append(.text(string, range))
            }
        }

        // MARK: Delimiters

        func scalar(before index: Int) -> UInt32? {
            guard index > 0 else { return nil }
            var j = index - 1
            if UTF16.isTrailSurrogate(units[j]), j > 0, UTF16.isLeadSurrogate(units[j - 1]) { j -= 1 }
            return String(decoding: units[j..<index], as: UTF16.self).unicodeScalars.first?.value
        }

        func scalar(at index: Int) -> UInt32? {
            guard index < units.count else { return nil }
            let end = (UTF16.isLeadSurrogate(units[index]) && index + 1 < units.count) ? index + 2 : index + 1
            return String(decoding: units[index..<end], as: UTF16.self).unicodeScalars.first?.value
        }

        func isSpace(_ v: UInt32?) -> Bool {
            guard let v, let s = Unicode.Scalar(v) else { return true }   // the edge counts as space
            return s.properties.isWhitespace
        }

        func isPunctuation(_ v: UInt32?) -> Bool {
            guard let v, let s = Unicode.Scalar(v) else { return false }
            switch s.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return true
            default:
                return false
            }
        }

        func flanking(at start: Int, run: Int, char: UInt16) -> (open: Bool, close: Bool) {
            let before = scalar(before: start), after = scalar(at: start + run)
            let left = !isSpace(after) && (!isPunctuation(after) || isSpace(before) || isPunctuation(before))
            let right = !isSpace(before) && (!isPunctuation(before) || isSpace(after) || isPunctuation(after))
            if char == 0x5F {
                return (left && (!right || isPunctuation(before)), right && (!left || isPunctuation(after)))
            }
            return (left, right)
        }

        mutating func handleDelimiter(_ delim: Delim) {
            var closer = delim
            // Close against the nearest opener of the same character, as often as it fits.
            while closer.canClose, closer.count > 0,
                  let openerIndex = stacks[closer.char]?.last,
                  case .delim(var opener) = items[openerIndex] {
                let use: Int
                if closer.char == 0x7E || closer.char == 0x3D {
                    use = 2
                } else {
                    use = (opener.count >= 2 && closer.count >= 2) ? 2 : 1
                }
                guard opener.count >= use, closer.count >= use else { break }
                let inner = Array(items[(openerIndex + 1)...])
                let content = flatten(inner)
                let markerStart = opener.start + opener.count - use
                let range = sourceRange(markerStart, closer.start + use)
                let kind: MarkdownInline.Kind
                switch closer.char {
                case 0x7E: kind = .strikethrough(content)
                case 0x3D: kind = .highlight(content)
                case 0x5F, 0x2A: kind = use == 2 ? .strong(content, markerWidth: use) : .emphasis(content, markerWidth: use)
                default: kind = .emphasis(content, markerWidth: use)
                }
                opener.count -= use
                closer.count -= use
                closer.start += use
                items.removeSubrange((openerIndex + 1)...)
                // Openers inside the span are gone with it.
                for (char, stack) in stacks { stacks[char] = stack.filter { $0 <= openerIndex } }
                if opener.count > 0 {
                    items[openerIndex] = .delim(opener)
                } else {
                    items.removeLast()   // the opener's own item
                    stacks[closer.char]?.removeLast()
                }
                items.append(.node(MarkdownInline(range: range, kind: kind)))
            }
            if closer.count > 0 {
                if closer.canOpen {
                    items.append(.delim(closer))
                    stacks[closer.char, default: []].append(items.count - 1)
                } else {
                    items.append(.text(String(decoding: [UInt16](repeating: closer.char, count: closer.count), as: UTF16.self),
                                       sourceRange(closer.start, closer.start + closer.count)))
                }
            }
        }

        /// Items to inlines: unmatched delimiters become text, neighbouring text merges.
        func flatten(_ list: [Item]) -> [MarkdownInline] {
            var out: [MarkdownInline] = []
            func addText(_ s: String, _ r: NSRange) {
                if let last = out.last, case .text(let existing) = last.kind {
                    out[out.count - 1] = MarkdownInline(
                        range: NSRange(location: last.range.location, length: NSMaxRange(r) - last.range.location),
                        kind: .text(existing + s))
                } else {
                    out.append(MarkdownInline(range: r, kind: .text(s)))
                }
            }
            for item in list {
                switch item {
                case .text(let s, let r): addText(s, r)
                case .node(let inline): out.append(inline)
                case .delim(let d):
                    addText(String(decoding: [UInt16](repeating: d.char, count: d.count), as: UTF16.self),
                            sourceRange(d.start, d.start + d.count))
                }
            }
            return out
        }

        mutating func finish() -> [MarkdownInline] {
            flatten(items)
        }

        // MARK: Atoms: code spans, comments, wiki-links, embeds, tags

        func readAtoms() -> [Atom] {
            let text = String(decoding: units, as: UTF16.self)
            let scan = WikiLinkParser.scan(text)
            var found: [Atom] = []
            for link in scan.links {
                let kind: MarkdownInline.Kind = link.isEmbed ? .embed(link) : .wikiLink(link)
                found.append(Atom(range: link.range, inline: MarkdownInline(range: link.range, kind: kind)))
            }
            for range in scan.protectedRanges {
                guard range.location >= 0, NSMaxRange(range) <= units.count else { continue }
                if units[range.location] == 0x60 {
                    found.append(Atom(range: range, inline: MarkdownInline(range: range, kind: .code(codeContent(range)))))
                } else {
                    found.append(Atom(range: range, inline: nil))   // a comment
                }
            }
            for tag in NoteMetadata.scan(text, links: scan).tags {
                found.append(Atom(range: tag.range, inline: MarkdownInline(range: tag.range, kind: .tag(tag.tag))))
            }
            found.sort { $0.range.location < $1.range.location }
            // Nothing overlaps: the first claim on a stretch wins.
            var kept: [Atom] = []
            var end = 0
            for atom in found where atom.range.location >= end {
                kept.append(atom)
                end = NSMaxRange(atom.range)
            }
            return kept
        }

        /// The text of a code span: between the backtick runs, with one space
        /// off each side when both have one.
        func codeContent(_ range: NSRange) -> String {
            var a = range.location, b = NSMaxRange(range)
            var run = 0
            while a + run < b, units[a + run] == 0x60 { run += 1 }
            a += run
            b -= run
            guard b > a else { return "" }
            var content = Array(units[a..<b])
            if content.count >= 2, content.first == 0x20, content.last == 0x20, content.contains(where: { $0 != 0x20 }) {
                content.removeFirst()
                content.removeLast()
            }
            return String(decoding: content.map { $0 == 0x0A ? 0x20 : $0 }, as: UTF16.self)
        }

        // MARK: Links and images

        func isASCIIPunctuation(_ unit: UInt16) -> Bool {
            (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit)
                || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
        }

        /// The index of the `]` that closes the `[` at `open`, skipping escapes
        /// and atoms.
        func closingBracket(from open: Int) -> Int? {
            var depth = 1
            var i = open + 1
            let limit = min(units.count, open + 1 + 1_000)
            var atomIndex = 0
            while i < limit {
                while atomIndex < atoms.count, NSMaxRange(atoms[atomIndex].range) <= i { atomIndex += 1 }
                if atomIndex < atoms.count, atoms[atomIndex].range.location <= i {
                    i = NSMaxRange(atoms[atomIndex].range)
                    continue
                }
                switch units[i] {
                case 0x5C: i += 2; continue
                case 0x5B: depth += 1
                case 0x5D:
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
                i += 1
            }
            return nil
        }

        func linkOrImage(at start: Int) -> (node: MarkdownInline, end: Int)? {
            let isImage = units[start] == 0x21
            let open = isImage ? start + 1 : start
            guard open < units.count, units[open] == 0x5B else { return nil }
            // `[[` is a wiki-link when it is one; otherwise it is not a Markdown link either.
            if open + 1 < units.count, units[open + 1] == 0x5B { return nil }
            guard depth < MarkdownInlineParser.maxDepth,
                  let close = closingBracket(from: open),
                  close + 1 < units.count, units[close + 1] == 0x28 else { return nil }
            guard let (destination, end) = destination(from: close + 2) else { return nil }
            let labelStart = open + 1
            let labelUnits = Array(units[labelStart..<close])
            let label = MarkdownInlineParser.parse(
                String(decoding: labelUnits, as: UTF16.self),
                offsets: Array(offsets[labelStart...close]), depth: depth + 1)
            let range = sourceRange(start, end)
            if isImage {
                return (MarkdownInline(range: range, kind: .image(
                    alt: MarkdownInlineParser.plainText(label), source: destination)), end)
            }
            return (MarkdownInline(range: range, kind: .link(label: label, destination: destination)), end)
        }

        /// `(dest "title")` after the `(`; returns the destination and the
        /// index just past the `)`.
        func destination(from start: Int) -> (String, Int)? {
            let n = units.count
            let limit = min(n, start + 2_000)
            var i = start
            while i < limit, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
            var dest: [UInt16] = []
            if i < limit, units[i] == 0x3C { // <…>
                i += 1
                while i < limit, units[i] != 0x3E, units[i] != 0x0A { dest.append(units[i]); i += 1 }
                guard i < limit, units[i] == 0x3E else { return nil }
                i += 1
            } else {
                var parens = 0
                while i < limit {
                    let c = units[i]
                    if c == 0x20 || c == 0x09 || c == 0x0A { break }
                    if c == 0x28 { parens += 1 }
                    if c == 0x29 {
                        if parens == 0 { break }
                        parens -= 1
                    }
                    if c == 0x5C, i + 1 < limit { i += 1 }
                    dest.append(units[i])
                    i += 1
                }
            }
            while i < limit, units[i] == 0x20 || units[i] == 0x09 || units[i] == 0x0A { i += 1 }
            if i < limit, units[i] == 0x22 || units[i] == 0x27 { // "title" or 'title'
                let quote = units[i]
                i += 1
                while i < limit, units[i] != quote { i += 1 }
                guard i < limit else { return nil }
                i += 1
                while i < limit, units[i] == 0x20 || units[i] == 0x09 || units[i] == 0x0A { i += 1 }
            }
            guard i < limit, units[i] == 0x29 else { return nil }
            return (String(decoding: dest, as: UTF16.self), i + 1)
        }
    }
}
