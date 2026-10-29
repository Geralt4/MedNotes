import Foundation

/// The YAML block at the top of a note: a first line of `---`, a later line of
/// `---`, and properties between them.
///
/// One definition for everything that reads it: the editor's styling, the
/// Markdown preview, the list preview, the metadata scanner and the property
/// editor. Pure and Foundation-only.
///
/// Rules, chosen so that a note is never hidden by mistake:
/// - A leading byte-order mark is ignored.
/// - Both fences are `---` alone on a line, trailing spaces and tabs allowed.
///   `...` is **not** a closer: a note that opens with a rule, has prose, and
///   later has another rule is a note, not front matter.
/// - A closing fence is required. An empty pair is valid.
/// - Lines break at LF, CRLF, CR, U+0085, U+2028 and U+2029, exactly as
///   `NSString.getLineStart` counts them.
/// - Only a block that reads as properties (every non-blank line is a comment,
///   a `key:` line, a list item or an indented continuation) is front matter
///   to its readers. Anything else between two rules is ordinary text.
enum FrontMatter {
    /// Beyond this many UTF-16 units the block is treated as text.
    static let maxLength = 64 * 1024

    struct Block: Equatable, Sendable {
        /// From the opening fence through the closing fence's line break.
        let range: NSRange
        /// Between the opening line's break and the start of the closing line.
        let innerRange: NSRange
        /// The opening fence's line, break included.
        let openLine: NSRange
        /// The closing fence's line, break included (none at the end of text).
        let closeLine: NSRange
        /// The break the opening fence ends with; new lines use the same.
        let lineEnding: String
        /// Whether the lines read as properties.
        let isProperties: Bool
    }

    /// The block between two `---` lines at the top of `text`, whatever it
    /// holds. Most callers want `properties(in:)`.
    static func block(in text: String) -> Block? {
        block(in: text as NSString)
    }

    static func block(in ns: NSString) -> Block? {
        let length = ns.length
        var start = 0
        if length > 0, ns.character(at: 0) == 0xFEFF { start = 1 }
        guard start < length else { return nil }

        var lines = ns.lines(from: start)
        // A lone `---` with nothing after it has no closer.
        guard let open = lines.next(), open.hasBreak,
              isFence(ns, from: open.start, to: open.contentsEnd) else { return nil }
        let ending = ns.substring(with: NSRange(location: open.contentsEnd, length: open.end - open.contentsEnd))

        // `lines` carries on after the opening line; stop at the first closing fence.
        for line in lines {
            guard isFence(ns, from: line.start, to: line.contentsEnd) else { continue }
            let inner = NSRange(location: open.end, length: line.start - open.end)
            return Block(
                range: NSRange(location: start, length: line.end - start),
                innerRange: inner,
                openLine: NSRange(location: start, length: open.end - start),
                closeLine: line.range,
                lineEnding: ending,
                isProperties: inner.length <= maxLength && readsAsProperties(ns, inner))
        }
        return nil
    }

    /// The block, only when it reads as properties.
    static func properties(in text: String) -> Block? {
        properties(in: text as NSString)
    }

    static func properties(in ns: NSString) -> Block? {
        guard let block = block(in: ns), block.isProperties else { return nil }
        return block
    }

    // MARK: - Private

    private static func isFence(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        guard end - start >= 3 else { return false }
        var p = end
        while p > start, ASCII.isSpaceOrTab(ns.character(at: p - 1)) { p -= 1 }
        return p - start == 3
            && ns.character(at: start) == ASCII.dash && ns.character(at: start + 1) == ASCII.dash
            && ns.character(at: start + 2) == ASCII.dash
    }

    /// Whether every line is blank, a comment, a list item, indented, or a
    /// `key:` line. `Patient stable: no complaints` is one too, as in Obsidian.
    private static func readsAsProperties(_ ns: NSString, _ inner: NSRange) -> Bool {
        for line in ns.lines(in: inner) {
            if !isPropertyLine(ns, from: line.start, to: line.contentsEnd) { return false }
        }
        return true
    }

    private static func isPropertyLine(_ ns: NSString, from start: Int, to end: Int) -> Bool {
        var p = start
        while p < end, ASCII.isSpaceOrTab(ns.character(at: p)) { p += 1 }
        if p == end { return true }                       // blank
        if p > start { return true }                      // indented continuation
        let first = ns.character(at: p)
        if first == ASCII.hash { return true }            // # comment
        if first == ASCII.dash {                          // - list item
            return p + 1 == end || ASCII.isSpaceOrTab(ns.character(at: p + 1))
        }
        // key: value  (a colon followed by a space or the end of the line)
        var q = p
        while q < end {
            if ns.character(at: q) == ASCII.colon, q + 1 == end || ASCII.isSpaceOrTab(ns.character(at: q + 1)) {
                return q > p
            }
            q += 1
        }
        return false
    }
}
