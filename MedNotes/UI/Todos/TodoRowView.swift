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
                    // Reminders' marks rather than a worded pill: two or three
                    // characters, so the title keeps the row's width.
                    if let mark = priorityMark {
                        Text(verbatim: mark)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(todo.isCompleted
                                ? .secondary : Chrome.priorityColor(todo.priority))
                            .accessibilityHidden(true)
                    }
                    Text(DisplayCopy.title(todo.title))
                        .font(.headline)
                        .lineLimit(1)
                        .strikethrough(todo.isCompleted)
                        .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                        .accessibilityValue(Text(verbatim: priorityValue))
                    Spacer(minLength: 0)
                }

                if dueText != nil || patient != nil {
                    HStack(spacing: 0) {
                        if let dueText {
                            Text(dueText)
                                .foregroundStyle(dueTint)
                        }
                        if dueText != nil, patient != nil {
                            Text(verbatim: " · ")
                                .foregroundStyle(.secondary)
                        }
                        if let patient {
                            patientLabel(patient)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }

                TagChipRow(tags: todo.tags)
            }
        }
        .padding(.vertical, Chrome.Row.verticalPadding)
        .contentShape(Rectangle())
    }

    /// A mark on every row makes none of them read as urgent. Low is the
    /// resting state — it earns no ink.
    private var priorityMark: String? {
        switch todo.priority {
        case .high: return "!!!"
        case .medium: return "!!"
        case .low: return nil
        }
    }

    /// The mark is hidden from VoiceOver, so the title speaks the priority.
    private var priorityValue: String {
        switch todo.priority {
        case .high: return String(localized: "High priority")
        case .medium: return String(localized: "Medium priority")
        case .low: return String(localized: "Low priority")
        }
    }

    private var dueTint: Color {
        if todo.isOverdue { return .red }
        if todo.isDueToday { return .orange }
        return .secondary
    }

    private var dueText: String? {
        if todo.isOverdue, let due = todo.dueDate {
            return String(localized: "Overdue \(due.formatted(date: .abbreviated, time: .omitted))")
        } else if todo.isDueToday {
            return String(localized: "Today")
        } else if let due = todo.dueDate {
            return due.formatted(date: .abbreviated, time: .omitted)
        }
        return nil
    }

    /// The linked patient's current name, or the name stored on the todo
    /// when there is no record to open (an id of nil).
    private var patient: (id: UUID?, name: String)? {
        if let pid = todo.patientId, let name = session.patientName(for: pid) {
            return (pid, name)
        } else if let name = todo.patientName, !name.isEmpty {
            return (nil, name)
        }
        return nil
    }

    @ViewBuilder
    private func patientLabel(_ patient: (id: UUID?, name: String)) -> some View {
        if let id = patient.id {
            // As on the event rows: a click on the name opens the patient,
            // the rest of the row still selects the todo.
            Button {
                Task { await session.jumpToPatient(id) }
            } label: {
                Text(patient.name)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open patient")
        } else {
            Text(patient.name)
                .foregroundStyle(.secondary)
        }
    }
}
