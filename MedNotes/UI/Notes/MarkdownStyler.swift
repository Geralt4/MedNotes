import Foundation

/// Where a note body's Markdown wants styling, for drawing it in the editor
/// while the stored text stays plain Markdown.
///
/// Line-based and deliberately small: ATX headings, bold, italic and a
/// front-matter block at the very start, plus wiki-links from
/// `WikiLinkParser`. It answers "what should look different", not "what does
/// this parse to"; `MarkdownPreview` renders.
/// Ranges are UTF-16, the units `NSTextView` and `NSString` count in.
enum MarkdownStyler {
    struct Span: Equatable {
        enum Role: Equatable {
            case heading(level: Int)
            case bold
            case italic
            /// The `#`, `**`, `_`, `[[`, `]]` characters themselves.
            case syntaxMarker
            case frontMatter
            /// The text between `[[` and `]]`.
            case wikiLink
            /// A `#tag`, `#` included.
            case tag
        }

        let range: NSRange
        let role: Role
    }

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var location = 0

        // Front matter: properties between a `---` first line and the next
        // `---` line (`FrontMatter`, the one definition every reader shares).
        if let block = FrontMatter.properties(in: ns) {
            spans.append(Span(range: block.range, role: .frontMatter))
            location = NSMaxRange(block.range)
        }

        // Code and comments that run across lines are not styled as Markdown:
        // a `#` line inside a fence is code, not a heading.
        let linkScan = WikiLinkParser.scan(text)
        let multiLine = mergedRanges(linkScan.protectedRanges)

        while location < ns.length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let line = NSRange(location: location, length: contentsEnd - location)
            if !coveredAcrossLines(multiLine, line) { spans += lineSpans(ns, line) }
            location = lineEnd
        }
        spans += wikiLinkSpans(from: linkScan)
        spans += NoteMetadata.scan(text, links: linkScan).tags.map { Span(range: $0.range, role: .tag) }
        return spans
    }

    /// Whether the line starts inside a range that began on an earlier line or
    /// runs past this one: a fence, a block comment. A code span that opens and
    /// closes within the line does not make it code.
    private static func coveredAcrossLines(_ ranges: [NSRange], _ line: NSRange) -> Bool {
        for range in ranges where range.location <= line.location && line.location < NSMaxRange(range) {
            return range.location < line.location || NSMaxRange(range) > NSMaxRange(line)
        }
        return false
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
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

    /// Wiki-link styling comes from `WikiLinkParser`, the definition the link
    /// index uses, so a link is styled exactly when it is indexed: not inside
    /// code or a comment, and an embed's `!` is part of its opening marker.
    private static func wikiLinkSpans(from scan: WikiLinkParser.Scan) -> [Span] {
        var spans: [Span] = []
        for link in scan.links {
            let openLength = link.isEmbed ? 3 : 2
            let inner = NSRange(
                location: link.range.location + openLength,
                length: link.range.length - openLength - 2)
            spans.append(Span(range: inner, role: .wikiLink))
            spans.append(Span(
                range: NSRange(location: link.range.location, length: openLength), role: .syntaxMarker))
            spans.append(Span(
                range: NSRange(location: NSMaxRange(link.range) - 2, length: 2), role: .syntaxMarker))
        }
        return spans
    }

    // MARK: - One line

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6}) +\\S")
    private static let bold = try! NSRegularExpression(
        pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    // Single markers, not touching a word character outside (snake_case
    // stays plain) and not part of a double marker.
    private static let italic = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}*_])([*_])(?![*_\\s])(.+?)(?<![*_\\s])\\1(?![\\p{L}\\p{N}*_])")

    private static func lineSpans(_ ns: NSString, _ line: NSRange) -> [Span] {
        guard line.length > 0 else { return [] }
        var spans: [Span] = []

        if let match = heading.firstMatch(in: ns as String, range: line) {
            let marker = match.range(at: 1)
            spans.append(Span(range: line, role: .heading(level: marker.length)))
            spans.append(Span(range: marker, role: .syntaxMarker))
        }

        for match in bold.matches(in: ns as String, range: line) {
            spans.append(Span(range: match.range(at: 2), role: .bold))
            spans += markers(around: match.range, length: match.range(at: 1).length)
        }

        // A marker touching another `*` or `_` is refused by the pattern, so
        // the halves of `**bold**` never read as italic too.
        for match in italic.matches(in: ns as String, range: line) {
            spans.append(Span(range: match.range(at: 2), role: .italic))
            spans += markers(around: match.range, length: 1)
        }

        return spans
    }

    private static func markers(around range: NSRange, length: Int) -> [Span] {
        [Span(range: NSRange(location: range.location, length: length), role: .syntaxMarker),
         Span(range: NSRange(location: NSMaxRange(range) - length, length: length), role: .syntaxMarker)]
    }
}
