import SwiftUI

/// Minimal Markdown preview for clinical notes. Block structure (headings,
/// lists, checklists, rules, code fences) is parsed by hand; inline emphasis
/// and links ride on Apple's `AttributedString(markdown:)` so no third-party
/// dependency enters the app.
struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if blocks.isEmpty {
                Text("Empty note")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
    }

    // MARK: - Blocks

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(text: String)
        /// `1. text` or `1) text`. `number` is as written; it is shown, not renumbered.
        case numbered(number: String, text: String)
        case checklist(text: String, checked: Bool)
        case codeLine(String)
        case divider
        /// The lines between a leading `---` pair, as written.
        case frontMatter([String])
    }

    static func parseBlocks(_ source: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        /// The open fence's character and length, while one is open.
        var fence: (character: Character, length: Int)?
        var body = source
        // Front matter, as the styler and the list read it (`FrontMatter`): a
        // `---` first line through the next `---` line, when what is between
        // reads as properties. Parsed line by line it became a rule and one
        // run-on paragraph of YAML.
        if let block = FrontMatter.properties(in: source) {
            let ns = source as NSString
            let properties = ns.substring(with: block.innerRange)
                .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !properties.isEmpty { out.append(.frontMatter(properties)) }
            body = ns.substring(from: NSMaxRange(block.range))
        }
        // A character that is a newline splits here, so CRLF is one break and
        // no line keeps a stray carriage return.
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if isFenceCloser(trimmed, of: open) {
                    fence = nil
                    flushParagraph()
                } else {
                    flushParagraph()
                    out.append(.codeLine(line))
                }
                continue
            }
            if let opened = fenceOpener(trimmed) {
                fence = opened
                flushParagraph()
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                out.append(.divider)
                continue
            }
            if let heading = headingLevel(of: trimmed) {
                flushParagraph()
                out.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") {
                flushParagraph()
                out.append(.checklist(text: trailing(trimmed, marker: "[ ]"), checked: false))
                continue
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("* [x] ")
                || trimmed.hasPrefix("- [X] ") || trimmed.hasPrefix("* [X] ") {
                flushParagraph()
                out.append(.checklist(text: trailing(trimmed, marker: "[x]"), checked: true))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                out.append(.bullet(text: String(trimmed.dropFirst(2))))
                continue
            }
            if let item = numberedItem(trimmed) {
                flushParagraph()
                out.append(.numbered(number: item.number, text: item.text))
                continue
            }
            paragraph.append(trimmed)
        }
        flushParagraph()
        return out
    }

    /// A line that opens a code fence: three or more backticks or tildes, then an
    /// info string. For backticks the info string may not contain one, so a line
    /// such as "```ls``` output was normal" is text, not a fence that hides it and
    /// turns everything after it into code.
    static func fenceOpener(_ trimmed: String) -> (character: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
        return (first, run.count)
    }

    /// A line that closes `open`: the same character, at least as many of it,
    /// and nothing else.
    static func isFenceCloser(_ trimmed: String, of open: (character: Character, length: Int)) -> Bool {
        trimmed.count >= open.length && trimmed.allSatisfy { $0 == open.character }
    }

    /// `1. text` or `1) text`: up to nine digits, a `.` or `)`, a space.
    static func numberedItem(_ trimmed: String) -> (number: String, text: String)? {
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return nil }
        let afterMarker = rest.dropFirst()
        guard afterMarker.first == " " else { return nil }
        return (String(digits) + String(marker), afterMarker.trimmingCharacters(in: .whitespaces))
    }

    private static func headingLevel(of line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        // ATX headings need a space after the hashes; "#tag" is content, as
        // in the rest of the app. Without this, a note opening on a tag loses
        // the hash and renders as a heading.
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    /// Case-insensitive: `- [X] done` is valid Markdown, but callers pass the
    /// lowercase marker, and a case-sensitive match would drop the item's text.
    private static func trailing(_ line: String, marker: String) -> String {
        guard let range = line.range(of: marker, options: .caseInsensitive) else { return "" }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private var blocks: [Block] {
        Self.parseBlocks(markdown)
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.weight(.semibold)
                        : level == 2 ? .headline
                        : .subheadline.weight(.semibold))
                .foregroundStyle(level <= 2 ? Color.primary : Color.secondary)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(inline(text))
                .font(.body)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().frame(width: 4, height: 4).foregroundStyle(.secondary)
                Text(inline(text))
                    .font(.body)
            }
            .padding(.leading, 14)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: number)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(inline(text))
                    .font(.body)
            }
            .padding(.leading, 14)
        case .codeLine(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Chrome.editorFill, in: .rect(cornerRadius: Chrome.Radius.chip))
        case .checklist(let text, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                Text(inline(text))
                    .font(.body)
                    .strikethrough(checked)
                    .foregroundStyle(checked ? Color.secondary : Color.primary)
            }
        case .divider:
            Divider().padding(.vertical, 2)
        case .frontMatter(let lines):
            // Kept, but quiet: it is the note's metadata, not its text.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Chrome.editorFill, in: .rect(cornerRadius: Chrome.Radius.chip))
        }
    }

    /// Renders **bold**, *italic*, `code`, and links; unknown syntax shows as
    /// literal text rather than swallowing it.
    private func inline(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(text)
        }
    }
}
