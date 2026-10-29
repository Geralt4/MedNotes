import Foundation

/// What has been typed into the "Add…" rows of the medical lists and not yet
/// added.
///
/// The rows used to keep this to themselves, so Done, Save, switching patient
/// and a lock all dropped it silently: an allergen typed and not added left no
/// allergy on the record and no sign that it had been forgotten. The detail view
/// owns the entries instead. Save and Done stop until the text is added or
/// cleared, so the severity is a deliberate click. Leaving the patient or a lock
/// cannot ask, so they add it to the draft (`commitAll`) with the status or
/// severity shown beside the row: dropping an allergy is the worse mistake.
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

    /// The first name typed in an Add row, for saying what has not been added.
    var firstUnadded: String? {
        [conditionName, allergyName, medicationName].map(Self.clean).first { !$0.isEmpty }
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
