import SwiftUI

/// The calendar event editor: title and type, schedule, linked patient,
/// description. Same field language as `PatientEditorForm` — bezeled inputs
/// with the label directly above, two to a row where they are short — and
/// driven by the `draft` binding so the detail view owns loading and saving.
struct EventEditorForm: View {
    @Binding var draft: CalendarEvent
    /// Patients offered by the link popup, already including the linked one
    /// when it is archived so the popup cannot reset it.
    let patientOptions: [Patient]
    /// Whether the directory still knows a linked patient.
    let isKnownPatient: (UUID) -> Bool
    /// Puts the keyboard in the title as the form appears, for a record the
    /// user just created. The placeholder title comes up selected, so typing
    /// replaces it.
    var focusesTitleOnAppear = false

    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Form {
            Section { titleFields }
            Section {
                scheduleFields
            } header: {
                DetailSectionHeader(title: "Schedule", systemImage: "clock")
            }
            Section {
                LinkedPatientPicker(selection: $draft.patientId,
                                    options: patientOptions,
                                    isKnown: isKnownPatient)
                    .controlSize(.large)
                    .padding(.vertical, Chrome.Space.xs)
            } header: {
                DetailSectionHeader(title: "Patient", systemImage: "person")
            }
            Section {
                EditorTextArea(text: $draft.description)
            } header: {
                DetailSectionHeader(title: "Description", systemImage: "text.alignleft")
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

    // MARK: - Title and type

    private var titleFields: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorTextField("Title", text: $draft.title, focus: $isTitleFocused)
            EditorField("Type") {
                Picker("Type", selection: $draft.eventType) {
                    ForEach(EventType.allCases, id: \.self) { type in
                        Label(DisplayCopy.eventType(type), systemImage: Chrome.eventSymbol(type)).tag(type)
                    }
                }
                .labelsHidden()
                .tint(Chrome.eventTint(draft.eventType))
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Schedule

    private var scheduleFields: some View {
        let components: DatePickerComponents = draft.isAllDay ? .date : [.date, .hourAndMinute]
        return VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorField("Start") {
                    DatePicker("Start", selection: Binding(
                        get: { draft.startDate },
                        set: { newValue in
                            draft.startDate = newValue
                            draft.ensureEndNotBeforeStart()
                        }
                    ), displayedComponents: components)
                    .labelsHidden()
                }
                EditorField("End") {
                    DatePicker("End", selection: Binding(
                        get: { draft.endDate },
                        set: { newValue in
                            draft.endDate = newValue
                            draft.ensureEndNotBeforeStart()
                        }
                    ), displayedComponents: components)
                    .labelsHidden()
                }
            }
            Toggle("All-day", isOn: Binding(
                get: { draft.isAllDay },
                set: { draft.setAllDay($0) }
            ))
            .toggleStyle(.checkbox)
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Chrome.Space.lg) {
            Text("Created \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))")
            Text("Updated \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
