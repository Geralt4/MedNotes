import SwiftUI

struct TodoRowView: View {
    @EnvironmentObject private var session: AppSession
    let todo: TodoItem

    var body: some View {
        HStack(alignment: .top, spacing: Chrome.Row.leadingSpacing) {
            Button {
                Task { await session.toggleTodo(id: todo.id) }
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(todo.isCompleted ? Color.accentColor : .secondary)
            .accessibilityLabel(todo.isCompleted ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: Chrome.Row.contentSpacing) {
                HStack(spacing: Chrome.Row.inlineSpacing) {
                    Text(DisplayCopy.title(todo.title))
                        .font(.headline)
                        .lineLimit(1)
                        .strikethrough(todo.isCompleted)
                        .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                        // Low priority shows no pill (below), so the priority
                        // it would have announced is spoken here instead.
                        .accessibilityValue(todo.priority == .low ? "Low priority" : "")
                    Spacer(minLength: Chrome.Space.xs)
                    // A pill on every row makes none of them read as urgent.
                    // Low is the resting state — it earns no ink.
                    if todo.priority != .low {
                        StatusPill(
                            text: DisplayCopy.priority(todo.priority),
                            tint: Chrome.priorityColor(todo.priority)
                        )
                    }
                }

                if !sublineParts.isEmpty {
                    Text(sublineParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(dueTint)
                }

                TagChipRow(tags: todo.tags)
            }
        }
        .padding(.vertical, Chrome.Row.verticalPadding)
        .contentShape(Rectangle())
    }

    private var dueTint: Color {
        if todo.isOverdue { return .red }
        if todo.isDueToday { return .orange }
        return .secondary
    }

    private var sublineParts: [String] {
        var parts: [String] = []
        if todo.isOverdue, let due = todo.dueDate {
            parts.append(String(localized: "Overdue \(due.formatted(date: .abbreviated, time: .omitted))"))
        } else if todo.isDueToday {
            parts.append(String(localized: "Today"))
        } else if let due = todo.dueDate {
            parts.append(due.formatted(date: .abbreviated, time: .omitted))
        }
        if let pid = todo.patientId, let name = session.patientName(for: pid) {
            parts.append(name)
        } else if let name = todo.patientName, !name.isEmpty {
            parts.append(name)
        }
        return parts
    }
}
