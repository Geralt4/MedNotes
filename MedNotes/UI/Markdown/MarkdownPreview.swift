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
        case checklist(text: String, checked: Bool)
        case codeLine(String)
        case divider
    }

    static func parseBlocks(_ source: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inFence.toggle()
                flushParagraph()
                continue
            }
            if inFence {
                flushParagraph()
                out.append(.codeLine(line))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" {
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
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                out.append(.bullet(text: String(trimmed.dropFirst(2))))
                continue
            }
            paragraph.append(trimmed)
        }
        flushParagraph()
        return out
    }

    private static func headingLevel(of line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...4).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (hashes.count, rest)
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
