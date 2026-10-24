import SwiftUI

struct PatientRowView: View {
    let patient: Patient

    var body: some View {
        HStack(spacing: Chrome.Row.leadingSpacing) {
            MonogramAvatar(initials: DisplayCopy.initials(
                first: patient.profile.firstName,
                last: patient.profile.lastName
            ))

            VStack(alignment: .leading, spacing: Chrome.Row.contentSpacing) {
                Text(DisplayCopy.patient(patient))
                    .font(.headline)
                    .lineLimit(1)

                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Chrome.Space.xs)

            // Trailing rather than stacked under the name: a patient with
            // active conditions then stands the same height as one without,
            // so the list keeps an even rhythm while scrolling. A dot and a
            // count rather than a worded pill, so the name keeps the width.
            if activeConditions > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                    Text(verbatim: "\(activeConditions)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
                .help("\(activeConditions) active conditions")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(activeConditions) active conditions")
            }
        }
        .padding(.vertical, Chrome.Row.verticalPadding)
        .contentShape(Rectangle())
    }

    private var details: [String] {
        [
            patient.profile.hasKnownDateOfBirth && patient.profile.age >= 0
                ? String(localized: "\(patient.profile.age)y") : nil,
            // The phone is left to the detail view: a third item never fit.
            patient.profile.amka.isEmpty ? nil : patient.profile.amka
        ].compactMap { $0 }
    }

    private var activeConditions: Int {
        patient.medical.conditions.filter { $0.status == .active }.count
    }
}
