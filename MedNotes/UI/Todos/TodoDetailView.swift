import SwiftUI

struct TodoDetailView: View {
    @EnvironmentObject private var session: AppSession
    @State private var draft: TodoItem?
    @State private var original: TodoItem?
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    /// The record whose title takes focus when its editor appears: only ever
    /// the todo the user just created, never one they arrowed to.
    @State private var autofocusTodoId: UUID?
    /// The editor is showing rather than the record. Set for a todo the user
    /// just created, cleared whenever the selection moves.
    @State private var isEditing = false
    /// This editor's registration with the session, so a lock saves the
    /// draft before the store closes; see `OpenEditorDraft`.
    @State private var lockToken = UUID()

    private var loadId: String {
        "\(session.selectedTodoId?.uuidString ?? "none")-\(session.todoEpoch)"
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft != nil {
                editorView
            } else {
                Text("Todo not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadId) {
            await loadTodo()
        }
        .onAppear {
            let draft = $draft, original = $original
            session.registerOpenEditor(lockToken) {
                draft.wrappedValue.map { .todo($0, edited: $0 != original.wrappedValue) }
            }
        }
        .onDisappear {
            session.unregisterOpenEditor(lockToken)
            guard let d = draft else { return }
            if hasChanges {
                Task {
                    if session.selectedTodoId == d.id {
                        _ = await session.save(d)
                    } else if await session.todoExists(id: d.id) == true {
                        // Selection moved elsewhere or was cleared; still autosave
                        // this todo's edits as long as it still exists.
                        _ = await session.save(d)
                    }
                }
            } else if d.isUntouchedNewRecord {
                // Module switch or cleared selection while a fresh, untouched
                // record was open: it was never meant to be kept.
                Task { await session.discardIfUntouched(d) }
            }
        }
        .confirmationDialog("Delete this todo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await session.deleteSelectedTodo() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func loadTodo() async {
        let selectedId = session.selectedTodoId
        if let d = draft, d.id == selectedId, hasChanges {
            // Keep local edits, but take completion from the store so a
            // list-side toggle is not overwritten on the next save.
            if let latest = await session.loadSelectedTodo(), latest.id == d.id,
               var current = draft, current.id == latest.id {
                current.isCompleted = latest.isCompleted
                current.completedAt = latest.completedAt
                draft = current
                if var orig = original {
                    orig.isCompleted = latest.isCompleted
                    orig.completedAt = latest.completedAt
                    original = orig
                }
            }
            return
        }
        if hasChanges, let d = draft, let selectedId, d.id != selectedId {
            if await session.save(d) == false {
                session.selectTodo(d.id)
                return
            }
            // The save bumps `todoEpoch`, which restarts this task. Without
            // marking the saved draft clean, the restart saves it again and is
            // restarted in turn; see the same guard in `NoteDetailView`.
            if draft == d { original = d }
        } else if let d = draft, d.id != selectedId, d.isUntouchedNewRecord {
            // Leaving a record the user created and never touched: drop it
            // rather than leave a "New Todo" row behind.
            await session.discardIfUntouched(d)
        }
        let switching = draft?.id != selectedId
        let showLoading = draft == nil || switching
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }
        if switching {
            autofocusTodoId = nil
            isEditing = false
        }
        let priorDraft = draft
        let loaded = await session.loadSelectedTodo()
        if Task.isCancelled { return }
        guard let todo = loaded, todo.id == selectedId else {
            // Only clear when the editor wasn't touched during the load.
            if draft == priorDraft {
                draft = nil
                original = nil
            }
            return
        }
        // Don't clobber edits made while the load was in flight.
        guard draft == priorDraft else { return }
        draft = todo
        original = todo
        if session.consumeFocusRequest(for: todo.id) {
            autofocusTodoId = todo.id
            isEditing = true
        } else if switching, todo.isUntouchedNewRecord {
            // Nothing to read yet: an empty todo opens in the editor.
            isEditing = true
        }
    }

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    /// Completion is written to the store the moment it changes and mirrored
    /// into `original`, so Save/Revert only ever track the other edits and a
    /// list-side toggle cannot be undone by a later save.
    private func setCompleted(_ newValue: Bool) {
        draft?.isCompleted = newValue
        if newValue {
            if draft?.completedAt == nil {
                draft?.completedAt = Date()
            }
        } else {
            draft?.completedAt = nil
        }
        if var orig = original {
            orig.isCompleted = newValue
            orig.completedAt = draft?.completedAt
            original = orig
        }
        Task {
            if let d = draft,
               await session.save(d) == false,
               let latest = await session.loadSelectedTodo(),
               latest.id == d.id {
                if var current = draft, current.id == latest.id {
                    current.isCompleted = latest.isCompleted
                    current.completedAt = latest.completedAt
                    draft = current
                }
                if var orig = original, orig.id == latest.id {
                    orig.isCompleted = latest.isCompleted
                    orig.completedAt = latest.completedAt
                    original = orig
                }
            }
        }
    }

    @ViewBuilder
    private var editorView: some View {
        if let todo = draft {
            Group {
                if isEditing {
                    TodoEditorForm(
                        draft: Binding(
                            get: { draft ?? todo },
                            // A field can commit while its editor is being torn down
                            // for another todo; a stale form must never overwrite the
                            // record that replaced it.
                            set: { updated in
                                if draft?.id == updated.id { draft = updated }
                            }),
                        patientOptions: session.assignmentPatients(including: todo.patientId),
                        isKnownPatient: { session.patientName(for: $0) != nil },
                        onSetCompleted: setCompleted,
                        focusesTitleOnAppear: todo.id == autofocusTodoId
                    )
                } else {
                    let known = todo.patientId.flatMap { session.patientName(for: $0) }
                    let stored = todo.patientName?.trimmingCharacters(in: .whitespaces)
                    TodoRecordView(
                        todo: todo,
                        // As in the list row: a stored name shows even
                        // without a link (older and imported todos).
                        patientName: known ?? (stored?.isEmpty == false ? stored : nil),
                        canOpenPatient: known != nil,
                        onOpenPatient: {
                            if let id = todo.patientId {
                                Task { await session.jumpToPatient(id) }
                            }
                        },
                        onSetCompleted: setCompleted)
                }
            }
            // Fresh editor state and scroll position per todo.
            .id(todo.id)
            .softTopEdge()
            .toolbar {
                TodoToolbar(
                    isEditing: isEditing,
                    onEdit: { isEditing = true },
                    onCancel: {
                        draft = original
                        isEditing = false
                    },
                    onDone: save,
                    onDelete: { showDeleteConfirm = true })
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
            // Only refresh the editor from the store when the user hasn't
            // typed during the save window. The completion fields are
            // excluded: they are owned by the toggle/reconcile paths.
            if let latest = await session.loadSelectedTodo(),
               latest.id == d.id,
               draft?.title == d.title,
               draft?.notes == d.notes,
               draft?.tags == d.tags,
               draft?.priority == d.priority,
               draft?.dueDate == d.dueDate,
               draft?.patientId == d.patientId,
               draft?.patientName == d.patientName {
                draft = latest
                original = latest
            }
        }
    }
}

/// Reading: Delete and Edit. Editing: Delete, Cancel and Done.
private struct TodoToolbar: ToolbarContent {
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
                    .help("Edit this todo (⌘E)")
            }
        }
    }
}
