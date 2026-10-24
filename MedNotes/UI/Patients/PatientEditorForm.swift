import SwiftUI

/// The patient record editor: an identity header, cards of labelled inputs
/// for the profile, then the medical lists (`PatientMedicalSections`).
///
/// Every input is a bezeled box with its label directly above it, two to a
/// row where the values are short. Inside a grouped `Form` the automatic
/// text-field style is borderless and pushes the value to the trailing edge
/// of the row, so a freshly created patient — every field empty — used to
/// render as a column of grey labels beside nothing at all. The bezels and
/// prompts here are explicit for that reason.
///
/// Driven entirely by the `draft` binding: the detail view owns loading and
/// saving, and the form renders without an `AppSession` (offscreen review).
struct PatientEditorForm: View {
    @Binding var draft: Patient
    /// Puts the keyboard in "First name" as the form appears. Set for a record
    /// the user just created, which has nothing to identify it yet.
    var focusesNameOnAppear = false
    /// Another patient already carrying a (normalised) AMKA, if any. The
    /// column is unique in the store, so this is the one entry error that
    /// would otherwise surface as a failed save.
    var duplicateAMKA: (String) -> Patient? = { _ in nil }
    /// Medical rows shown disclosed from the start; for review renders only.
    var expandedMedicalRows: Set<UUID> = []

    @FocusState private var isFirstNameFocused: Bool

