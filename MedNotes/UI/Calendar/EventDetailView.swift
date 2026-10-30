import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject private var session: AppSession
    @State private var draft: CalendarEvent?
    @State private var original: CalendarEvent?
    @State private var isLoading = true
    @State private var loads = LoadGeneration()
    @State private var showDeleteConfirm = false
    /// The record the open delete dialog is about, taken from the editor the
    /// button was pressed in; never whatever is selected when it is confirmed.
    @State private var deleteTargetId: UUID?
    /// The record whose title takes focus when its editor appears: only ever
    /// the event the user just created, never one they arrowed to.
    @State private var autofocusEventId: UUID?
    /// The editor is showing rather than the record. Set for an event the
    /// user just created, cleared whenever the selection moves.
    @State private var isEditing = false
    /// This editor's registration with the session, so a lock saves the
    /// draft before the store closes; see `OpenEditorDraft`.
    @State private var lockToken = UUID()

    private var loadId: String {
        "\(session.selectedEventId?.uuidString ?? "none")-\(session.eventEpoch)"
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft != nil {
                editorView
            } else {
                Text("Event not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadId) {
            await loadEvent()
        }
        .onAppear {
            let draft = $draft, original = $original
            session.registerOpenEditor(lockToken) {
                draft.wrappedValue.map { .event($0, edited: $0 != original.wrappedValue) }
            }
        }
        .onDisappear {
            // False when a lock or restore already saved or discarded this draft.
            guard session.unregisterOpenEditor(lockToken), let d = draft else { return }
            if hasChanges {
                Task {
                    if session.selectedEventId == d.id {
                        _ = await session.save(d)
                    } else if await session.eventExists(id: d.id) == true {
                        // Selection moved elsewhere or was cleared; still autosave
                        // this event's edits as long as it still exists.
                        _ = await session.save(d)
                    }
                }
            } else if d.isUntouchedNewRecord {
                // Module switch or cleared selection while a fresh, untouched
                // record was open: it was never meant to be kept.
                Task { await session.discardIfUntouched(d) }
            }
        }
        .confirmationDialog("Delete this event?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleteTargetId { Task { await session.deleteEvent(id: id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func loadEvent() async {
        let generation = loads.begin()
        // Only the newest load clears the spinner, on any exit: one that was
        // cancelled and ends late must not uncover the previous record.
        defer { if loads.isCurrent(generation) { isLoading = false } }
        let selectedId = session.selectedEventId
        if let d = draft, d.id == selectedId, hasChanges {
            // Keep the edits, but take the link to the synced calendar event
            // from the store: the bridge may have made or changed it since
            // this copy was read, and saving the stale fields would unlink it.
            if let latest = await session.loadSelectedEvent(), latest.id == d.id,
               var current = draft, current.id == latest.id {
                current.adoptSyncState(from: latest)
                draft = current
                if var orig = original {
                    orig.adoptSyncState(from: latest)
                    original = orig
                }
            }
            return
        }
        if hasChanges, let d = draft, let selectedId, d.id != selectedId {
            if await session.save(d) == false {
                session.selectEvent(d.id)
                return
            }
            // The save bumps `eventEpoch`, which restarts this task. Without
            // marking the saved draft clean, the restart saves it again and is
            // restarted in turn; see the same guard in `NoteDetailView`.
            if draft == d { original = d }
        } else if let d = draft, d.id != selectedId, d.isUntouchedNewRecord {
            // Leaving a record the user created and never touched: drop it
            // rather than leave a "New Event" row behind.
            await session.discardIfUntouched(d)
        }
        let switching = draft?.id != selectedId
        let showLoading = draft == nil || switching
        if showLoading { isLoading = true }
        if switching {
            autofocusEventId = nil
            isEditing = false
        }
        let priorDraft = draft
        let loaded = await session.loadSelectedEvent()
        if Task.isCancelled { return }
        guard let event = loaded, event.id == selectedId else {
            // Only clear when the editor wasn't touched during the load.
            if draft == priorDraft {
                draft = nil
                original = nil
            }
            return
        }
        // Don't clobber edits made while the load was in flight.
        guard draft == priorDraft else { return }
        draft = event
        original = event
        if session.consumeFocusRequest(for: event.id) {
            autofocusEventId = event.id
            isEditing = true
        } else if switching, event.isUntouchedNewRecord {
            // Nothing to read yet: an empty event opens in the editor.
            isEditing = true
        }
    }

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    @ViewBuilder
    private var editorView: some View {
        if let event = draft {
            Group {
                if isEditing {
                    EventEditorForm(
                        draft: Binding(
                            get: { draft ?? event },
                            // A field can commit while its editor is being torn down
                            // for another event; a stale form must never overwrite
                            // the record that replaced it.
                            set: { updated in
                                if draft?.id == updated.id { draft = updated }
                            }),
                        patientOptions: session.assignmentPatients(including: event.patientId),
                        isKnownPatient: { session.patientName(for: $0) != nil },
                        focusesTitleOnAppear: event.id == autofocusEventId
                    )
                } else {
                    let name = event.patientId.flatMap { session.patientName(for: $0) }
                    EventRecordView(
                        event: event,
                        patientName: name,
                        onOpenPatient: {
                            if let id = event.patientId {
                                Task { await session.jumpToPatient(id) }
                            }
                        })
                }
            }
            // Fresh editor state and scroll position per event.
            .id(event.id)
            .softTopEdge()
            .toolbar {
                EventToolbar(
                    isEditing: isEditing,
                    onEdit: { isEditing = true },
                    onCancel: {
                        draft = original
                        isEditing = false
                    },
                    onDone: save,
                    onDelete: {
                        deleteTargetId = draft?.id
                        showDeleteConfirm = true
                    })
            }
        }
    }

    /// Saves and returns to the record. Stays in the editor when the save
    /// fails, so the fields are still in front of the user.
    private func save() {
        guard let d = draft else { return }
        guard hasChanges else {
            isEditing = false
            return
        }
        Task {
            guard await session.save(d) else { return }
            if draft?.id == d.id { isEditing = false }
            // Only refresh from the store when the user hasn't typed during
            // the save window.
            if let latest = await session.loadSelectedEvent(),
               latest.id == d.id,
               draft?.title == d.title,
               draft?.description == d.description,
               draft?.startDate == d.startDate,
               draft?.endDate == d.endDate,
               draft?.isAllDay == d.isAllDay,
               draft?.eventType == d.eventType,
               draft?.patientId == d.patientId {
                draft = latest
                original = latest
            }
        }
    }
}

/// Reading: Delete and Edit. Editing: Delete, Cancel and Done.
private struct EventToolbar: ToolbarContent {
    let isEditing: Bool
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    let onDelete: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Delete")
            .accessibilityLabel("Delete")
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
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", action: onEdit)
                    .keyboardShortcut("e")
                    .help("Edit this event (⌘E)")
            }
        }
    }
}
