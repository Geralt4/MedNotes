import SwiftUI

/// The destination wizard: after EventKit permission, the user must choose the
/// exact calendar or list MedNotes may write to.
///
/// Defaults to creating a new `MedNotes` container in a source the user
/// explicitly picks; adopting an existing destination is the secondary choice.
/// The disclosure names the source, its type, whether the container is
/// app-created, and exactly which fields will leave the app. EventKit cannot
/// prove whether a destination is shared, so choosing a cloud source requires
/// an explicit acknowledgment that its participants may receive the data.
struct SyncDestinationWizard: View {
    enum Bridge {
        case calendar
        case reminders

        var title: String {
            switch self {
            case .calendar: return String(localized: "Choose a Calendar")
            case .reminders: return String(localized: "Choose a Reminders List")
            }
        }

        var containerNoun: String {
            switch self {
            case .calendar: return String(localized: "calendar")
            case .reminders: return String(localized: "list")
            }
        }
    }

    struct SourceOption: Identifiable, Equatable {
        var id: String { identifier }
        var identifier: String
        var title: String
        var type: String
        var isCloud: Bool
    }

    let bridge: Bridge
    /// Sources the user can create a new MedNotes container in.
    let sources: [SourceOption]
    /// Existing containers, offered as the secondary choice.
    let existing: [SyncDestinationCandidate]
    /// The count and kinds of records that would travel through this bridge.
    let recordSummary: String
    /// Human-readable field names that leave the app.
    let transmittedFields: [String]
    /// Creates the container in the chosen source and returns it.
    let createInSource: (String) async throws -> SyncDestinationCandidate
    /// Confirms a candidate as the destination.
    let confirm: (SyncDestinationCandidate) async throws -> SyncDestination
    let onCancel: () -> Void

    @State private var mode: Mode = .newContainer
    @State private var selectedSourceID: String?
    @State private var selectedCandidateID: String?
    @State private var acknowledgedCloud = false
    @State private var failure: String?
    @State private var isWorking = false
    /// The container "Create" made in `createdInSourceID`, kept so that a
    /// retry after a failed confirmation confirms it instead of creating a
    /// second "MedNotes" calendar or list in the same account.
    @State private var createdCandidate: SyncDestinationCandidate?
    @State private var createdInSourceID: String?

    private enum Mode: String, CaseIterable {
        case newContainer
        case existing

        var label: String {
            switch self {
            case .newContainer: return String(localized: "Create a new one")
            case .existing: return String(localized: "Use an existing one")
            }
        }
    }

    private var selectedCandidate: SyncDestinationCandidate? {
        existing.first { $0.calendarIdentifier == selectedCandidateID }
    }

    private var selectedSource: SourceOption? {
        sources.first { $0.identifier == selectedSourceID }
    }

    private var requiresAcknowledgment: Bool {
        switch mode {
        case .newContainer: return selectedSource?.isCloud ?? false
        case .existing: return selectedCandidate?.requiresCloudAcknowledgment ?? false
        }
    }

    private var canConfirm: Bool {
        guard !isWorking else { return false }
        if requiresAcknowledgment && !acknowledgedCloud { return false }
        switch mode {
        case .newContainer: return selectedSourceID != nil
        case .existing: return selectedCandidateID != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            Label(bridge.title, systemImage: bridge == .calendar ? "calendar" : "checklist")
                .font(.title3.weight(.semibold))

            Text("MedNotes writes only to the destination you choose here. It never picks one by name, and it stops if that destination disappears.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .newContainer {
                newContainerChooser
            } else {
                existingChooser
            }

            disclosure

            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isWorking ? "Connecting…" : "Confirm Destination") {
                    Task { await confirmSelection() }
                }
                .keyboardShortcut(.defaultAction)
                .prominentActionButtonStyle()
                .disabled(!canConfirm)
            }
        }
        .padding(Chrome.Space.xl)
        .frame(width: 520)
        .onAppear {
            if selectedSourceID == nil, let first = sources.first { selectedSourceID = first.identifier }
            if selectedCandidateID == nil, let first = existing.first { selectedCandidateID = first.calendarIdentifier }
        }
        // The acknowledgment is for the destination the user looked at. A new
        // account, list/calendar or mode needs its own.
        .onChange(of: mode) { acknowledgedCloud = false }
        .onChange(of: selectedSourceID) { acknowledgedCloud = false }
        .onChange(of: selectedCandidateID) { acknowledgedCloud = false }
    }

    private var newContainerChooser: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Text("New \(bridge.containerNoun) account")
                .font(.headline)
            if sources.isEmpty {
                Text("No account can hold a new \(bridge.containerNoun).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Account", selection: $selectedSourceID) {
                    ForEach(sources) { source in
                        Text(verbatim: "\(source.title) — \(DisplayCopy.syncSourceType(source.type))").tag(Optional(source.identifier))
                    }
                }
                Text("MedNotes creates a “MedNotes” \(bridge.containerNoun) in this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var existingChooser: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Text("Existing \(bridge.containerNoun)")
                .font(.headline)
            if existing.isEmpty {
                Text("There is no existing \(bridge.containerNoun) to adopt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Destination", selection: $selectedCandidateID) {
                    ForEach(existing) { candidate in
                        Text(verbatim: "\(candidate.calendarTitle) — \(candidate.sourceTitle) (\(DisplayCopy.syncSourceType(candidate.sourceType)))")
                            .tag(Optional(candidate.calendarIdentifier))
                    }
                }
                if let candidate = selectedCandidate {
                    Text(candidate.isAppCreated
                         ? "A “MedNotes” container MedNotes created earlier."
                         : "An existing container. MedNotes will only touch records it created and marked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.xs) {
            Text("What leaves MedNotes")
                .font(.headline)
            Text(verbatim: recordSummary)
                .font(.callout)
            Text(verbatim: String(localized: "Fields: \(transmittedFields.joined(separator: ", "))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if requiresAcknowledgment {
                Toggle(isOn: $acknowledgedCloud) {
                    Text("I understand that this account may be shared, and its participants may receive this clinical data.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func confirmSelection() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let candidate: SyncDestinationCandidate
            switch mode {
            case .newContainer:
                guard let sourceID = selectedSourceID else { return }
                if let created = createdCandidate, createdInSourceID == sourceID {
                    candidate = created
                } else {
                    candidate = try await createInSource(sourceID)
                    createdCandidate = candidate
                    createdInSourceID = sourceID
                }
            case .existing:
                guard let candidateID = selectedCandidateID,
                      let found = existing.first(where: { $0.calendarIdentifier == candidateID }) else {
                    return
                }
                candidate = found
            }
            _ = try await confirm(candidate)
        } catch {
            failure = error.localizedDescription
        }
    }
}
