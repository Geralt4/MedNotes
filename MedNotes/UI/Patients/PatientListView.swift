import SwiftUI

struct PatientListView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var swipe = SwipeRevealController()
    /// The row a swipe, context menu or ⌘⌫ is about to archive — or, in the
    /// archived list, delete for good.
    @State private var pendingId: UUID?

    private var showsArchived: Bool { session.patientFilter == .archived }

    var body: some View {
        List(selection: Binding<UUID?>(
            get: { session.selectedPatientId },
            set: { session.selectPatient($0) }
        )) {
            ForEach(session.patients) { patient in
                PatientRowView(patient: patient)
                    .swipeToDelete(
                        id: patient.id,
                        label: showsArchived ? "Delete patient permanently" : "Archive patient",
                        symbol: showsArchived ? "trash.fill" : "archivebox.fill",
                        tint: Color(nsColor: showsArchived ? .systemRed : .systemOrange),
                        word: showsArchived ? "Delete" : "Archive")
                    .tag(patient.id)
                    .contextMenu {
                        if showsArchived {
                            Button {
                                Task { await session.unarchivePatient(id: patient.id) }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            Button(role: .destructive) {
                                pendingId = patient.id
                            } label: {
                                Label("Delete Permanently", systemImage: "trash")
                            }
                        } else {
                            Button {
                                pendingId = patient.id
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .swipeToDeleteContainer(swipe) { pendingId = $0 }
        .softTopEdge()
        .animation(.default, value: session.patients.map(\.id))
        .navigationTitle("Patients")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                // Icon-only for the same reason as the todo filter: width here
                // pushes the leading item across the split divider.
                Menu {
                    Picker("Filter", selection: Binding(
                        get: { session.patientFilter },
                        set: { session.patientFilter = $0 }
                    )) {
                        ForEach(PatientFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: showsArchived
                        ? "archivebox.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter: \(session.patientFilter.title)")
                .accessibilityLabel("Filter")
                .accessibilityValue(Text(verbatim: session.patientFilter.title))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.newPatient() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New patient")
                .accessibilityLabel("New patient")
            }
        }
        .overlay {
            if session.patients.isEmpty {
                listEmptyState
            }
        }
        // Search lives in the column, not the toolbar: as a toolbar item
        // macOS pins it to a fixed width at the window's trailing edge,
        // which pushed this list's own buttons across the split divider.
        .topBar {
            ListSearchField(
                prompt: showsArchived ? "Search archived patients" : "Search patients",
                text: Binding(
                    get: { session.patientSearchText },
                    set: { session.patientSearchText = $0 }
                ),
                focusToken: session.searchFocusToken
            )
            .padding(.horizontal, Chrome.Space.sm)
            .padding(.bottom, Chrome.Space.sm - 2)
        }
        .confirmationDialog(
            showsArchived ? "Delete this patient permanently?" : "Archive this patient?",
            isPresented: Binding(
                get: { pendingId != nil },
                set: { if !$0 { pendingId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(showsArchived ? "Delete" : "Archive", role: showsArchived ? .destructive : nil) {
                if let id = pendingId {
                    let permanent = showsArchived
                    Task {
                        if permanent {
                            await session.deletePatient(id: id)
                        } else {
                            await session.archivePatient(id: id)
                        }
                    }
                }
                pendingId = nil
            }
            Button("Cancel", role: .cancel) { pendingId = nil }
        } message: {
            Text(showsArchived
                ? "This cannot be undone."
                : "Notes, todos and appointments stay linked, and the record can be restored from the Archived list.")
        }
    }

    @ViewBuilder
    private var listEmptyState: some View {
        let query = session.patientSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            EmptyStateView.search(text: session.patientSearchText)
        } else if showsArchived {
            EmptyStateView(title: "No Archived Patients", systemImage: "archivebox",
                           description: "Archived patients appear here and can be restored.")
        } else {
            EmptyStateView(title: "No Patients", systemImage: "person.2", description: "Create a patient to get started.")
        }
    }
}
