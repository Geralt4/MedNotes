import Foundation

/// Reads a note into a `MarkdownDocument`.
///
/// One rule per thing, shared with the index: fenced code is `WikiLinkParser`'s
/// (the same ranges the link table skips), front matter is `FrontMatter`'s, and
/// code spans, comments, wiki-links and tags inside a paragraph come from the
/// same scanners (see `MarkdownInlineParser`). What this parser adds is the
/// block structure: headings, lists, quotes, callouts, tables and paragraphs.
///
/// Not read, on purpose: setext headings (a `---` under text is a rule, as in
/// `NoteMetadata`), HTML blocks, footnotes, link reference definitions, lazy
/// quote continuation. A fence inside a quote or list item is read here as code
/// although the index does not skip it (documented in `WikiLinkParser`).
///
/// Time is linear in the note. Nesting stops at `maxDepth`, and a note longer
/// than `maxLength` comes back as plain paragraphs. Pure and Foundation-only.
enum MarkdownParser {
    static let maxLength = 500_000
    static let maxDepth = 12

    static func parse(_ text: String) -> MarkdownDocument {
        let length = (text as NSString).length
        guard length > 0 else { return MarkdownDocument(blocks: [], length: 0) }
        var builder = Builder(text: text)
        return MarkdownDocument(blocks: builder.run(), length: length)
    }

    // MARK: - Lines

    /// One line of content as a block sees it: a container's prefix (`> `, a
    /// list indent) is already taken off, `start` says where the rest begins in
    /// the note.
    struct Line {
        var start: Int
        var units: [UInt16]
        var end: Int { start + units.count }

        var isBlank: Bool { units.allSatisfy { $0 == 0x20 || $0 == 0x09 } }

        var indent: Int {
            var width = 0
            for unit in units {
                if unit == 0x20 { width += 1 } else if unit == 0x09 { width += 4 - width % 4 } else { break }
            }
            return width
        }

        /// The line with `count` leading units removed.
        func dropping(_ count: Int) -> Line {
            Line(start: start + count, units: Array(units.dropFirst(count)))
        }

        var text: String { String(decoding: units, as: UTF16.self) }
    }

    // MARK: - Builder

    private struct Builder {
        let text: String
        let ns: NSString
        let fences: [NSRange]

        init(text: String) {
            self.text = text
            self.ns = text as NSString
            self.fences = WikiLinkParser.fences(in: text)
        }

        mutating func run() -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            var bodyStart = 0
            if let front = FrontMatter.properties(in: ns) {
                let inner = ns.substring(with: front.innerRange)
                    .components(separatedBy: CharacterSet.newlines)
                blocks.append(MarkdownBlock(
                    range: trimmedLineBreak(front.range), kind: .frontMatter(lines: inner.filter { !$0.isEmpty })))
                bodyStart = NSMaxRange(front.range)
            }
            if ns.length > MarkdownParser.maxLength {
                return blocks + plainParagraphs(from: bodyStart)
            }
            let lines = splitLines(from: bodyStart)
            blocks += parseBlocks(lines[...], depth: 0, topLevel: true)
            return blocks
        }

        func trimmedLineBreak(_ range: NSRange) -> NSRange {
            var length = range.length
            while length > 0, [0x0A, 0x0D].contains(ns.character(at: range.location + length - 1)) { length -= 1 }
            return NSRange(location: range.location, length: length)
        }

