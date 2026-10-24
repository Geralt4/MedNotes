import SwiftUI

/// An event as it reads between edits: what it is, when, with whom, and its
/// notes. The toolbar's Edit switches to `EventEditorForm`. Same grouped
/// `Form` as the editor, so switching modes keeps the layout; renders
/// without a session.
struct EventRecordView: View {
    let event: CalendarEvent
    /// The linked patient's display name. `nil` hides the section, also when
    /// the directory no longer knows the patient: events store only its id.
    var patientName: String?
    /// Opens the linked patient.
    var onOpenPatient: () -> Void = {}

    var body: some View {
        let summary = EventSummary(event)
        Form {
            Section { header(summary) }
                .listRowBackground(Color.clear)
            if let patientName {
                Section {
                    patientRow(patientName)
                } header: {
                    DetailSectionHeader(title: "Patient", systemImage: "person")
                }
            }
            let notes = event.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                Section {
                    Text(verbatim: notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Chrome.Space.xs)
                } header: {
                    DetailSectionHeader(title: "Description", systemImage: "text.alignleft")
                }
            }
            Section { footer }
                .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
    }

    // MARK: - Header

    private func header(_ summary: EventSummary) -> some View {
        let tint = Chrome.eventTint(event.eventType)
        return HStack(alignment: .top, spacing: Chrome.Space.lg) {
            Image(systemName: Chrome.eventSymbol(event.eventType))
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: Chrome.Radius.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                Text(DisplayCopy.title(event.title))
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                StatusPill(text: DisplayCopy.eventType(event.eventType), tint: tint)
                Text(verbatim: summary.when)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, Chrome.Space.xxs)
                Text(verbatim: [summary.relative, summary.duration].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Chrome.Space.xs)
    }

    // MARK: - Patient

    private func patientRow(_ name: String) -> some View {
        Button(action: onOpenPatient) {
            HStack(spacing: Chrome.Row.leadingSpacing) {
                MonogramAvatar(initials: Self.initials(of: name), size: 28)
                Text(verbatim: name)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open patient")
    }

    private static func initials(of name: String) -> String {
        let parts = name.split(separator: " ")
        return DisplayCopy.initials(first: parts.first.map(String.init) ?? "",
                                    last: parts.count > 1 ? String(parts.last!) : "")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Chrome.Space.xs) {
            Text("Created \(event.createdAt.formatted(date: .abbreviated, time: .shortened))")
            Text(verbatim: "·")
            Text("Updated \(event.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            if event.ekEventIdentifier != nil, event.syncStatus == .synced {
                Text(verbatim: "·")
                Label("Synced with Apple Calendar", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
