import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Commands on the current module: create, delete, pin, focus, and the small helpers they use.
extension AppSession {
    static func matchesSearchTokens(_ query: String, fields: [String]) -> Bool {
        // Folded on both sides: case, accents and the final sigma do not matter.
        let tokens = Schema.splitTokens(query).map(WikiLinkParser.normalizedKey)
        guard !tokens.isEmpty else { return false }
        let folded = fields.map(WikiLinkParser.normalizedKey)
        return tokens.allSatisfy { token in
            folded.contains { $0.contains(token) }
        }
    }

    func patientName(for id: UUID) -> String? {
        patientDirectory.first(where: { $0.id == id }).map { DisplayCopy.patient($0) }
    }

    func sidebarCount(for module: AppModule) -> Int {
        switch module {
        case .notes: return sidebarNoteCount
        case .patients: return sidebarPatientCount
        case .todos: return sidebarPendingTodoCount
        case .calendar: return sidebarUpcomingEventCount
        case .graph: return 0
        }
    }

    func consumeFocusRequest(for recordId: UUID) -> Bool {
        guard pendingFocusRecordId == recordId else { return false }
        pendingFocusRecordId = nil
        return true
    }

    /// Graph has no records of its own, so ⌘N has nothing to create there.
    var canCreateInCurrentModule: Bool { selectedModule != .graph }

    func createInCurrentModule() async {
        switch selectedModule {
        case .notes: await newNote()
        case .patients: await newPatient()
        case .todos: await newTodo()
        case .calendar: await newEvent()
        case .graph: break
        }
    }

    var canDeleteSelection: Bool {
        switch selectedModule {
        case .notes: return selectedNoteId != nil
        case .patients: return selectedPatientId != nil
        case .todos: return selectedTodoId != nil
        case .calendar: return selectedEventId != nil
        case .graph: return false
        }
    }

    private func selectedId(in module: AppModule) -> UUID? {
        switch module {
        case .notes: return selectedNoteId
        case .patients: return selectedPatientId
        case .todos: return selectedTodoId
        case .calendar: return selectedEventId
        case .graph: return nil
        }
    }

    var pendingDeletionArchives: Bool {
        let module = pendingDeletion?.module ?? selectedModule
        guard module == .patients else { return false }
        return !(pendingDeletion?.isPermanent ?? (patientFilter == .archived))
    }

    var pendingDeleteTitle: String {
        if pendingDeletionArchives {
            return String(localized: "Archive this patient?")
        }
        return (pendingDeletion?.module ?? selectedModule).deleteConfirmTitle
    }

    var pendingDeleteMessage: String {
        if pendingDeletionArchives {
            return String(localized: "Notes, todos and appointments stay linked, and the record can be restored from the Archived list.")
        }
        return String(localized: "This cannot be undone.")
    }

    /// Whether Edit › Delete may ask about the selected record now: not while
    /// a sheet, an alert, the quick switcher, the privacy curtain or the
    /// confirmation itself covers the main window. The dialog would queue
    /// behind the sheet, or ask over a record nobody can see.
    var canRequestDelete: Bool {
        canDeleteSelection && !confirmDelete
            && backupFlow == nil && importFlow == nil && destinationFlow == nil
            && errorMessage == nil && notice == nil
            && !showSwitcher && !showsPrivacyCurtain
    }

    func requestDelete() {
        guard canRequestDelete else { return }
        guard let id = selectedId(in: selectedModule) else { return }
        // Snapshot the target now so the confirmation dialog deletes exactly
        // what it described, even if the module or selection changes while the
        // dialog is up.
        pendingDeletion = PendingDeletion(
            module: selectedModule, id: id,
            isPermanent: selectedModule != .patients || patientFilter == .archived)
        confirmDelete = true
    }

    /// Deletes the entity captured in `pendingDeletion` (the module + id
    /// snapshotted when the confirmation was requested — not necessarily the
    /// current module's selection). No-op when no snapshot is pending.
    func deleteInCurrentModule() async {
        guard let target = pendingDeletion else { return }
        // Clear only this request: a delete confirmed meanwhile keeps its own snapshot.
        defer { if pendingDeletion?.id == target.id { pendingDeletion = nil } }
        switch target.module {
        case .notes: await deleteNote(id: target.id)
        case .patients:
            if target.isPermanent {
                await deletePatient(id: target.id)
            } else {
                await archivePatient(id: target.id)
            }
        case .todos: await deleteTodo(id: target.id)
        case .calendar: await deleteEvent(id: target.id)
        case .graph: break
        }
    }

    var canPinSelection: Bool {
        // Require the note to be resolvable in the current list so the Pin
        // command can't show a stale title or silently no-op when a search
        // excludes the selected note.
        guard selectedModule == .notes, let id = selectedNoteId else { return false }
        return notes.contains(where: { $0.id == id })
    }

    var selectedNoteIsPinned: Bool {
        guard let id = selectedNoteId else { return false }
        return notes.first(where: { $0.id == id })?.isPinned == true
    }

    func pinSelectedNote() async {
        guard let id = selectedNoteId,
              let note = notes.first(where: { $0.id == id }) else { return }
        _ = await togglePin(note)
    }

    var canToggleSelectedTodo: Bool {
        selectedModule == .todos && selectedTodoId != nil
    }

    func toggleSelectedTodo() async {
        guard let id = selectedTodoId else { return }
        await toggleTodo(id: id)
    }

    func dismissError() {
        errorMessage = nil
    }
}
