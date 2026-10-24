import SwiftUI

/// A todo as it reads between edits: done or not, what, how urgent, when,
/// for whom, with its tags and notes. The toolbar's Edit switches to
/// `TodoEditorForm`. Completion stays a live control here, as in the list:
/// it is saved the moment it changes. Renders without a session.
struct TodoRecordView: View {
    let todo: TodoItem
    /// The directory's name for the linked patient, else the name the todo
    /// stored when it was linked; `nil` hides the section.
    var patientName: String?
    /// Whether the directory still knows the patient, so it can be opened.
    var canOpenPatient = false
    var onOpenPatient: () -> Void = {}
    var onSetCompleted: (Bool) -> Void = { _ in }

    enum DueTone: Equatable { case overdue, today, plain }

    var body: some View {
        Form {
            Section { header }
                .listRowBackground(Color.clear)
            if let patientName {
                Section {
                    patientRow(patientName)
                } header: {
                    DetailSectionHeader(title: "Patient", systemImage: "person")
                }
            }
            if !todo.tags.isEmpty {
                Section {
                    FlowLayout {
                        ForEach(todo.tags, id: \.self) { TagChip(text: $0, compact: true) }
                    }
                    .padding(.vertical, Chrome.Space.xxs)
                } header: {
                    DetailSectionHeader(title: "Tags", systemImage: "tag")
                }
            }
            if let notes = todo.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                Section {
                    Text(verbatim: notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Chrome.Space.xs)
                } header: {
                    DetailSectionHeader(title: "Notes", systemImage: "text.alignleft")
                }
            }
            Section { footer }
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Chrome.Space.md) {
            Button {
                onSetCompleted(!todo.isCompleted)
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(todo.isCompleted ? Color.accentColor : .secondary)
            .help(todo.isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(todo.isCompleted ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                Text(DisplayCopy.title(todo.title))
                    .font(.title2.weight(.semibold))
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                    .textSelection(.enabled)
                if let priority = priorityLine {
                    Text(verbatim: priority)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(todo.isCompleted ? .secondary : Chrome.priorityColor(todo.priority))
                }
                if let due = Self.dueLine(for: todo) {
                    Text(verbatim: due.text)
                        .font(.callout)
                        .foregroundStyle(Self.color(for: due.tone))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Chrome.Space.xs)
    }

    /// The list's mark with the words, e.g. "!!! High priority"; none for low.
    private var priorityLine: String? {
        switch todo.priority {
        case .high: return "!!! " + String(localized: "High priority")
        case .medium: return "!! " + String(localized: "Medium priority")
        case .low: return nil
        }
    }

    private static func color(for tone: DueTone) -> Color {
        switch tone {
        case .overdue: return .red
        case .today: return .orange
        case .plain: return .secondary
        }
    }

    /// The due date in words. A done todo is never overdue, only "due".
    static func dueLine(for todo: TodoItem, now: Date = Date(),
                        calendar: Calendar = .current) -> (text: String, tone: DueTone)? {
        guard let due = todo.dueDate else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = calendar.timeZone
        let date = due.formatted(style)
        if !todo.isCompleted {
            let today = calendar.startOfDay(for: now)
            if due < today {
                return (String(localized: "Overdue · \(date)"), .overdue)
            }
            if calendar.isDate(due, inSameDayAs: now) {
                return (String(localized: "Due today"), .today)
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
               calendar.isDate(due, inSameDayAs: tomorrow) {
                return (String(localized: "Due tomorrow"), .plain)
            }
        }
        return (String(localized: "Due \(date)"), .plain)
    }

    // MARK: - Patient

    @ViewBuilder
    private func patientRow(_ name: String) -> some View {
        let row = HStack(spacing: Chrome.Row.leadingSpacing) {
            MonogramAvatar(initials: DisplayCopy.initials(ofName: name), size: 28)
            Text(verbatim: name)
                .foregroundStyle(canOpenPatient ? .primary : .secondary)
            Spacer(minLength: 0)
            if canOpenPatient {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        // Todos keep the name they were linked with, so a patient the
        // directory no longer knows still reads here, just not as a link.
        if canOpenPatient {
            Button(action: onOpenPatient) { row }
                .buttonStyle(.plain)
                .help("Open patient")
        } else {
            row
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Chrome.Space.xs) {
            Text("Created \(todo.createdAt.formatted(date: .abbreviated, time: .shortened))")
            if todo.isCompleted, let completed = todo.completedAt {
                Text(verbatim: "·")
                Text("Completed \(completed.formatted(date: .abbreviated, time: .shortened))")
            }
            if todo.reminderIdentifier != nil, todo.syncStatus == .synced {
                Text(verbatim: "·")
                Label("Synced with Apple Reminders", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
