import SwiftUI

struct PatientDetailView: View {
    @EnvironmentObject private var session: AppSession
    @State private var draft: Patient?
    @State private var original: Patient?
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    /// The record the open delete or archive dialog is about, taken from the
    /// editor the user pressed the button in. The dialog acts on this, never on
    /// whatever the list has selected by the time it is confirmed.
    @State private var confirmTarget: (id: UUID, permanent: Bool)?
    /// Numbers the loads, so only the newest one clears the spinner; see
    /// `LoadGeneration`.
    @State private var loads = LoadGeneration()
    /// The record whose "First name" field takes focus when its editor appears:
    /// only ever the patient the user just created, never one they arrowed to.
    @State private var autofocusPatientId: UUID?
    /// The profile editor is showing rather than the record. Set for a
    /// record the user just created, cleared whenever the selection moves.
    @State private var isEditing = false
    /// This editor's registration with the session, so a lock saves the
    /// draft before the store closes; see `OpenEditorDraft`.
    @State private var lockToken = UUID()

    private var loadId: String {
        "\(session.selectedPatientId?.uuidString ?? "none")-\(session.patientEpoch)"
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft != nil {
                editorView
            } else {
                Text("Patient not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadId) {
            await loadPatient()
        }
        .onAppear {
            let draft = $draft, original = $original
            session.registerOpenEditor(lockToken) {
                draft.wrappedValue.map {
                    .patient($0, edited: $0 != original.wrappedValue,
                             knownFileIDs: original.wrappedValue.map { Set($0.files.map(\.id)) })
                }
            }
        }
        .onDisappear {
            // False when a lock or restore already saved or discarded this draft.
            guard session.unregisterOpenEditor(lockToken), let d = draft else { return }
            if hasChanges {
                Task {
                    if session.selectedPatientId == d.id {
                        _ = await saveDraft(d)
                    } else if await session.patientExists(id: d.id) == true {
                        // Selection moved elsewhere or was cleared; still autosave
                        // this patient's edits as long as it still exists.
                        _ = await saveDraft(d)
                    }
                }
            } else if d.isUntouchedNewRecord {
                // Module switch or cleared selection while a fresh, untouched
                // record was open: it was never meant to be kept.
                Task { await session.discardIfUntouched(d) }
            }
        }
        .confirmationDialog(
            confirmTarget?.permanent ?? isArchived
                ? "Delete this patient permanently?" : "Archive this patient?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button(confirmTarget?.permanent ?? isArchived ? "Delete" : "Archive",
                   role: confirmTarget?.permanent ?? isArchived ? .destructive : nil) {
                guard let target = confirmTarget else { return }
                Task {
                    if target.permanent {
                        await session.deletePatient(id: target.id)
                    } else {
                        await session.archivePatient(id: target.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmTarget?.permanent ?? isArchived
                ? "This cannot be undone."
                : "Notes, todos and appointments stay linked, and the record can be restored from the Archived list.")
        }
    }

    private func loadPatient() async {
        let generation = loads.begin()
        // Only the newest load clears the spinner, on any exit: one that was
        // cancelled and ends late must not uncover the previous record.
        defer { if loads.isCurrent(generation) { isLoading = false } }
        let selectedId = session.selectedPatientId
        if let d = draft, d.id == selectedId, hasChanges {
            return
        }
        if hasChanges, let d = draft, let selectedId, d.id != selectedId {
            if await saveDraft(d) == false {
                session.selectPatient(d.id)
                return
            }
            // The save bumps `patientEpoch`, which restarts this task. Without
            // marking the saved draft clean, the restart saves it again and is
            // restarted in turn; see the same guard in `NoteDetailView`.
            if draft == d { original = d }
        } else if let d = draft, d.id != selectedId, d.isUntouchedNewRecord {
            // Leaving a record the user created and never touched: drop it
            // rather than leave a "Unnamed Patient" row behind.
            await session.discardIfUntouched(d)
        }
        let switching = draft?.id != selectedId
        let showLoading = draft == nil || switching
        if showLoading { isLoading = true }
        if switching {
            autofocusPatientId = nil
            isEditing = false
        }
        let priorDraft = draft
        let loaded = await session.loadSelectedPatient()
        if Task.isCancelled { return }
        guard let patient = loaded, patient.id == selectedId else {
            // Only clear when the editor wasn't touched during the load.
            if draft == priorDraft {
                draft = nil
                original = nil
            }
            return
        }
        // Don't clobber edits made while the load was in flight.
        guard draft == priorDraft else { return }
        draft = patient
        original = patient
        if session.consumeFocusRequest(for: patient.id) {
            autofocusPatientId = patient.id
            isEditing = true
        } else if switching, patient.isUntouchedNewRecord {
            // Nothing to read yet: an empty record opens in the editor.
            isEditing = true
        }
    }

    /// Saves with the attachment ids this editor loaded, so a save from a draft
    /// older than the stored record cannot delete files it never saw.
    private func saveDraft(_ d: Patient) async -> Bool {
        await session.save(d, knownFileIDs: original.map { Set($0.files.map(\.id)) })
    }

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    private var isArchived: Bool {
        draft?.isArchived ?? false
    }

    @ViewBuilder
    private var editorView: some View {
        if let patient = draft {
            let binding = Binding(
                get: { draft ?? patient },
                // A field can commit while its editor is being torn down
                // for another patient; a stale form must never overwrite
                // the record that replaced it.
                set: { (updated: Patient) in
                    if draft?.id == updated.id { draft = updated }
                })
            Group {
                if isEditing && !patient.isArchived {
                    PatientEditorForm(
                        draft: binding,
                        focusesNameOnAppear: patient.id == autofocusPatientId,
                        // The AMKA column is unique across all patients, archived
                        // ones included, so the directory is the right haystack.
                        duplicateAMKA: { amka in
                            session.patientDirectory.first {
                                $0.id != patient.id && AMKA.normalized($0.profile.amka) == amka
                            }
                        }
                    )
                } else {
                    PatientRecordView(
                        patient: binding,
                        onEdit: patient.isArchived ? nil : { isEditing = true })
                        // An archived record is read until it is restored.
                        .disabled(patient.isArchived)
                }
            }
            // Fresh editor state and scroll position per patient.
            .id(patient.id)
            .softTopEdge()
            .toolbar {
                if patient.isArchived {
                    ArchivedPatientToolbar(
                        onRestore: { Task { await session.unarchivePatient(id: patient.id) } },
                        onDelete: {
                            confirmTarget = (patient.id, true)
                            showDeleteConfirm = true
                        })
                } else {
                    PatientToolbar(
                        isEditing: isEditing,
                        hasChanges: hasChanges,
                        onEdit: { isEditing = true },
                        onRevert: { draft = original },
                        onCancel: {
                            draft = original
                            isEditing = false
                        },
                        onSave: { save(thenLeaveEditing: false) },
                        onDone: { save(thenLeaveEditing: true) },
                        onArchive: {
                            confirmTarget = (patient.id, false)
                            showDeleteConfirm = true
                        })
                }
            }
        }
    }

    /// Saves the draft. Leaves the editor only once the save succeeded, so a
    /// failed save (a duplicate AMKA) keeps the fields in front of the user.
    private func save(thenLeaveEditing leave: Bool) {
        guard let d = draft else { return }
        guard hasChanges else {
            if leave { isEditing = false }
            return
        }
        Task {
            guard await saveDraft(d) else { return }
            if leave, draft?.id == d.id { isEditing = false }
            // Only refresh from the store when the user hasn't typed during
            // the save window.
            if let latest = await session.loadSelectedPatient(),
               latest.id == d.id,
               draft?.profile == d.profile,
               draft?.medical == d.medical {
                draft = latest
                original = latest
            }
        }
    }
}

/// Toolbar for a live patient. Reading: Archive and Edit, plus Revert and
/// Save after a change to the medical lists, which are edited in place.
/// Editing: Archive, Cancel and Done.
private struct PatientToolbar: ToolbarContent {
    let isEditing: Bool
    let hasChanges: Bool
    let onEdit: () -> Void
    let onRevert: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDone: () -> Void
    let onArchive: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: onArchive) {
                Image(systemName: "archivebox")
            }
            .help("Archive")
            .accessibilityLabel("Archive")
        }
        ToolbarSpacerCompat()
        if isEditing {
            ToolbarItem(placement: .primaryAction) {
                Button("Cancel", action: onCancel)
                    .help("Discard changes")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done", action: onDone)
                    .keyboardShortcut("s")
                    .prominentActionButtonStyle()
                    .help("Save changes (⌘S)")
            }
        } else {
            if hasChanges {
                ToolbarItem(placement: .primaryAction) {
                    Button("Revert", action: onRevert)
                        .help("Discard changes")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save", action: onSave)
                        .keyboardShortcut("s")
                        .prominentActionButtonStyle()
                        .help("Save changes (⌘S)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", action: onEdit)
                    .keyboardShortcut("e")
                    .help("Edit this patient (⌘E)")
            }
        }
    }
}

/// Toolbar for an archived patient: restore, or delete for good.
private struct ArchivedPatientToolbar: ToolbarContent {
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Delete permanently")
            .accessibilityLabel("Delete permanently")
        }
        ToolbarSpacerCompat()
        ToolbarItem(placement: .primaryAction) {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .prominentActionButtonStyle()
            .help("Restore to the active list")
        }
    }
}
