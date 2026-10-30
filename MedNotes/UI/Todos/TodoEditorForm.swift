import SwiftUI

/// The todo editor: title and status, due date, linked patient, tags, notes.
///
/// Same field language as `PatientEditorForm` — bezeled inputs with the label
/// directly above, two to a row where they are short — and driven by the
/// `draft` binding so the detail view owns loading and saving. Completion is
/// the one field that saves the instant it changes; the owner supplies that
/// through `onSetCompleted` so the store logic stays with the store access.
struct TodoEditorForm: View {
    @Binding var draft: TodoItem
    /// Patients offered by the link popup, already including the linked one
    /// when it is archived so the popup cannot reset it.
    let patientOptions: [Patient]
    /// Whether the directory still knows a linked patient.
    let isKnownPatient: (UUID) -> Bool
    let onSetCompleted: (Bool) -> Void
    /// Puts the keyboard in the title as the form appears, for a record the
    /// user just created. The placeholder title comes up selected, so typing
    /// replaces it.
    var focusesTitleOnAppear = false
    /// The tag typed and not yet added, held by the detail view so that Done,
    /// leaving the todo and a lock can add it; see `TagEditor`.
    var pendingTag: Binding<String>?

    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Form {
            Section { titleFields }
            Section {
                dueDateControl
            } header: {
                DetailSectionHeader(title: "Due date", systemImage: "calendar")
            }
            Section {
                patientField
            } header: {
                DetailSectionHeader(title: "Patient", systemImage: "person")
            }
            Section {
                tagsField
            } header: {
                DetailSectionHeader(title: "Tags", systemImage: "tag")
            }
            Section {
                EditorTextArea(text: Binding(
                    get: { draft.notes ?? "" },
                    set: { draft.notes = $0.isEmpty ? nil : $0 }
                ))
            } header: {
                DetailSectionHeader(title: "Notes", systemImage: "text.alignleft")
            }
            Section { footer }
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .onAppear {
            guard focusesTitleOnAppear else { return }
            // A focus request made in the same pass that inserts the field is
            // dropped; give the field one turn of the run loop to exist.
            DispatchQueue.main.async { isTitleFocused = true }
        }
    }

    // MARK: - Title and status

    private var titleFields: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorTextField("Title", text: $draft.title, focus: $isTitleFocused)
            EditorFieldRow {
                EditorField("Priority") {
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(TodoPriority.allCases, id: \.self) { priority in
                            Text(DisplayCopy.priority(priority)).tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                EditorField("Status") {
                    Toggle("Completed", isOn: Binding(
                        get: { draft.isCompleted },
                        set: { onSetCompleted($0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Due date

    private var dueDateControl: some View {
        HStack(spacing: Chrome.Space.sm) {
            EditorDateField(date: $draft.dueDate, setTitle: "Set due date", clearTitle: "Remove due date")
            if draft.dueDate != nil {
                if draft.isOverdue {
                    StatusPill("Overdue", tint: .red)
                } else if draft.isDueToday {
                    StatusPill("Due today", tint: .orange)
                }
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Patient

    private var patientField: some View {
        LinkedPatientPicker(
            selection: Binding(
                get: { draft.patientId },
                set: { newId in
                    if let newId,
                       let patient = patientOptions.first(where: { $0.id == newId }) {
                        draft.patientId = newId
                        let name = patient.displayName
                        draft.patientName = (name.isEmpty || name == " ") ? nil : name
                    } else if let newId {
                        draft.patientId = newId
                    } else {
                        draft.patientId = nil
                        draft.patientName = nil
                    }
                }
            ),
            options: patientOptions,
            isKnown: isKnownPatient
        )
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Tags

    private var tagsField: some View {
        TagEditor(tags: $draft.tags, pendingText: pendingTag)
            .padding(.vertical, Chrome.Space.xxs)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Chrome.Space.lg) {
            Text("Created \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))")
            if draft.isCompleted, let completed = draft.completedAt {
                Text("Completed \(completed.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
