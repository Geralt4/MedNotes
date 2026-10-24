import SwiftUI

/// The three medical lists of the patient editor — conditions, allergies,
/// medications — as form sections.
///
/// Each row shows the name, a detail line and a status pill that is itself a
/// menu, so the common change is one click. Disclosing a row exposes every
/// field the model holds for it. The add rows carry the attribute that must
/// not be defaulted silently — an allergy's severity above all — so it is
/// chosen at entry, with the default visible.
struct PatientMedicalSections: View {
    @Binding var medical: MedicalInfo

    @State private var newConditionName = ""
    @State private var newConditionStatus: ConditionStatus = .active
    @State private var newAllergyName = ""
    @State private var newAllergySeverity: AllergySeverity = .moderate
    @State private var newMedicationName = ""
    @State private var newMedicationDosage = ""
    @State private var newMedicationFrequency = ""
    @State private var expandedRows: Set<UUID> = []

    /// `initiallyExpanded` exists for offscreen review renders, which cannot
    /// click a disclosure triangle.
    init(medical: Binding<MedicalInfo>, initiallyExpanded: Set<UUID> = []) {
        self._medical = medical
        self._expandedRows = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        Section {
            conditionRows
        } header: {
            DetailSectionHeader(title: "Conditions", systemImage: "stethoscope")
        }
        Section {
            allergyRows
        } header: {
            DetailSectionHeader(title: "Allergies", systemImage: "exclamationmark.triangle")
        }
        Section {
            medicationRows
        } header: {
            DetailSectionHeader(title: "Medications", systemImage: "pills")
        }
    }

    // MARK: - Conditions

