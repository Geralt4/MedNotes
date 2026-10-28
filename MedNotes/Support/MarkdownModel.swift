import Foundation

/// A note read into blocks and inlines, with the UTF-16 range of everything in
/// the note's own text. The editor's styling, the Reading view and embeds all
/// read the same tree, so a rule such as "what is code" is written once.
///
/// Pure and Foundation-only. Built by `MarkdownParser`.
struct MarkdownDocument: Equatable, Sendable {
    var blocks: [MarkdownBlock]
    /// UTF-16 length of the text that was parsed.
    var length: Int
}

struct MarkdownBlock: Equatable, Sendable, Identifiable {
    /// The whole block in the source, markers included.
    let range: NSRange
    var kind: Kind
    /// The `^id` that ends the block's last line, when it has one.
    var blockID: String?

    /// Unique among siblings (two siblings never start at the same place).
    var id: Int { range.location }

    indirect enum Kind: Equatable, Sendable {
        /// The raw lines between the `---` fences.
        case frontMatter(lines: [String])
        case heading(level: Int, content: [MarkdownInline], marker: NSRange)
        case paragraph([MarkdownInline])
        case list(MarkdownList)
        case quote([MarkdownBlock])
        case callout(MarkdownCallout)
        case code(language: String?, text: String)
        case table(MarkdownTable)
        case rule
        /// `%% … %%` or `<!-- … -->` on lines of its own: not shown.
        case comment
    }
}

struct MarkdownList: Equatable, Sendable {
    var isOrdered: Bool
    /// The number the first item carries (ordered lists).
    var start: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Equatable, Sendable, Identifiable {
    let range: NSRange
    /// `-`, `*`, `+`, `1.` or `1)`, without the space after it.
    let marker: NSRange
    var task: MarkdownTask?
    var blocks: [MarkdownBlock]
    var blockID: String?

    var id: Int { range.location }
}

struct MarkdownTask: Equatable, Sendable {
    /// The three characters `[ ]` / `[x]` in the source.
    let box: NSRange
    var isDone: Bool
}

struct MarkdownCallout: Equatable, Sendable {
    enum Fold: Equatable, Sendable { case none, open, closed }
    /// Lower-cased, as written between `[!` and `]`.
    var type: String
    /// The text after the type; empty when the title is the default.
    var title: [MarkdownInline]
    var fold: Fold
    /// The `> [!type]…` line.
    var headerRange: NSRange
    var children: [MarkdownBlock]
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case none, left, center, right }
    var alignments: [Alignment]
    var header: [[MarkdownInline]]
    var rows: [[[MarkdownInline]]]
}

struct MarkdownInline: Equatable, Sendable {
    /// The whole inline in the source, markers included.
    let range: NSRange
    var kind: Kind

    indirect enum Kind: Equatable, Sendable {
        case text(String)
        /// `markerWidth` characters of `*`/`_` open and close it.
        case strong([MarkdownInline], markerWidth: Int)
        case emphasis([MarkdownInline], markerWidth: Int)
        case strikethrough([MarkdownInline])
        case highlight([MarkdownInline])
        case code(String)
        case link(label: [MarkdownInline], destination: String)
        case wikiLink(ParsedLink)
        case embed(ParsedLink)
        case tag(String)
        case image(alt: String, source: String)
        /// A line break inside a paragraph.
        case softBreak
        case hardBreak
    }
}
