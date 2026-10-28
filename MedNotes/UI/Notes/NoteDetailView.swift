import SwiftUI

struct NoteDetailView: View {
    @EnvironmentObject private var session: AppSession
    @State private var draft: Note?
    @State private var original: Note?
    @State private var isLoading = true
    @State private var loads = LoadGeneration()
    @State private var showDeleteConfirm = false
    @State private var isPreviewing = false
    @State private var templates: [NoteTemplate] = []
    /// The note whose title takes focus once it is loaded: only ever the note
    /// the user just created, never one they arrowed to.
    @State private var autofocusNoteId: UUID?
    @FocusState private var isTitleFocused: Bool
    /// The window's undo manager: the title and body text views register
    /// their typing with it.
    @Environment(\.undoManager) private var undoManager
    /// This editor's registration with the session, so a lock saves the
    /// draft before the store closes; see `OpenEditorDraft`.
    @State private var lockToken = UUID()

    private var loadId: String {
        "\(session.selectedNoteId?.uuidString ?? "none")-\(session.noteEpoch)"
    }

    /// The body's text view, caret and undo, which `TextEditor` does not
    /// expose on macOS 14.
    @StateObject private var bodyEditor = NoteBodyEditor()

    /// The link being typed at the body's caret — drives the autocomplete
    /// popover.
    private var openAnchorText: String? {
        guard let draft else { return nil }
        return bodyEditor.openAnchor(in: draft)
    }

    /// Completions for the open anchor, fetched from the whole store by
    /// `AppSession.linkCandidates`; the list column's load may be filtered.
    @State private var anchorCandidates: [AppSession.LinkCandidate] = []

