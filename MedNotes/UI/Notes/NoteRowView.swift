import SwiftUI

struct NoteRowView: View {
    let note: Note

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

            let preview = DisplayCopy.preview(note.content)
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
}
