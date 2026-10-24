import XCTest
@testable import MedNotes

/// What the patient record view shows and what it offers to add.
final class PatientRecordFieldsTests: XCTestCase {
    private let unknownDOB = Date(timeIntervalSince1970: 0)

    private func dob(yearsAgo: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .year, value: -yearsAgo, to: Date())!
    }

    func testFullRecordShowsEverySectionInEditorOrder() {
        let patient = Patient(
            profile: PatientProfile(
                firstName: "Γεώργιος", lastName: "Παπαδόπουλος", fathersName: "Νικόλαος",
                dateOfBirth: dob(yearsAgo: 64), gender: .male, amka: "24106212343",
                afm: "123456789", idNumber: "AK123456", phone: "2101234567",
                email: "g@example.invalid",
                address: Address(street: "Σταδίου 5", city: "Αθήνα", postalCode: "10562",
                                 region: "Αττική", country: "Ελλάδα"),
                emergencyContact: EmergencyContact(name: "Ελένη", phone: "6900000000",
                                                   relationship: "spouse"),
                insurance: InsuranceInfo(provider: "ΕΟΠΥΥ", policyNumber: "P-1")),
            medical: MedicalInfo(bloodType: .aPositive, height: 172, weight: 80))

        let fields = PatientRecordFields(patient)

        XCTAssertEqual(fields.sections.map(\.kind),
                       [.identity, .contact, .emergencyContact, .insurance, .measurements])
        XCTAssertEqual(fields.missingFields, [])
        let identity = fields.sections[0].rows
        XCTAssertEqual(identity.map(\.label), [
            String(localized: "Father's name"), String(localized: "Gender"),
            String(localized: "Date of birth"), String(localized: "AMKA"),
            String(localized: "AFM"), String(localized: "ID number")])
        XCTAssertTrue(identity[2].value.contains(String(localized: "\(64) years old")), identity[2].value)
        let contact = fields.sections[1].rows
        XCTAssertEqual(contact.map(\.label), [
            String(localized: "Phone"), String(localized: "Email"), String(localized: "Address")])
        XCTAssertEqual(contact[1].link, URL(string: "mailto:g@example.invalid"))
        XCTAssertEqual(contact[2].value, "Σταδίου 5, 10562 Αθήνα, Αττική, Ελλάδα")
        XCTAssertEqual(fields.sections[2].rows.first?.value, "Ελένη · spouse")
    }

    func testSparseRecordShowsOnlyWhatIsFilledAndNamesTheRest() {
        let patient = Patient(profile: PatientProfile(
            firstName: "Σοφία", lastName: "Βασιλείου", dateOfBirth: unknownDOB, phone: "6912345678"))

        let fields = PatientRecordFields(patient)

        XCTAssertEqual(fields.sections.map(\.kind), [.contact])
        XCTAssertEqual(fields.sections[0].rows.map(\.label), [String(localized: "Phone")])
        XCTAssertEqual(fields.missingFields, [
            String(localized: "Father's name"), String(localized: "Date of birth"),
            String(localized: "AMKA"), String(localized: "AFM"), String(localized: "ID number"),
            String(localized: "Email"), String(localized: "Address"),
            String(localized: "Emergency contact"), String(localized: "Insurance"),
            String(localized: "Blood type"), String(localized: "Height"), String(localized: "Weight")])
    }

    func testWhitespaceCountsAsEmpty() {
        let patient = Patient(profile: PatientProfile(
            firstName: "A", dateOfBirth: unknownDOB, amka: "   ", afm: " \n"))
        let fields = PatientRecordFields(patient)
        XCTAssertFalse(fields.sections.contains { $0.kind == .identity })
        XCTAssertTrue(fields.missingFields.contains(String(localized: "AMKA")))
    }

    func testAddressJoinsOnlyTheSetParts() {
        XCTAssertEqual(PatientRecordFields.addressLine(Address(city: "Πάτρα")), "Πάτρα")
        XCTAssertEqual(PatientRecordFields.addressLine(Address(street: "Οδός 1", country: "GR")), "Οδός 1, GR")
        XCTAssertEqual(PatientRecordFields.addressLine(Address(city: "Αθήνα", postalCode: "10562")), "10562 Αθήνα")
        XCTAssertEqual(PatientRecordFields.addressLine(Address()), "")
    }

    func testPreferNotToSayGenderIsNeitherShownNorMissing() {
        let fields = PatientRecordFields(Patient(profile: PatientProfile(firstName: "A", dateOfBirth: unknownDOB)))
        let gender = String(localized: "Gender")
        XCTAssertFalse(fields.sections.flatMap(\.rows).contains { $0.label == gender })
        XCTAssertFalse(fields.missingFields.contains(gender))
    }

    func testHeaderFacts() {
        let unnamed = Patient(profile: PatientProfile(dateOfBirth: unknownDOB))
        XCTAssertEqual(PatientRecordFields.headerFacts(unnamed),
                       String(localized: "Enter a name to identify this patient."))

        let nameOnly = Patient(profile: PatientProfile(firstName: "A", dateOfBirth: unknownDOB))
        XCTAssertNil(PatientRecordFields.headerFacts(nameOnly))

        let full = Patient(
            profile: PatientProfile(firstName: "A", dateOfBirth: dob(yearsAgo: 30), gender: .female,
                                    amka: "24109300442"),
            medical: MedicalInfo(bloodType: .oNegative))
        XCTAssertEqual(PatientRecordFields.headerFacts(full), [
            String(localized: "\(30) years old"), DisplayCopy.gender(.female),
            String(localized: "AMKA \("24109300442")"), "O−"].joined(separator: " · "))
    }
}