        func splitLines(from start: Int) -> [Line] {
            var lines: [Line] = []
            var location = start
            let n = ns.length
            while location < n {
                var lineEnd = 0, contentsEnd = 0
                ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: location, length: 0))
                var units = [UInt16](repeating: 0, count: contentsEnd - location)
                if !units.isEmpty { ns.getCharacters(&units, range: NSRange(location: location, length: contentsEnd - location)) }
                lines.append(Line(start: location, units: units))
                location = lineEnd > location ? lineEnd : n
            }
            return lines
        }

        /// A very long note: paragraphs split at blank lines, no inline reading.
        func plainParagraphs(from start: Int) -> [MarkdownBlock] {
            var out: [MarkdownBlock] = []
            var chunk: [Line] = []
            func flush() {
                guard let first = chunk.first, let last = chunk.last else { return }
                let joined = chunk.map(\.text).joined(separator: " ")
                let range = NSRange(location: first.start, length: last.end - first.start)
                out.append(MarkdownBlock(range: range, kind: .paragraph([
                    MarkdownInline(range: range, kind: .text(joined))])))
                chunk = []
            }
            for line in splitLines(from: start) {
                if line.isBlank { flush() } else { chunk.append(line) }
            }
            flush()
            return out
        }

        // MARK: Blocks

        /// An opener whose closer is not in the lines that follow will not find
        /// one from a later line either, so a note of unclosed openers is read in
        /// linear time.
        final class CommentMemo {
            var noPercentCloser = false
            var noHTMLCloser = false
        }

        func parseBlocks(_ lines: ArraySlice<Line>, depth: Int, topLevel: Bool) -> [MarkdownBlock] {
            let memo = CommentMemo()
            var blocks: [MarkdownBlock] = []
            var i = lines.startIndex
            while i < lines.endIndex {
                let line = lines[i]
                if line.isBlank { i += 1; continue }
                if depth >= MarkdownParser.maxDepth {
                    let (block, next) = paragraph(lines, from: i, depth: depth, interrupt: false, memo: memo)
                    blocks.append(block)
                    i = next
                    continue
                }
                if let (block, next) = fencedCode(lines, from: i, topLevel: topLevel) {
                    blocks.append(block); i = next; continue
                }
                if let (block, next) = commentBlock(lines, from: i, memo: memo) {
                    blocks.append(block); i = next; continue
                }
                if let block = heading(line, depth: depth) {
                    blocks.append(block); i += 1; continue
                }
                if isRule(line) {
                    blocks.append(MarkdownBlock(range: NSRange(location: line.start, length: line.units.count), kind: .rule))
                    i += 1; continue
                }
                if isQuoteLine(line) {
                    let (block, next) = quote(lines, from: i, depth: depth)
                    blocks.append(block); i = next; continue
                }
                if listMarker(line) != nil {
                    let (block, next) = list(lines, from: i, depth: depth)
                    blocks.append(block); i = next; continue
                }
                if let (block, next) = table(lines, from: i, depth: depth) {
                    blocks.append(block); i = next; continue
                }
                let (block, next) = paragraph(lines, from: i, depth: depth, interrupt: true, memo: memo)
                blocks.append(block)
                i = next
            }
            return blocks
        }

        // MARK: Fenced code

        /// A fence run at the start of a line: `(char, length, info start)`.
        func fenceOpener(_ line: Line) -> (char: UInt16, length: Int, after: Int)? {
            guard line.indent <= 3 else { return nil }
            var p = 0
            while p < line.units.count, line.units[p] == 0x20 { p += 1 }
            guard p < line.units.count, line.units[p] == 0x60 || line.units[p] == 0x7E else { return nil }
            let char = line.units[p]
            var q = p
            while q < line.units.count, line.units[q] == char { q += 1 }
            guard q - p >= 3 else { return nil }
            // A backtick fence's info string has no backtick: that is an inline span.
            if char == 0x60, line.units[q...].contains(0x60) { return nil }
            return (char, q - p, q)
        }

        func fencedCode(_ lines: ArraySlice<Line>, from i: Int, topLevel: Bool) -> (MarkdownBlock, Int)? {
            let line = lines[i]
            guard let opener = fenceOpener(line) else { return nil }
            var close = lines.endIndex          // index of the closing line, when there is one
            var j = i + 1
            while j < lines.endIndex {
                let candidate = lines[j]
                if candidate.indent <= 3 {
                    let trimmed = candidate.units.drop(while: { $0 == 0x20 })
                    let run = trimmed.prefix(while: { $0 == opener.char }).count
                    if run >= opener.length, trimmed.dropFirst(run).allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                        close = j
                        break
                    }
                }
                j += 1
            }
            if topLevel {
                // The index's own fence list decides what is code at the top level.
                guard fences.contains(where: { $0.location == line.start }) else { return nil }
            }
            let bodyEnd = close
            let body = lines[(i + 1)..<bodyEnd].map(\.text).joined(separator: "\n")
            let info = String(decoding: line.units[opener.after...], as: UTF16.self)
                .trimmingCharacters(in: .whitespaces)
            let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            let last = close < lines.endIndex ? lines[close] : lines[bodyEnd - 1 >= i ? bodyEnd - 1 : i]
            let range = NSRange(location: line.start, length: last.end - line.start)
            let next = close < lines.endIndex ? close + 1 : lines.endIndex
            return (MarkdownBlock(range: range, kind: .code(language: language, text: body)), next)
        }

        // MARK: Comments

        func commentBlock(_ lines: ArraySlice<Line>, from i: Int, memo: CommentMemo) -> (MarkdownBlock, Int)? {
            let line = lines[i]
            let trimmed = line.units.drop(while: { $0 == 0x20 || $0 == 0x09 })
            let (open, close): ([UInt16], [UInt16])
            let isPercent: Bool
            if trimmed.starts(with: [0x25, 0x25]) { (open, close) = ([0x25, 0x25], [0x25, 0x25]); isPercent = true }
            else if trimmed.starts(with: Array("<!--".utf16)) { (open, close) = (Array("<!--".utf16), Array("-->".utf16)); isPercent = false }
            else { return nil }
            if isPercent ? memo.noPercentCloser : memo.noHTMLCloser { return nil }
            var j = i
            var searchFrom = line.units.count - trimmed.count + open.count
            while j < lines.endIndex {
                let units = lines[j].units
                if let hit = find(close, in: units, from: j == i ? searchFrom : 0) {
                    let rest = units[(hit + close.count)...]
                    guard rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
                    let range = NSRange(location: line.start, length: lines[j].end - line.start)
                    return (MarkdownBlock(range: range, kind: .comment), j + 1)
                }
                searchFrom = 0
                j += 1
            }
            if isPercent { memo.noPercentCloser = true } else { memo.noHTMLCloser = true }
            return nil
        }

        func find(_ needle: [UInt16], in units: [UInt16], from: Int) -> Int? {
            guard needle.count > 0, units.count >= needle.count, from >= 0 else { return nil }
            var p = from
            while p + needle.count <= units.count {
                if units[p] == needle[0], Array(units[p..<(p + needle.count)]) == needle { return p }
                p += 1
            }
            return nil
        }

        // MARK: Headings and rules

        func heading(_ line: Line, depth: Int) -> MarkdownBlock? {
            var p = 0
            while p < line.units.count, line.units[p] == 0x20, p < 4 { p += 1 }
            guard p <= 3 else { return nil }
            var hashes = 0
            while p < line.units.count, line.units[p] == 0x23 { hashes += 1; p += 1 }
            guard (1...6).contains(hashes), p < line.units.count, line.units[p] == 0x20 || line.units[p] == 0x09 else { return nil }
            let markerEnd = p + 1
            // Text runs to the end, minus an optional closing run of `#` set off by a space.
            var end = line.units.count
            while end > markerEnd, line.units[end - 1] == 0x20 || line.units[end - 1] == 0x09 { end -= 1 }
            var q = end
            while q > markerEnd, line.units[q - 1] == 0x23 { q -= 1 }
            if q < end, q == markerEnd || line.units[q - 1] == 0x20 || line.units[q - 1] == 0x09 {
                end = q
                while end > markerEnd, line.units[end - 1] == 0x20 || line.units[end - 1] == 0x09 { end -= 1 }
            }
            var start = markerEnd
            while start < end, line.units[start] == 0x20 || line.units[start] == 0x09 { start += 1 }
            guard end > start else { return nil }   // an empty heading is not one (as in NoteMetadata)
            // A `^id` ends the heading's text, as for any line.
            var blockID: String?
            var contentUnits = Array(line.units[start..<end])
            if let (trimmed, id) = NoteMetadata.splitTrailingBlockID(contentUnits), !trimmed.isEmpty {
                contentUnits = trimmed
                blockID = id
            }
            let content = inlines(units: contentUnits, sources: (start..<(start + contentUnits.count)).map { line.start + $0 },
                                  end: line.start + start + contentUnits.count, depth: depth)
            return MarkdownBlock(
                range: NSRange(location: line.start, length: line.units.count),
                kind: .heading(level: hashes, content: content,
                               marker: NSRange(location: line.start, length: markerEnd)),
                blockID: blockID)
        }

        func isRule(_ line: Line) -> Bool {
            guard line.indent <= 3 else { return false }
            let marks = line.units.filter { $0 != 0x20 && $0 != 0x09 }
            guard marks.count >= 3, let first = marks.first, [0x2D, 0x2A, 0x5F].contains(first) else { return false }
            return marks.allSatisfy { $0 == first }
        }

        // MARK: Quotes and callouts

        func isQuoteLine(_ line: Line) -> Bool {
            guard line.indent <= 3 else { return false }
            return line.units.first(where: { $0 != 0x20 }) == 0x3E
        }

        /// A quote line without its `>` and the one space after it.
        func unquoted(_ line: Line) -> Line {
            var p = 0
            while p < line.units.count, line.units[p] == 0x20 { p += 1 }
            p += 1   // the >
            if p < line.units.count, line.units[p] == 0x20 { p += 1 }
            return line.dropping(min(p, line.units.count))
        }

        func quote(_ lines: ArraySlice<Line>, from i: Int, depth: Int) -> (MarkdownBlock, Int) {
            var j = i
            var inner: [Line] = []
            while j < lines.endIndex, isQuoteLine(lines[j]) {
                inner.append(unquoted(lines[j]))
                j += 1
            }
            let range = NSRange(location: lines[i].start, length: lines[j - 1].end - lines[i].start)
            if let first = inner.first, let header = calloutHeader(first, headerLine: lines[i], depth: depth) {
                var callout = header
                callout.children = parseBlocks(inner.dropFirst(), depth: depth + 1, topLevel: false)
                return (MarkdownBlock(range: range, kind: .callout(callout)), j)
            }
            return (MarkdownBlock(range: range, kind: .quote(parseBlocks(inner[...], depth: depth + 1, topLevel: false))), j)
        }

        /// `[!type]`, `[!type]+`, `[!type]-`, then an optional title.
        func calloutHeader(_ line: Line, headerLine: Line, depth: Int) -> MarkdownCallout? {
            let u = line.units
            guard u.count >= 4, u[0] == 0x5B, u[1] == 0x21 else { return nil }
            var p = 2
            while p < u.count, isTypeChar(u[p]) { p += 1 }
            guard p > 2, p < u.count, u[p] == 0x5D else { return nil }
            let type = String(decoding: u[2..<p], as: UTF16.self).lowercased()
            p += 1
            var fold = MarkdownCallout.Fold.none
            if p < u.count, u[p] == 0x2B { fold = .open; p += 1 } else if p < u.count, u[p] == 0x2D { fold = .closed; p += 1 }
            guard p == u.count || u[p] == 0x20 || u[p] == 0x09 else { return nil }
            while p < u.count, u[p] == 0x20 || u[p] == 0x09 { p += 1 }
            var end = u.count
            while end > p, u[end - 1] == 0x20 || u[end - 1] == 0x09 { end -= 1 }
            let title = end > p
                ? inlines(units: Array(u[p..<end]), sources: (p..<end).map { line.start + $0 }, end: line.start + end, depth: depth)
                : []
            return MarkdownCallout(
                type: type, title: title, fold: fold,
                headerRange: NSRange(location: headerLine.start, length: line.end - headerLine.start), children: [])
        }

        func isTypeChar(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
                || unit == 0x2D || unit == 0x5F
        }

        // MARK: Lists

        struct Marker {
            var indent: Int
            var markerLength: Int      // units of `-` or `1.`
            var contentOffset: Int     // units from the line start to the item's text
            var isOrdered: Bool
            var number: Int
            var char: UInt16           // the bullet, or the `.`/`)` of an ordered marker
        }

        func listMarker(_ line: Line) -> Marker? {
            guard line.indent <= 3 else { return nil }
            var p = 0
            while p < line.units.count, line.units[p] == 0x20 { p += 1 }
            guard p < line.units.count else { return nil }
            let indent = p
            var number = 0, ordered = false, char: UInt16 = line.units[p]
            var markerEnd = p
            if [0x2D, 0x2A, 0x2B].contains(char) {
                markerEnd = p + 1
            } else if (0x30...0x39).contains(char) {
                var q = p
                while q < line.units.count, (0x30...0x39).contains(line.units[q]), q - p < 9 {
                    number = number * 10 + Int(line.units[q] - 0x30)
                    q += 1
                }
                guard q < line.units.count, line.units[q] == 0x2E || line.units[q] == 0x29 else { return nil }
                ordered = true
                char = line.units[q]
                markerEnd = q + 1
            } else {
                return nil
            }
            // A marker needs a space (or the end of the line) after it.
            guard markerEnd == line.units.count || line.units[markerEnd] == 0x20 || line.units[markerEnd] == 0x09 else { return nil }
            if char == 0x2D || char == 0x2A, isRule(line) { return nil }
            var spaces = 0
            while markerEnd + spaces < line.units.count, line.units[markerEnd + spaces] == 0x20 { spaces += 1 }
            // Five or more spaces: the text is indented code, the marker keeps one.
            let used = (spaces == 0 || spaces > 4) ? 1 : spaces
            let contentOffset = markerEnd + used
            return Marker(indent: indent, markerLength: markerEnd - p, contentOffset: contentOffset,
                          isOrdered: ordered, number: number, char: char)
        }

        func list(_ lines: ArraySlice<Line>, from i: Int, depth: Int) -> (MarkdownBlock, Int) {
            guard let first = listMarker(lines[i]) else {
                let (block, next) = paragraph(lines, from: i, depth: depth, interrupt: false)
                return (block, next)
            }
            var items: [MarkdownListItem] = []
            var j = i
            var marker = first
            while j < lines.endIndex {
                let startLine = lines[j]
                let contentIndent = marker.contentOffset   // continuation lines must reach this column
                var itemLines: [Line] = [startLine.dropping(min(marker.contentOffset, startLine.units.count))]
                var k = j + 1
                var blanks = 0
                while k < lines.endIndex {
                    let candidate = lines[k]
                    if candidate.isBlank {
                        blanks += 1
                        k += 1
                        continue
                    }
                    if candidate.indent >= contentIndent {
                        for _ in 0..<blanks { itemLines.append(Line(start: candidate.start, units: [])) }
                        blanks = 0
                        itemLines.append(dropIndent(candidate, upTo: contentIndent))
                        k += 1
                        continue
                    }
                    // Lazy continuation: text that continues the item's last paragraph.
                    if blanks == 0, listMarker(candidate) == nil, !startsBlock(candidate), itemLines.last?.isBlank == false {
                        itemLines.append(candidate.dropping(candidate.units.prefix(while: { $0 == 0x20 || $0 == 0x09 }).count))
                        k += 1
                        continue
                    }
                    break
                }
                // Trailing blank lines belong to nobody.
                let endIndex = k - blanks
                var content = itemLines
                // A task box: `[ ]` or `[x]` followed by a space or the end of the line.
                var task: MarkdownTask?
                if var head = content.first, head.units.count >= 3, head.units[0] == 0x5B, head.units[2] == 0x5D,
                   [0x20, 0x78, 0x58].contains(head.units[1]),
                   head.units.count == 3 || head.units[3] == 0x20 || head.units[3] == 0x09 {
                    task = MarkdownTask(box: NSRange(location: head.start, length: 3), isDone: head.units[1] != 0x20)
                    let skip = head.units.count == 3 ? 3 : 4
                    head = head.dropping(skip)
                    content[0] = head
                }
                let blocks = parseBlocks(content[...], depth: depth + 1, topLevel: false)
                let last = lines[max(j, endIndex - 1)]
                let range = NSRange(location: startLine.start + 0, length: last.end - startLine.start)
                var item = MarkdownListItem(
                    range: range,
                    marker: NSRange(location: startLine.start + marker.indent, length: marker.markerLength),
                    task: task, blocks: blocks, blockID: nil)
                // A `^id` ending the item's own text names the whole item, children included.
                if let firstBlock = blocks.first, case .paragraph = firstBlock.kind, let id = firstBlock.blockID {
                    item.blockID = id
                }
                items.append(item)
                j = endIndex
                // The next item: a marker of the same kind, after any blank lines
                // (a loose list is still one list).
                var m = j
                while m < lines.endIndex, lines[m].isBlank { m += 1 }
                guard m < lines.endIndex, let next = listMarker(lines[m]),
                      next.isOrdered == first.isOrdered, next.char == first.char,
                      next.indent < marker.indent + first.contentOffset - first.indent || next.indent <= first.indent + 3
                else { break }
                j = m
                marker = next
            }
            let range = NSRange(location: lines[i].start, length: (items.last.map { NSMaxRange($0.range) } ?? lines[i].end) - lines[i].start)
            return (MarkdownBlock(range: range, kind: .list(MarkdownList(
                isOrdered: first.isOrdered, start: first.number, items: items))), j)
        }

        func dropIndent(_ line: Line, upTo width: Int) -> Line {
            var removed = 0, columns = 0
            for unit in line.units {
                if columns >= width { break }
                if unit == 0x20 { columns += 1 } else if unit == 0x09 { columns += 4 - columns % 4 } else { break }
                removed += 1
            }
            return line.dropping(removed)
        }

        /// Whether a line begins something that ends a paragraph before it.
        func startsBlock(_ line: Line) -> Bool {
            if line.isBlank { return true }
            if fenceOpener(line) != nil || heading(line, depth: MarkdownParser.maxDepth) != nil || isRule(line) || isQuoteLine(line) { return true }
            if let m = listMarker(line), !m.isOrdered || m.number == 1 {
                // An empty marker line does not interrupt a paragraph.
                return m.contentOffset < line.units.count
            }
            return false
        }

        // MARK: Tables

        func table(_ lines: ArraySlice<Line>, from i: Int, depth: Int) -> (MarkdownBlock, Int)? {
            guard i + 1 < lines.endIndex, lines[i].units.contains(0x7C),
                  let alignments = delimiterRow(lines[i + 1]) else { return nil }
            let header = cells(lines[i], depth: depth)
            // The delimiter row must give one column per header cell; `a | b`
            // over `---` is a paragraph and a rule, and padding would drop `b`.
            guard !header.isEmpty, header.count == alignments.count else { return nil }
            var rows: [[[MarkdownInline]]] = []
            var j = i + 2
            while j < lines.endIndex, !lines[j].isBlank, lines[j].units.contains(0x7C), !startsBlock(lines[j]) || listMarker(lines[j]) != nil {
                rows.append(pad(cells(lines[j], depth: depth), to: alignments.count))
                j += 1
            }
            let range = NSRange(location: lines[i].start, length: lines[j - 1].end - lines[i].start)
            return (MarkdownBlock(range: range, kind: .table(MarkdownTable(
                alignments: alignments, header: pad(header, to: alignments.count), rows: rows))), j)
        }

        func pad(_ row: [[MarkdownInline]], to count: Int) -> [[MarkdownInline]] {
            var out = Array(row.prefix(count))
            while out.count < count { out.append([]) }
            return out
        }

        func delimiterRow(_ line: Line) -> [MarkdownTable.Alignment]? {
            var out: [MarkdownTable.Alignment] = []
            for range in cellRanges(line) {
                let cell = Array(line.units[range]).filter { $0 != 0x20 && $0 != 0x09 }
                guard !cell.isEmpty else { return nil }
                let left = cell.first == 0x3A, right = cell.last == 0x3A
                let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
                guard !dashes.isEmpty, dashes.allSatisfy({ $0 == 0x2D }) else { return nil }
                out.append(left && right ? .center : left ? .left : right ? .right : .none)
            }
            return out.isEmpty ? nil : out
        }

        /// Unit ranges of the cells of a row: split at `|` outside code spans and
        /// not escaped; one leading and one trailing `|` are borders.
        func cellRanges(_ line: Line) -> [Range<Int>] {
            let u = line.units
            var cuts: [Int] = []
            var i = 0
            var inCode = 0
            while i < u.count {
                let c = u[i]
                if c == 0x5C { i += 2; continue }
                if c == 0x60 {
                    var run = 0
                    while i + run < u.count, u[i + run] == 0x60 { run += 1 }
                    inCode = inCode == 0 ? run : (inCode == run ? 0 : inCode)
                    i += run
                    continue
                }
                if c == 0x7C, inCode == 0 { cuts.append(i) }
                i += 1
            }
            var bounds: [Int] = [-1] + cuts + [u.count]
            // Borders: a pipe before the first non-space, one after the last.
            let firstNonSpace = u.firstIndex(where: { $0 != 0x20 && $0 != 0x09 }) ?? u.count
            if let first = cuts.first, first == firstNonSpace { bounds.removeFirst() ; bounds[0] = first }
            if let last = cuts.last, !u.isEmpty,
               u.lastIndex(where: { $0 != 0x20 && $0 != 0x09 }) == last, bounds.count > 1 { bounds.removeLast() }
            var ranges: [Range<Int>] = []
            for k in 0..<(bounds.count - 1) {
                let a = bounds[k] + 1, b = bounds[k + 1]
                if a <= b { ranges.append(a..<b) }
            }
            return ranges
        }

        func cells(_ line: Line, depth: Int) -> [[MarkdownInline]] {
            cellRanges(line).map { range in
                var a = range.lowerBound, b = range.upperBound
                while a < b, line.units[a] == 0x20 || line.units[a] == 0x09 { a += 1 }
                while b > a, line.units[b - 1] == 0x20 || line.units[b - 1] == 0x09 { b -= 1 }
                guard b > a else { return [] }
                return inlines(units: Array(line.units[a..<b]), sources: (a..<b).map { line.start + $0 },
                               end: line.start + b, depth: depth)
            }
        }

        // MARK: Paragraphs

        func paragraph(_ lines: ArraySlice<Line>, from i: Int, depth: Int, interrupt: Bool,
                       memo: CommentMemo = CommentMemo()) -> (MarkdownBlock, Int) {
            var chunk: [Line] = [lines[i]]
            var j = i + 1
            while j < lines.endIndex, !lines[j].isBlank {
                if interrupt {
                    if startsBlock(lines[j]) { break }
                    if commentBlock(lines, from: j, memo: memo) != nil { break }
                    if table(lines, from: j, depth: depth) != nil { break }
                }
                chunk.append(lines[j])
                j += 1
            }
            // A `^id` ends the last line.
            var blockID: String?
            if var last = chunk.last, let (trimmed, id) = NoteMetadata.splitTrailingBlockID(last.units) {
                last.units = trimmed
                chunk[chunk.count - 1] = last
                blockID = id
            }
            var units: [UInt16] = []
            var sources: [Int] = []
            for (n, raw) in chunk.enumerated() {
                var line = raw
                if n > 0 {
                    let lead = line.units.prefix(while: { $0 == 0x20 || $0 == 0x09 }).count
                    line = line.dropping(lead)
                    units.append(0x0A)
                    sources.append(chunk[n - 1].end)
                }
                for (k, unit) in line.units.enumerated() { units.append(unit); sources.append(line.start + k) }
            }
            // Trailing spaces on the last line carry no break.
            while let last = units.last, last == 0x20 || last == 0x09 { units.removeLast(); sources.removeLast() }
            let endSource = (chunk.last.map { $0.start + $0.units.count }) ?? lines[i].end
            let content = inlines(units: units, sources: sources, end: endSource, depth: depth)
            let first = chunk[0]
            let lastLine = lines[j - 1]
            let range = NSRange(location: first.start, length: lastLine.end - first.start)
            return (MarkdownBlock(range: range, kind: .paragraph(content), blockID: blockID), j)
        }

        // MARK: Inline reading

        func inlines(units: [UInt16], sources: [Int], end: Int, depth: Int) -> [MarkdownInline] {
            MarkdownInlineParser.parse(String(decoding: units, as: UTF16.self), offsets: sources + [end])
        }
    }
}
