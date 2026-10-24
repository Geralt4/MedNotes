import Foundation

/// Where a note body's Markdown wants styling, for drawing it in the editor
/// while the stored text stays plain Markdown.
///
/// Line-based and deliberately small: ATX headings, bold, italic, wiki-links
/// and a front-matter block at the very start. It answers "what should look
/// different", not "what does this parse to"; `MarkdownPreview` renders.
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
        }

        let range: NSRange
        let role: Role
    }

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var location = 0

        // Front matter: a `---` first line, through the next `---` line.
        if let end = frontMatterEnd(in: ns) {
            spans.append(Span(range: NSRange(location: 0, length: end), role: .frontMatter))
            location = end
        }

        while location < ns.length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let line = NSRange(location: location, length: contentsEnd - location)
            spans += lineSpans(ns, line)
            location = lineEnd
        }
        return spans
    }

    // MARK: - Front matter

    private static func frontMatterEnd(in ns: NSString) -> Int? {
        var firstEnd = 0, firstContents = 0
        ns.getLineStart(nil, end: &firstEnd, contentsEnd: &firstContents,
                        for: NSRange(location: 0, length: 0))
        guard ns.substring(with: NSRange(location: 0, length: firstContents)) == "---",
              firstEnd < ns.length else { return nil }
        var location = firstEnd
        while location < ns.length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            if ns.substring(with: NSRange(location: location, length: contentsEnd - location)) == "---" {
                return lineEnd
            }
            location = lineEnd
        }
        // Never closed: an ordinary rule followed by text, not front matter.
        return nil
    }

    // MARK: - One line

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6}) +\\S")
    private static let bold = try! NSRegularExpression(
        pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    // Single markers, not touching a word character outside (snake_case
    // stays plain) and not part of a double marker.
    private static let italic = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}*_])([*_])(?![*_\\s])(.+?)(?<![*_\\s])\\1(?![\\p{L}\\p{N}*_])")
    private static let wikiLink = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+)\\]\\]")

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

        for match in wikiLink.matches(in: ns as String, range: line) {
            spans.append(Span(range: match.range(at: 1), role: .wikiLink))
            spans += markers(around: match.range, length: 2)
        }
        return spans
    }

    private static func markers(around range: NSRange, length: Int) -> [Span] {
        [Span(range: NSRange(location: range.location, length: length), role: .syntaxMarker),
         Span(range: NSRange(location: NSMaxRange(range) - length, length: length), role: .syntaxMarker)]
    }
}