    var body: some View {
        // Once per redraw: it compares the whole body with the text view.
        let anchor = openAnchorText
        // The editor and, beside it, the inspector. A plain column rather than
        // `.inspector`: the system inspector re-lays out its content at moments
        // that wipe a half-typed accent (`NoteEditorUndoTests`), and the editor
        // must keep one place in the hierarchy while a note loads and switches.
        HStack(spacing: 0) {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let draft {
                    noteEditor(draft, anchor: anchor)
                } else {
                    Text("Note not found")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if session.noteInspectorShown {
                Divider()
                NoteInspector(note: draft, applyProperty: applyProperty, reveal: reveal)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task(id: loadId) {
            await loadNote()
        }
        .onChange(of: autofocusNoteId) { _, id in
            guard id != nil else { return }
            // This editor is not re-created per note, so the request is
            // answered here rather than on appearance — one turn later, so
            // the field exists when focus lands. The title comes up selected.
            DispatchQueue.main.async {
                isTitleFocused = true
                autofocusNoteId = nil
            }
        }
        // Selection changes and saves (which relink the note) both move loadId.
        .onChange(of: loadId) {
            if let id = session.selectedNoteId { Task { await session.refreshLinks(noteId: id) } }
        }
        .onAppear {
            let draft = $draft, original = $original
            session.registerOpenEditor(lockToken) {
                draft.wrappedValue.map { .note($0, edited: $0 != original.wrappedValue) }
            }
            if let id = session.selectedNoteId {
                Task { await session.refreshLinks(noteId: id) }
            }
        }
        // On appearance and again whenever Settings › Templates changes one.
        .task(id: session.templateEpoch) {
            templates = await session.templatesForMenu()
        }
        // Every keystroke inside `[[` restarts this; the pause is the
        // debounce, and a superseded lookup is simply cancelled.
        .task(id: anchor) {
            guard let anchor else {
                anchorCandidates = []
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let candidates = await session.linkCandidates(anchor: anchor, excluding: draft?.id)
            // Redrawing mid-composition would put the draft's text back over
            // the half-typed letter; committing it moves on to a new lookup.
            while bodyEditor.isComposing, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled else { return }
            anchorCandidates = candidates
        }
        // Where the body's caret is, which the popover follows. Editing
        // beginning is when the body is first seen showing the draft.
        .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) {
            bodyEditor.track($0.object, showing: draft)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) {
            bodyEditor.track($0.object, showing: draft)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) {
            bodyEditor.track($0.object, showing: draft)
        }
        // Undo and redo never reach the binding; take the body's text back.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)
            .merge(with: NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange))) {
            if let text = bodyEditor.textAfterUndo($0, of: draft) { draft?.content = text }
        }
        .background(WindowReader { bodyEditor.attach(to: $0) })
        // Typing, undo, templates and reverts all change the body; opening a
        // note or leaving Preview brings up a fresh text view. Each restyles.
        .onChange(of: draft?.content, initial: true) { bodyEditor.restyleSoon(draft) }
        .onChange(of: "\(draft?.id.uuidString ?? "")-\(isPreviewing)") { bodyEditor.restyleSoon(draft) }
        .onDisappear {
            session.unregisterOpenEditor(lockToken)
            guard let d = draft else { return }
            if hasChanges {
                Task {
                    if session.selectedNoteId == d.id {
                        _ = await session.save(d)
                    } else if await session.noteExists(id: d.id) == true {
                        // Selection moved elsewhere or was cleared; still autosave
                        // this note's edits as long as it still exists.
                        _ = await session.save(d)
                    }
                }
            } else if session.isUntouchedNewNote(d) {
                // Module switch or cleared selection while a fresh, untouched
                // record was open: it was never meant to be kept.
                Task { await session.discardIfUntouched(d) }
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await session.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Wiki-link autocomplete

    /// Floating candidate list shown while the caret is in an open [[.
    private func wikiAnchorPopover(_ anchor: String) -> some View {
        Group {
            if !anchorCandidates.isEmpty || !anchor.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Keyed by entity id, not title: two patients can share a
                    // display name (father's name is what disambiguates them),
                    // and duplicate ForEach ids drop or misrender rows.
                    ForEach(anchorCandidates) { candidate in
                        Button {
                            completeAnchor(candidate.insert)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: candidate.kind == .patient ? "person" : "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(candidate.title)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if anchorCandidates.isEmpty {
                        Text("Keep typing — creates link text")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(Chrome.Space.sm)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Chrome.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Chrome.Radius.chip)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    private func completeAnchor(_ choice: String) {
        guard var d = draft else { return }
        // Through the body's text view, so it lands on its undo stack.
        if bodyEditor.complete(with: choice, in: d, updateDraft: { draft?.content = $0 }) { return }
        // No text view to edit through: complete at the note's end, where
        // the whole-text rule found the link the popover showed.
        d.content = LinkingService.complete(openAnchorText: d.content, choice: choice)
        replaceDraft(with: d)
    }

    /// Puts `note` in the editor in place of the text being edited.
    ///
    /// The title and body are AppKit text views whose typing undo actions
    /// hold ranges into the text they were typed into. Once that text is
    /// replaced from here, ⌘Z would apply those ranges to the new text —
    /// garbling it, or raising `NSRangeException` when they no longer fit —
    /// so the window's undo history goes with it.
    private func replaceDraft(with note: Note?) {
        let replacesText = note?.content != draft?.content || note?.title != draft?.title
        draft = note
        if replacesText { undoManager?.removeAllActions() }
    }

    // MARK: - Templates

    private func applyTemplate(_ template: NoteTemplate) {
        guard var d = draft else { return }
        let patientName = d.mentionedPatients.first.flatMap { session.patientName(for: $0) }
        let rendered = template.rendered(patientName: patientName)
        if d.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d.content = rendered
        } else {
            d.content += "\n\n---\n\n" + rendered
        }
        replaceDraft(with: d)
    }

    private func loadNote() async {
        let generation = loads.begin()
        // Only the newest load clears the spinner, on any exit: one that was
        // cancelled and ends late must not uncover the previous record.
        defer { if loads.isCurrent(generation) { isLoading = false } }
        let selectedId = session.selectedNoteId
        if let d = draft, d.id == selectedId, hasChanges {
            // Keep local edits, but take pin state from the store so a
            // list-side pin toggle is not overwritten on the next save.
            // Read the draft again after the load: typing goes on meanwhile.
            if let latest = await session.loadSelectedNote(), latest.id == d.id,
               var current = draft, current.id == latest.id {
                current.isPinned = latest.isPinned
                current.updatedAt = latest.updatedAt
                draft = current
                if var orig = original {
                    orig.isPinned = latest.isPinned
                    orig.updatedAt = latest.updatedAt
                    original = orig
                }
            }
            return
        }
        if hasChanges, let d = draft, let selectedId, d.id != selectedId {
            if await session.save(d) == false {
                session.select(d.id)
                return
            }
            // The save bumps `noteEpoch`, which restarts this task before it
            // loads the next note. Unless the edits count as saved, the
            // restart saves them again and is restarted in turn: measured,
            // hundreds of saves and seconds before the next note showed.
            if draft == d { original = d }
        } else if let d = draft, d.id != selectedId, session.isUntouchedNewNote(d) {
            // Leaving a record the user created and never touched: drop it
            // rather than leave a "New Note" row behind.
            await session.discardIfUntouched(d)
        }
        let switching = draft?.id != selectedId
        let showLoading = draft == nil || switching
        if showLoading { isLoading = true }
        let priorDraft = draft
        let loaded = await session.loadSelectedNote()
        if Task.isCancelled { return }
        guard let note = loaded, note.id == selectedId else {
            // Only clear when the editor wasn't touched during the load.
            if draft == priorDraft {
                replaceDraft(with: nil)
                original = nil
            }
            return
        }
        // Don't clobber edits made while the load was in flight.
        guard draft == priorDraft else { return }
        replaceDraft(with: note)
        original = note
        if session.consumeFocusRequest(for: note.id) {
            autofocusNoteId = note.id
        }
    }

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    @ViewBuilder
    private func noteEditor(_ current: Note, anchor: String?) -> some View {
        VStack(spacing: 0) {
            TextField("Title", text: Binding(
                get: { draft?.title ?? "" },
                set: { draft?.title = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .focused($isTitleFocused)
            .padding(.horizontal, Chrome.Space.lg)
            .padding(.vertical, Chrome.Space.md)
            .readableColumn()

            Divider()

            if isPreviewing, let d = draft {
                ScrollView {
                    // The title field above stays in view; the body only.
                    MarkdownPreview(markdown: d.content)
                        .padding(Chrome.Space.md)
                        .readableColumn()
                }
                .frame(minHeight: 220)
            } else {
                // Full width, with the text held to the readable column by
                // margins inside the editor: a click or scroll anywhere in the
                // pane reaches the text, and the scroller sits at the edge.
                GeometryReader { geometry in
                    let margin = max(0, (geometry.size.width - Chrome.readableWidth) / 2)
                    ZStack(alignment: .bottomLeading) {
                        TextEditor(text: Binding(
                            get: { draft?.content ?? "" },
                            set: { draft?.content = $0 }
                        ))
                        // A text view per note, so selection, scroll position and
                        // typing state never carry over from the previous one.
                        .id(current.id)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.vertical, Chrome.Space.sm)
                        // `contentMargins` does not reach a TextEditor's text
                        // (measured); the inset is set on its text view.
                        .onChange(of: margin, initial: true) {
                            bodyEditor.setHorizontalInset(margin + Chrome.Space.md, for: draft)
                        }

                        if let anchor {
                            wikiAnchorPopover(anchor)
                                .padding(Chrome.Space.md)
                                .padding(.leading, margin)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: Chrome.Space.sm) {
                TagEditor(tags: Binding(
                    get: { draft?.tags ?? [] },
                    set: { draft?.tags = $0 }
                ), collapsesField: true)
                if let created = draft?.createdAt, let updated = draft?.updatedAt {
                    HStack(spacing: Chrome.Space.xs) {
                        Text("Created \(created.formatted(date: .abbreviated, time: .shortened))")
                        Text(verbatim: "·")
                        Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                        Text(verbatim: "·")
                        Text("\(draft?.wordCount ?? 0) words")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Chrome.Space.lg)
            .padding(.vertical, 10)
            .readableColumn()
        }
        .toolbar {
            NoteToolbar(
                templates: templates,
                isPreviewing: isPreviewing,
                isPinned: draft?.isPinned == true,
                hasChanges: hasChanges,
                onTemplate: applyTemplate,
                onTogglePreview: { isPreviewing.toggle() },
                onTogglePin: togglePin,
                onRevert: { replaceDraft(with: original) },
                onSave: save,
                onDelete: { showDeleteConfirm = true },
                isInspectorShown: session.noteInspectorShown,
                onToggleInspector: { session.noteInspectorShown.toggle() })
        }
    }

    // MARK: - The inspector's actions

    /// Writes one property change into the note's text. The edit belongs to
    /// the note the panel was showing when the field was edited: if another
    /// note is open by the time it arrives (clicking the list ends a field's
    /// focus after the selection changed), it is dropped.
    private func applyProperty(noteID: UUID, _ operation: FrontMatterEditor.Operation, expecting: String?) {
        guard PropertyEditRouting.accepts(noteID: noteID, draft: draft), let current = draft else { return }
        let outcome = bodyEditor.editProperty(
            operation, expecting: expecting, in: current, updateDraft: { draft?.content = $0 })
        guard outcome == .noTextView else { return }
        // Preview is showing: no text view to edit through, so the draft is
        // edited directly, which clears the undo stack (see `replaceDraft`).
        if let updated = PropertyEditRouting.draftAfter(operation, expecting: expecting, noteID: noteID, draft: draft) {
            replaceDraft(with: updated)
        }
    }

    /// Puts the caret at a heading of the open note, leaving Preview first.
    private func reveal(offset: Int) {
        if isPreviewing { isPreviewing = false }
        revealWhenReady(offset: offset, attempts: 12)
    }

    private func revealWhenReady(offset: Int, attempts: Int) {
        guard let current = draft else { return }
        if bodyEditor.reveal(utf16Offset: offset, in: current) || attempts <= 0 { return }
        // The body's text view is not there yet (Preview was showing).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            revealWhenReady(offset: offset, attempts: attempts - 1)
        }
    }

    private func save() {
        guard let d = draft else { return }
        Task {
            // Only refresh the editor from the store when the user hasn't
            // typed during the save window; the editable fields are compared
            // against the snapshot that was saved (system fields like
            // updatedAt may legitimately differ via reconcile).
            if await session.save(d),
               let latest = await session.loadSelectedNote(),
               latest.id == d.id,
               draft?.title == d.title,
               draft?.content == d.content,
               draft?.tags == d.tags {
                replaceDraft(with: latest)
                original = latest
            }
        }
    }

    /// Pins at once, outside the save flow: the store is told directly, and
    /// the draft and its baseline both take the flag so it reads as no edit.
    private func togglePin() {
        guard var d = draft else { return }
        d.isPinned.toggle()
        draft = d
        if var orig = original {
            orig.isPinned = d.isPinned
            original = orig
        }
        Task {
            if await session.togglePin(d) == false,
               let latest = await session.loadSelectedNote() {
                if var current = draft, current.id == latest.id {
                    current.isPinned = latest.isPinned
                    current.updatedAt = latest.updatedAt
                    draft = current
                }
                if var orig = original, orig.id == latest.id {
                    orig.isPinned = latest.isPinned
                    orig.updatedAt = latest.updatedAt
                    original = orig
                }
            }
        }
    }
}

/// The note's actions, all in the toolbar so the pane opens on the title:
/// Delete, then template, preview and pin, then Revert and Save after a change.
private struct NoteToolbar: ToolbarContent {
    let templates: [NoteTemplate]
    let isPreviewing: Bool
    let isPinned: Bool
    let hasChanges: Bool
    let onTemplate: (NoteTemplate) -> Void
    let onTogglePreview: () -> Void
    let onTogglePin: () -> Void
    let onRevert: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    let isInspectorShown: Bool
    let onToggleInspector: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .help("Delete")
            .accessibilityLabel("Delete")
        }
        ToolbarSpacerCompat()
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(templates) { template in
                    Button(template.name) { onTemplate(template) }
                }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .menuIndicator(.hidden)
            .disabled(templates.isEmpty)
            .help("Insert clinical template")
            .accessibilityLabel("Insert clinical template")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onTogglePreview) {
                Image(systemName: isPreviewing ? "pencil" : "eye")
            }
            .help(isPreviewing ? "Edit" : "Preview")
            .accessibilityLabel(isPreviewing ? "Edit" : "Preview")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onToggleInspector) {
                Image(systemName: "sidebar.right")
            }
            .help(isInspectorShown ? "Hide Inspector" : "Show Inspector")
            .accessibilityLabel(isInspectorShown ? "Hide Inspector" : "Show Inspector")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .symbolEffect(.bounce, value: isPinned)
            }
            .help(isPinned ? "Unpin" : "Pin")
            .accessibilityLabel(isPinned ? "Unpin" : "Pin")
        }
        if hasChanges {
            ToolbarSpacerCompat()
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
    }
}
