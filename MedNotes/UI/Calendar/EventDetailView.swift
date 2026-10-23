import SwiftUI

struct EventDetailView: View {
    @EnvironmentObject private var session: AppSession
    @State private var draft: CalendarEvent?
    @State private var original: CalendarEvent?
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    /// The record whose title takes focus when its editor appears: only ever
    /// the event the user just created, never one they arrowed to.
    @State private var autofocusEventId: UUID?
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
            session.unregisterOpenEditor(lockToken)
            guard let d = draft else { return }
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
                Task { await session.deleteSelectedEvent() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func loadEvent() async {
        let selectedId = session.selectedEventId
        if let d = draft, d.id == selectedId, hasChanges {
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
        defer { if showLoading { isLoading = false } }
        if switching { autofocusEventId = nil }
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
        }
    }

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    @ViewBuilder
    private var editorView: some View {
        if let event = draft {
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
            // Fresh editor state and scroll position per event.
            .id(event.id)
            .softTopEdge()
            .toolbar {
                EditorToolbar(
                    hasChanges: hasChanges,
                    onRevert: { draft = original },
                    onSave: {
                        if let d = draft {
                            Task {
                                // Only refresh the editor from the store when the
                                // user hasn't typed during the save window.
                                if await session.save(d),
                                   let latest = await session.loadSelectedEvent(),
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
                    },
                    onDelete: { showDeleteConfirm = true }
                )
            }
        }
    }
}