    var body: some View {
        Form {
            // The clear background takes effect on macOS 13–15; macOS 26 draws
            // the section container regardless, and the card reads fine there.
            Section { header }
                .listRowBackground(Color.clear)
            Section {
                identityFields
            } header: {
                DetailSectionHeader(title: "Identity", systemImage: "person.text.rectangle")
            }
            Section {
                contactFields
            } header: {
                DetailSectionHeader(title: "Contact", systemImage: "phone")
            }
            Section {
                addressFields
            } header: {
                DetailSectionHeader(title: "Address", systemImage: "house")
            }
            Section {
                emergencyContactFields
            } header: {
                DetailSectionHeader(title: "Emergency contact", systemImage: "person.crop.circle.badge.exclamationmark")
            }
            Section {
                insuranceFields
            } header: {
                DetailSectionHeader(title: "Insurance", systemImage: "cross.case")
            }
            Section {
                medicalFields
            } header: {
                DetailSectionHeader(title: "Medical", systemImage: "heart.text.square")
            }
            PatientMedicalSections(medical: $draft.medical, initiallyExpanded: expandedMedicalRows)
            Section { footer }
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .onAppear {
            guard focusesNameOnAppear else { return }
            // A focus request made in the same pass that inserts the field is
            // dropped; give the field one turn of the run loop to exist.
            DispatchQueue.main.async { isFirstNameFocused = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Chrome.Space.lg) {
            MonogramAvatar(
                initials: DisplayCopy.initials(
                    first: draft.profile.firstName,
                    last: draft.profile.lastName
                ),
                size: 56
            )
            VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                HStack(spacing: Chrome.Space.sm) {
                    Text(DisplayCopy.patient(draft.profile.fullName))
                        .font(.title2.weight(.semibold))
                    if draft.isArchived {
                        StatusPill("Archived", tint: .secondary)
                    }
                }
                if let subtitle = headerSubtitle {
                    Text(verbatim: subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Chrome.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var headerSubtitle: String? {
        PatientRecordFields.headerFacts(draft)
    }

    // MARK: - Identity

    private var identityFields: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("First name", text: $draft.profile.firstName,
                                focus: $isFirstNameFocused, contentType: .givenName)
                EditorTextField("Last name", text: $draft.profile.lastName, contentType: .familyName)
            }
            EditorFieldRow {
                EditorTextField("Father's name", text: Binding(
                    get: { draft.profile.fathersName ?? "" },
                    set: {
                        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.profile.fathersName = trimmed.isEmpty ? nil : trimmed
                    }))
                EditorField("Gender") {
                    Picker("Gender", selection: $draft.profile.gender) {
                        ForEach(Gender.allCases, id: \.self) { gender in
                            Text(DisplayCopy.gender(gender)).tag(gender)
                        }
                    }
                    .labelsHidden()
                }
            }
            EditorFieldRow {
                EditorField("Date of birth") { dateOfBirthControl }
                EditorField("AMKA") {
                    VStack(alignment: .leading, spacing: Chrome.Space.xs + 1) {
                        TextField("AMKA", text: $draft.profile.amka, prompt: Text("11 digits"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .autocorrectionDisabled()
                        if let note = amkaNote {
                            Text(verbatim: note)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            EditorFieldRow {
                EditorTextField("AFM", text: optionalText($draft.profile.afm), prompt: "9 digits",
                                autocorrects: false)
                EditorTextField("ID number", text: optionalText($draft.profile.idNumber),
                                autocorrects: false)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    /// Optional strings in the model read as "" and store `nil` when cleared.
    private func optionalText(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// Epoch-0 is the model's "unknown" sentinel; the date field sees `nil`.
    private var dateOfBirthBinding: Binding<Date?> {
        Binding(
            get: { draft.profile.hasKnownDateOfBirth ? draft.profile.dateOfBirth : nil },
            set: { draft.profile.dateOfBirth = $0 ?? Date(timeIntervalSince1970: 0) })
    }

    @ViewBuilder
    private var dateOfBirthControl: some View {
        let encoded = AMKA.birthDate(from: draft.profile.amka)
        VStack(alignment: .leading, spacing: Chrome.Space.xs + 1) {
            EditorDateField(
                date: dateOfBirthBinding,
                setTitle: "Set date of birth", clearTitle: "Clear date of birth",
                defaultDate: { Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date() })
            if let encoded {
                if !draft.profile.hasKnownDateOfBirth {
                    Button {
                        draft.profile.dateOfBirth = encoded
                    } label: {
                        Label(String(localized: "Use \(encoded.formatted(date: .abbreviated, time: .omitted)) from AMKA"),
                              systemImage: "wand.and.stars")
                    }
                } else if !Calendar.current.isDate(encoded, inSameDayAs: draft.profile.dateOfBirth) {
                    HStack(spacing: Chrome.Space.sm) {
                        Text(verbatim: String(localized: "The AMKA encodes \(encoded.formatted(date: .abbreviated, time: .omitted))."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Use it") { draft.profile.dateOfBirth = encoded }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    /// Advisory only: the store takes the value as typed. A duplicate is the
    /// one case that will fail to save, so it is named here before the user
    /// finds out from an alert.
    private var amkaNote: String? {
        let amka = draft.profile.amka
        if let issue = AMKA.issue(for: amka) {
            return DisplayCopy.amkaIssue(issue)
        }
        let normalized = AMKA.normalized(amka)
        guard !normalized.isEmpty, let other = duplicateAMKA(normalized) else { return nil }
        return String(localized: "\(DisplayCopy.patient(other)) already has this AMKA. Saving will fail until it is changed.")
    }

    // MARK: - Contact

    private var contactFields: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("Phone", text: $draft.profile.phone, prompt: "Mobile or landline",
                                autocorrects: false, contentType: .telephoneNumber)
                EditorTextField("Email", text: $draft.profile.email, prompt: "name@example.com",
                                autocorrects: false, contentType: .emailAddress)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Address

    private var addressFields: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorTextField("Street", text: $draft.profile.address.street,
                            prompt: "Street and number", contentType: .streetAddressLine1)
            EditorFieldRow {
                EditorTextField("Postal code", text: $draft.profile.address.postalCode,
                                autocorrects: false, contentType: .postalCode)
                EditorTextField("City", text: $draft.profile.address.city, contentType: .addressCity)
            }
            EditorFieldRow {
                EditorTextField("Region", text: $draft.profile.address.region)
                EditorTextField("Country", text: $draft.profile.address.country, contentType: .countryName)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Emergency contact

    /// Read as a blank contact while absent; stored as `nil` again once every
    /// field is cleared, so an untouched card leaves the record untouched.
    private var emergencyContact: Binding<EmergencyContact> {
        Binding(
            get: { draft.profile.emergencyContact ?? EmergencyContact() },
            set: { draft.profile.emergencyContact = $0.isEmpty ? nil : $0 })
    }

    private var emergencyContactFields: some View {
        let contact = emergencyContact
        return VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("Name", text: contact.name, contentType: .name)
                EditorTextField("Relationship", text: contact.relationship, prompt: "e.g. spouse, daughter")
            }
            EditorFieldRow {
                EditorTextField("Phone", text: contact.phone, prompt: "Mobile or landline",
                                autocorrects: false, contentType: .telephoneNumber)
                EditorTextField("Email", text: optionalText(contact.email), prompt: "name@example.com",
                                autocorrects: false, contentType: .emailAddress)
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Insurance

    private var insurance: Binding<InsuranceInfo> {
        Binding(
            get: { draft.profile.insurance ?? InsuranceInfo() },
            set: { draft.profile.insurance = $0.isEmpty ? nil : $0 })
    }

    private var insuranceFields: some View {
        let policy = insurance
        return VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorTextField("Provider", text: policy.provider)
                EditorTextField("Policy number", text: policy.policyNumber, autocorrects: false)
            }
            EditorFieldRow {
                EditorTextField("Group number", text: optionalText(policy.groupNumber), autocorrects: false)
                EditorField("Valid until") {
                    EditorDateField(date: policy.validUntil,
                                    setTitle: "Set expiry date", clearTitle: "Clear expiry date")
                }
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Medical

    private var medicalFields: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            EditorFieldRow {
                EditorField("Blood type") {
                    Picker("Blood type", selection: $draft.medical.bloodType) {
                        Text(DisplayCopy.bloodType(nil)).tag(BloodType?.none)
                        ForEach(BloodType.allCases, id: \.self) { type in
                            Text(DisplayCopy.bloodType(type)).tag(BloodType?.some(type))
                        }
                    }
                    .labelsHidden()
                }
                EditorField("Height (cm)") {
                    TextField("Height", value: $draft.medical.height, format: .number, prompt: Text("cm"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .autocorrectionDisabled()
                }
                EditorField("Weight (kg)") {
                    TextField("Weight", value: $draft.medical.weight, format: .number, prompt: Text("kg"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .autocorrectionDisabled()
                }
            }
        }
        .controlSize(.large)
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Chrome.Space.lg) {
            Text("Created \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))")
            Text("Modified \(draft.lastModified.formatted(date: .abbreviated, time: .shortened))")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
