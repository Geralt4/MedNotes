import Foundation

/// What the patient record view shows: the profile as labelled values, with
/// empty fields left out and named separately so the view can offer to add
/// them. Pure data, so the choice of what appears is testable without a view.
struct PatientRecordFields: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        /// Set for values that open something (an email address).
        var link: URL? = nil

        var id: String { label }
    }

    struct Section: Equatable, Identifiable {
        enum Kind: Equatable {
            case identity, contact, emergencyContact, insurance, measurements
        }

        let kind: Kind
        let rows: [Row]

        var id: Kind { kind }
    }

    /// Only sections with at least one value, in the editor's order.
    let sections: [Section]
    /// Localised names of the fields still empty, in the editor's order.
    let missingFields: [String]

    init(_ patient: Patient) {
        let profile = patient.profile
        var missing: [String] = []

        /// A row when the value has content, otherwise a name for `missing`.
        func row(_ label: String, _ value: String?, link: URL? = nil) -> Row? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                missing.append(label)
                return nil
            }
            return Row(label: label, value: trimmed, link: link)
        }

        var sections: [Section] = []
        func add(_ kind: Section.Kind, _ rows: [Row?]) {
            let present = rows.compactMap { $0 }
            if !present.isEmpty { sections.append(Section(kind: kind, rows: present)) }
        }

        add(.identity, [
            row(String(localized: "Father's name"), profile.fathersName),
            // "Prefer not to say" is an answer, not a gap: neither shown nor missing.
            profile.gender == .preferNotToSay
                ? nil : Row(label: String(localized: "Gender"), value: DisplayCopy.gender(profile.gender)),
            row(String(localized: "Date of birth"), profile.hasKnownDateOfBirth
                ? Self.dateOfBirth(profile) : nil),
            row(String(localized: "AMKA"), profile.amka),
            row(String(localized: "AFM"), profile.afm),
            row(String(localized: "ID number"), profile.idNumber)
        ])

        let email = profile.email.trimmingCharacters(in: .whitespacesAndNewlines)
        add(.contact, [
            row(String(localized: "Phone"), profile.phone),
            row(String(localized: "Email"), email, link: Self.mailURL(email)),
            // One line: an address section of its own would repeat its title.
            row(String(localized: "Address"), Self.addressLine(profile.address))
        ])

        if let contact = profile.emergencyContact, !contact.isEmpty {
            let name = [contact.name, contact.relationship]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let contactEmail = contact.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var rows: [Row] = []
            if !name.isEmpty { rows.append(Row(label: String(localized: "Name"), value: name)) }
            if !contact.phone.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(Row(label: String(localized: "Phone"), value: contact.phone))
            }
            if !contactEmail.isEmpty {
                rows.append(Row(label: String(localized: "Email"), value: contactEmail,
                                link: Self.mailURL(contactEmail)))
            }
            add(.emergencyContact, rows)
        } else {
            missing.append(String(localized: "Emergency contact"))
        }

        if let policy = profile.insurance, !policy.isEmpty {
            var rows: [Row] = []
            for (label, value) in [(String(localized: "Provider"), policy.provider),
                                   (String(localized: "Policy number"), policy.policyNumber),
                                   (String(localized: "Group number"), policy.groupNumber ?? "")]
            where !value.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(Row(label: label, value: value))
            }
            if let until = policy.validUntil {
                rows.append(Row(label: String(localized: "Valid until"),
                                value: until.formatted(date: .long, time: .omitted)))
            }
            add(.insurance, rows)
        } else {
            missing.append(String(localized: "Insurance"))
        }

        let medical = patient.medical
        add(.measurements, [
            row(String(localized: "Blood type"), medical.bloodType.map { DisplayCopy.bloodType($0) }),
            row(String(localized: "Height"), medical.height.map {
                Measurement(value: $0, unit: UnitLength.centimeters)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided))
            }),
            row(String(localized: "Weight"), medical.weight.map {
                Measurement(value: $0, unit: UnitMass.kilograms)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided))
            })
        ])

        self.sections = sections
        self.missingFields = missing
    }

    /// The line under the patient's name: age, gender, AMKA, blood type.
    /// Shared by the record view and the editor's header.
    static func headerFacts(_ patient: Patient) -> String? {
        let profile = patient.profile
        if profile.fullName.isEmpty {
            return String(localized: "Enter a name to identify this patient.")
        }
        var parts: [String] = []
        if profile.hasKnownDateOfBirth, profile.age >= 0 {
            parts.append(String(localized: "\(profile.age) years old"))
        }
        if profile.gender != .preferNotToSay {
            parts.append(DisplayCopy.gender(profile.gender))
        }
        if !profile.amka.isEmpty {
            parts.append(String(localized: "AMKA \(profile.amka)"))
        }
        if let bloodType = patient.medical.bloodType, bloodType != .unknown {
            parts.append(DisplayCopy.bloodType(bloodType))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func dateOfBirth(_ profile: PatientProfile) -> String {
        let date = profile.dateOfBirth.formatted(date: .long, time: .omitted)
        guard profile.age >= 0 else { return date }
        return "\(date) · \(String(localized: "\(profile.age) years old"))"
    }

    /// "Street, 11527 Athens, Attica, Greece" from whichever parts are set.
    static func addressLine(_ address: Address) -> String {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let town = [clean(address.postalCode), clean(address.city)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [clean(address.street), town, clean(address.region), clean(address.country)]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func mailURL(_ email: String) -> URL? {
        guard email.contains("@"), !email.contains(where: \.isWhitespace) else { return nil }
        return URL(string: "mailto:\(email)")
    }
}
