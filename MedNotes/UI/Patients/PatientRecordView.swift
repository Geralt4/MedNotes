import SwiftUI

/// The patient record as it reads between edits: a header with the facts a
/// clinician looks for first, the profile as labelled values with empty
/// fields left out, and the medical lists, which stay editable in place.
///
/// The profile is changed in `PatientEditorForm`; `onEdit` switches to it.
/// Same grouped `Form` as the editor, so switching modes keeps the layout.
/// Renders without an `AppSession`, like the editor (offscreen review).
struct PatientRecordView: View {
    @Binding var patient: Patient
    /// Opens the editor. `nil` for a record that cannot be edited (archived),
    /// which also hides the line offering to fill in missing fields.
    var onEdit: (() -> Void)?
    /// Text in the medical add rows, when the owner wants to add it on leaving.
    var pendingEntries: Binding<PendingMedicalEntries>?

    var body: some View {
        let fields = PatientRecordFields(patient)
        Form {
            Section { header }
                .listRowBackground(Color.clear)
            ForEach(fields.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        LabeledContent(row.label) { value(row) }
                    }
                } header: {
                    Self.header(for: section.kind)
                }
            }
            PatientMedicalSections(medical: $patient.medical, pending: pendingEntries)
            if let onEdit, !fields.missingFields.isEmpty {
                Section {
                    addDetails(fields.missingFields, action: onEdit)
                }
                .listRowBackground(Color.clear)
            }
            Section { footer }
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Chrome.Space.lg) {
            MonogramAvatar(
                initials: DisplayCopy.initials(
                    first: patient.profile.firstName,
                    last: patient.profile.lastName
                ),
                size: 56
            )
            VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                HStack(spacing: Chrome.Space.sm) {
                    Text(DisplayCopy.patient(patient))
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    if patient.isArchived {
                        StatusPill("Archived", tint: .secondary)
                    }
                }
                if let facts = PatientRecordFields.headerFacts(patient) {
                    Text(verbatim: facts)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if hasChips {
                    chips
                        .padding(.top, Chrome.Space.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Chrome.Space.xs)
    }

    private var activeConditions: Int {
        patient.medical.conditions.filter { $0.status == .active }.count
    }

    /// Severe and life-threatening allergies: named up top, not left for the
    /// reader to find in the list below.
    private var seriousAllergies: [Allergy] {
        patient.medical.allergies.filter {
            ($0.severity == .severe || $0.severity == .lifeThreatening)
                && !$0.allergen.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var phone: String {
        patient.profile.phone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChips: Bool {
        !phone.isEmpty || activeConditions > 0 || !seriousAllergies.isEmpty
    }

    private var chips: some View {
        HStack(spacing: Chrome.Row.inlineSpacing) {
            if !phone.isEmpty {
                Label {
                    Text(verbatim: phone).textSelection(.enabled)
                } icon: {
                    Image(systemName: "phone.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, Chrome.Space.xs)
            }
            if activeConditions > 0 {
                StatusPill("\(activeConditions) active conditions", tint: .orange)
            }
            ForEach(seriousAllergies) { allergy in
                StatusPill(
                    text: "\(allergy.allergen) · \(DisplayCopy.allergySeverity(allergy.severity))",
                    tint: PatientMedicalSections.allergyTint(allergy.severity))
                    .help("Allergy")
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func value(_ row: PatientRecordFields.Row) -> some View {
        if let link = row.link {
            Link(row.value, destination: link)
        } else {
            Text(verbatim: row.value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private static func header(for kind: PatientRecordFields.Section.Kind) -> DetailSectionHeader {
        switch kind {
        case .identity:
            DetailSectionHeader(title: "Identity", systemImage: "person.text.rectangle")
        case .contact:
            DetailSectionHeader(title: "Contact", systemImage: "phone")
        case .emergencyContact:
            DetailSectionHeader(title: "Emergency contact", systemImage: "person.crop.circle.badge.exclamationmark")
        case .insurance:
            DetailSectionHeader(title: "Insurance", systemImage: "cross.case")
        case .measurements:
            DetailSectionHeader(title: "Measurements", systemImage: "heart.text.square")
        }
    }

    // MARK: - Missing fields

    /// One quiet line instead of a column of empty boxes: names the first
    /// few gaps and opens the editor.
    private func addDetails(_ missing: [String], action: @escaping () -> Void) -> some View {
        let shown = missing.prefix(3).joined(separator: ", ")
        let list = missing.count > 3 ? "\(shown)…" : shown
        return Button(action: action) {
            Label(String(localized: "Add \(list)"), systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .help("Edit this patient")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Chrome.Space.lg) {
            Text("Created \(patient.createdAt.formatted(date: .abbreviated, time: .shortened))")
            Text("Modified \(patient.lastModified.formatted(date: .abbreviated, time: .shortened))")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
