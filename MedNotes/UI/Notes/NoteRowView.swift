import SwiftUI

struct NoteRowView: View {
    let note: Note
    /// The matched line while a search is active; nil shows the ordinary preview.
    var snippet: SearchSnippet?

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Row.contentSpacing) {
            HStack(spacing: Chrome.Row.inlineSpacing) {
                Text(DisplayCopy.title(note.title))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: Chrome.Space.xs)
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: note.isPinned)
                        .accessibilityLabel("Pinned")
                }
            }

            if let snippet {
                Text(Self.highlighted(snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                let preview = DisplayCopy.preview(note.content)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: Chrome.Row.inlineSpacing) {
                // The stamp keeps its width; the chips take what is left.
                Text(DisplayCopy.relative(note.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
                TagChipRow(tags: note.tags)
            }
        }
        .padding(.vertical, Chrome.Row.verticalPadding)
        .contentShape(Rectangle())
    }

    /// The snippet with its matched words in the accent colour and semibold.
    static func highlighted(_ snippet: SearchSnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in snippet.highlights {
            guard let swiftRange = Range(range, in: text) else { continue }
            text[swiftRange].foregroundColor = .accentColor
            text[swiftRange].font = .caption.weight(.semibold)
        }
        return text
    }
}
