import Foundation

/// What has been typed into the "Add…" rows of the medical lists and not yet
/// added.
///
/// The rows used to keep this to themselves, so Done, Save, switching patient
/// and a lock all dropped it silently: an allergen typed and not added left no
/// allergy on the record and no sign that it had been forgotten. The detail view
/// owns the entries instead, and adds them to the draft wherever the editor is
/// left (`commitAll`). The status or severity shown beside each row goes with
/// them, so what is recorded is what was on screen.
struct PendingMedicalEntries: Equatable {
    var conditionName = ""
    var conditionStatus: ConditionStatus = .active
    var allergyName = ""
    var allergySeverity: AllergySeverity = .moderate
    var medicationName = ""
    var medicationDosage = ""
    var medicationFrequency = ""

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No row has a name typed into it. A dosage or frequency without a name
    /// is not an entry: there is nothing to attach it to.
    var isEmpty: Bool {
        Self.clean(conditionName).isEmpty
            && Self.clean(allergyName).isEmpty
            && Self.clean(medicationName).isEmpty
    }

    @discardableResult
    mutating func addCondition(to medical: inout MedicalInfo) -> Bool {
        let name = Self.clean(conditionName)
        guard !name.isEmpty else { return false }
        medical.conditions.append(MedicalCondition(name: name, status: conditionStatus))
        conditionName = ""
        conditionStatus = .active
        return true
    }

    @discardableResult
    mutating func addAllergy(to medical: inout MedicalInfo) -> Bool {
        let name = Self.clean(allergyName)
        guard !name.isEmpty else { return false }
        medical.allergies.append(Allergy(allergen: name, severity: allergySeverity))
        allergyName = ""
        allergySeverity = .moderate
        return true
    }

    @discardableResult
    mutating func addMedication(to medical: inout MedicalInfo) -> Bool {
        let name = Self.clean(medicationName)
        guard !name.isEmpty else { return false }
        medical.medications.append(Medication(
            name: name,
            dosage: Self.clean(medicationDosage),
            frequency: Self.clean(medicationFrequency)))
        medicationName = ""
        medicationDosage = ""
        medicationFrequency = ""
        return true
    }

    /// Adds every row that has a name, and returns how many were added.
    @discardableResult
    mutating func commitAll(into medical: inout MedicalInfo) -> Int {
        var added = 0
        if addCondition(to: &medical) { added += 1 }
        if addAllergy(to: &medical) { added += 1 }
        if addMedication(to: &medical) { added += 1 }
        return added
    }
}