    @ViewBuilder
    private var conditionRows: some View {
        if medical.conditions.isEmpty {
            emptyRow("No conditions recorded.")
        }
        ForEach(medical.conditions) { condition in
            let binding = self.condition(condition.id)
            DisclosureGroup(isExpanded: isExpanded(condition.id)) {
                conditionFields(binding)
            } label: {
                listRow(title: condition.name, detail: condition.notes,
                        removeLabel: "Remove condition",
                        onRemove: { medical.conditions.removeAll { $0.id == condition.id } }) {
                    StatusPillMenu(selection: binding.status, options: ConditionStatus.allCases,
                                   title: DisplayCopy.conditionStatus, tint: Self.conditionTint,
                                   help: "Change status")
                }
            }
        }
        EditorAddRow(prompt: "Add a condition", text: $newConditionName, action: addCondition) {
            Picker("Status", selection: $newConditionStatus) {
                ForEach(ConditionStatus.allCases, id: \.self) { status in
                    Text(DisplayCopy.conditionStatus(status)).tag(status)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func conditionFields(_ condition: Binding<MedicalCondition>) -> some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("Condition", text: condition.name)
                EditorField("Status") {
                    Picker("Status", selection: condition.status) {
                        ForEach(ConditionStatus.allCases, id: \.self) { status in
                            Text(DisplayCopy.conditionStatus(status)).tag(status)
                        }
                    }
                    .labelsHidden()
                }
            }
            EditorFieldRow {
                EditorField("Diagnosed") {
                    EditorDateField(date: condition.diagnosedDate,
                                    setTitle: "Set diagnosis date", clearTitle: "Clear diagnosis date")
                }
                EditorTextField("Notes", text: condition.notes)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.sm)
    }

    private func addCondition() {
        let name = newConditionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        medical.conditions.append(MedicalCondition(name: name, status: newConditionStatus))
        newConditionName = ""
        newConditionStatus = .active
    }

    private static func conditionTint(_ status: ConditionStatus) -> Color {
        status == .active ? .orange : .secondary
    }

    // MARK: - Allergies

    @ViewBuilder
    private var allergyRows: some View {
        if medical.allergies.isEmpty {
            emptyRow("No allergies recorded.")
        }
        ForEach(medical.allergies) { allergy in
            let binding = self.allergy(allergy.id)
            DisclosureGroup(isExpanded: isExpanded(allergy.id)) {
                allergyFields(binding)
            } label: {
                listRow(title: allergy.allergen, detail: allergy.reaction,
                        removeLabel: "Remove allergy",
                        onRemove: { medical.allergies.removeAll { $0.id == allergy.id } }) {
                    StatusPillMenu(selection: binding.severity, options: AllergySeverity.allCases,
                                   title: DisplayCopy.allergySeverity, tint: Self.allergyTint,
                                   help: "Change severity")
                }
            }
        }
        EditorAddRow(prompt: "Add an allergy", text: $newAllergyName, action: addAllergy) {
            Picker("Severity", selection: $newAllergySeverity) {
                ForEach(AllergySeverity.allCases, id: \.self) { severity in
                    Text(DisplayCopy.allergySeverity(severity)).tag(severity)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func allergyFields(_ allergy: Binding<Allergy>) -> some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("Allergen", text: allergy.allergen)
                EditorField("Severity") {
                    Picker("Severity", selection: allergy.severity) {
                        ForEach(AllergySeverity.allCases, id: \.self) { severity in
                            Text(DisplayCopy.allergySeverity(severity)).tag(severity)
                        }
                    }
                    .labelsHidden()
                }
            }
            EditorFieldRow {
                EditorTextField("Reaction", text: allergy.reaction)
                EditorTextField("Notes", text: allergy.notes)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.sm)
    }

    private func addAllergy() {
        let name = newAllergyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        medical.allergies.append(Allergy(allergen: name, severity: newAllergySeverity))
        newAllergyName = ""
        newAllergySeverity = .moderate
    }

    static func allergyTint(_ severity: AllergySeverity) -> Color {
        severity == .severe || severity == .lifeThreatening ? .red : .secondary
    }

    // MARK: - Medications

    private enum MedicationState: Hashable {
        case active, stopped
    }

    @ViewBuilder
    private var medicationRows: some View {
        if medical.medications.isEmpty {
            emptyRow("No medications recorded.")
        }
        ForEach(medical.medications) { medication in
            let binding = self.medication(medication.id)
            DisclosureGroup(isExpanded: isExpanded(medication.id)) {
                medicationFields(binding)
            } label: {
                listRow(title: medication.name,
                        detail: [medication.dosage, medication.frequency]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        removeLabel: "Remove medication",
                        onRemove: { medical.medications.removeAll { $0.id == medication.id } }) {
                    StatusPillMenu(
                        selection: medicationState(binding),
                        options: [MedicationState.active, .stopped],
                        title: { Self.medicationTitle($0, for: medication) },
                        tint: { Self.medicationTint($0, for: medication) },
                        help: "Change status")
                }
            }
        }
        EditorAddRow(prompt: "Add a medication", text: $newMedicationName, action: addMedication) {
            TextField("Dosage", text: $newMedicationDosage, prompt: Text("Dosage"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 100)
            TextField("Frequency", text: $newMedicationFrequency, prompt: Text("Frequency"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 120)
        }
    }

    private func medicationFields(_ medication: Binding<Medication>) -> some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("Medication", text: medication.name)
                EditorTextField("Prescribed by", text: medication.prescribedBy)
            }
            EditorFieldRow {
                EditorTextField("Dosage", text: medication.dosage, prompt: "e.g. 850 mg")
                EditorTextField("Frequency", text: medication.frequency, prompt: "e.g. twice daily")
            }
            EditorFieldRow {
                EditorField("Started") {
                    DatePicker("Started", selection: medication.startDate, displayedComponents: .date)
                        .labelsHidden()
                }
                EditorField("Ended") {
                    EditorDateField(date: medication.endDate,
                                    setTitle: "Set end date", clearTitle: "Clear end date")
                }
            }
            EditorTextField("Notes", text: medication.notes)
            if !medication.wrappedValue.isActive {
                EditorTextField("Reason for stopping", text: Binding(
                    get: { medication.wrappedValue.reasonForStopping ?? "" },
                    set: { medication.wrappedValue.reasonForStopping = $0.isEmpty ? nil : $0 }
                ))
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.sm)
    }

    private func medicationState(_ medication: Binding<Medication>) -> Binding<MedicationState> {
        Binding(
            get: { medication.wrappedValue.isActive ? .active : .stopped },
            set: { state in
                if state == .active {
                    medication.wrappedValue.resume()
                } else {
                    medication.wrappedValue.stop()
                }
            }
        )
    }

    private static func medicationTitle(_ state: MedicationState, for medication: Medication) -> String {
        switch state {
        case .stopped:
            return String(localized: "Stopped")
        case .active:
            return startsInTheFuture(medication) && medication.isActive
                ? String(localized: "Not started")
                : String(localized: "Active")
        }
    }

    private static func medicationTint(_ state: MedicationState, for medication: Medication) -> Color {
        switch state {
        case .stopped: return .secondary
        case .active: return startsInTheFuture(medication) ? .orange : .green
        }
    }

    /// Regimen recorded as ongoing but beginning after today.
    private static func startsInTheFuture(_ medication: Medication) -> Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: medication.startDate) > calendar.startOfDay(for: Date())
    }

    private func addMedication() {
        let name = newMedicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        medical.medications.append(Medication(
            name: name,
            dosage: newMedicationDosage.trimmingCharacters(in: .whitespacesAndNewlines),
            frequency: newMedicationFrequency.trimmingCharacters(in: .whitespacesAndNewlines)))
        newMedicationName = ""
        newMedicationDosage = ""
        newMedicationFrequency = ""
    }

    // MARK: - Row helpers

    /// Binding into the array by id, so an expanded row keeps editing the same
    /// item while its neighbours are added or removed.
    private func condition(_ id: UUID) -> Binding<MedicalCondition> {
        Binding(
            get: { medical.conditions.first { $0.id == id } ?? MedicalCondition(id: id) },
            set: { updated in
                if let index = medical.conditions.firstIndex(where: { $0.id == id }) {
                    medical.conditions[index] = updated
                }
            })
    }

    private func allergy(_ id: UUID) -> Binding<Allergy> {
        Binding(
            get: { medical.allergies.first { $0.id == id } ?? Allergy(id: id) },
            set: { updated in
                if let index = medical.allergies.firstIndex(where: { $0.id == id }) {
                    medical.allergies[index] = updated
                }
            })
    }

    private func medication(_ id: UUID) -> Binding<Medication> {
        Binding(
            get: { medical.medications.first { $0.id == id } ?? Medication(id: id) },
            set: { updated in
                if let index = medical.medications.firstIndex(where: { $0.id == id }) {
                    medical.medications[index] = updated
                }
            })
    }

    private func isExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedRows.contains(id) },
            set: { expanded in
                if expanded {
                    expandedRows.insert(id)
                } else {
                    expandedRows.remove(id)
                }
            })
    }

    /// One recorded item: name, optional detail, the pill menu, remove button.
    private func listRow<Pill: View>(title: String, detail: String, removeLabel: LocalizedStringKey,
                                     onRemove: @escaping () -> Void,
                                     @ViewBuilder pill: () -> Pill) -> some View {
        HStack(spacing: Chrome.Space.sm) {
            Text(verbatim: title.isEmpty ? String(localized: "Unnamed") : title)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Chrome.Space.sm)
            pill()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
        .padding(.vertical, Chrome.Space.xxs)
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.vertical, Chrome.Space.xxs)
    }
}
