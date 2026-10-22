import SwiftUI

/// The pane's way to the store, as closures: the pane never sees a session,
/// so it renders offscreen and in tests over an in-memory stand-in.
struct TemplateActions {
    var load: () async throws -> [NoteTemplate]
    var save: (NoteTemplate) async throws -> Void
    /// Stores a fresh custom template the way "+" does for records, so there
    /// is a row to edit in place; `discardIfUntouched` takes it back.
    var create: () async throws -> NoteTemplate
    var delete: (String) async throws -> Void
    /// Puts a built-in's shipped copy back and returns it.
    var reset: (String) async throws -> NoteTemplate
    var discardIfUntouched: (NoteTemplate) async -> Void
}

/// Settings › Templates: the clinical templates behind the note editor's
/// "Insert clinical template" menu. Built-ins are edited in place and reset
/// to their shipped copy; custom templates are added and deleted.
///
/// The editor follows the record editors: a draft with explicit Save and
/// Revert, autosaved when the selection moves on, and a "+" that stores a
/// template up front and discards it again if it is left untouched.
struct TemplatesSettingsPane: View {
    let actions: TemplateActions
    /// The template a new note starts from; nil for a blank note. A value
    /// naming a template that no longer exists reads as "None".
    @Binding var defaultTemplateID: String?

    @State private var templates: [NoteTemplate] = []
    @State private var selectedId: String?
    @State private var draft: NoteTemplate?
    @State private var original: NoteTemplate?
    @State private var failure: String?
    @State private var confirmDelete = false
    @FocusState private var isNameFocused: Bool

    /// See `GeneralSettingsPane.height`. The list and the content box have
    /// fixed heights of their own, so the total does not move with the text.
    static let height: CGFloat = 680
    private static let listHeight: CGFloat = 148
    private static let contentHeight: CGFloat = 200

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    private var canSave: Bool {
        guard hasChanges, let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedIsCustom: Bool {
        draft.map { !$0.isBuiltIn } ?? false
    }

    /// Unknown ids show as "None" without being rewritten: the preference
    /// is cleared by the session when its template is deleted.
    private var defaultSelection: Binding<String?> {
        Binding(
            get: { templates.contains { $0.id == defaultTemplateID } ? defaultTemplateID : nil },
            set: { defaultTemplateID = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.md) {
            Picker("New notes start from", selection: defaultSelection) {
                Text("A blank note").tag(String?.none)
                ForEach(templates) { template in
                    Text(verbatim: DisplayCopy.title(template.name)).tag(String?.some(template.id))
                }
            }
            .fixedSize()

            List(selection: $selectedId) {
                ForEach(templates) { template in
                    TemplateRow(template: template)
                        .tag(template.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: Self.listHeight)
            .accessibilityLabel("Templates")

            ControlGroup {
                Button {
                    Task { await addTemplate() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a template")
                .accessibilityLabel("Add a template")

                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(!selectedIsCustom)
                .help("Delete the selected template")
                .accessibilityLabel("Delete the selected template")

                Button {
                    Task { await duplicateSelected() }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(draft == nil)
                .help("Duplicate the selected template")
                .accessibilityLabel("Duplicate the selected template")
            }
            .fixedSize()

            EditorTextField("Name", text: Binding(
                get: { draft?.name ?? "" },
                set: { draft?.name = $0 }
            ), focus: $isNameFocused, autocorrects: false)
            .disabled(draft == nil)

            EditorField("Content") {
                EditorTextArea(text: Binding(
                    get: { draft?.content ?? "" },
                    set: { draft?.content = $0 }
                ), minHeight: Self.contentHeight)
                .frame(height: Self.contentHeight)
                .disabled(draft == nil)
            }

            SettingsNote("{{date}}, {{time}} and {{patient}} are filled in when a template is inserted into a note. Built-in templates can be edited here and reset to their shipped copy; custom templates can be deleted.")

            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Chrome.Space.sm) {
                if let draft, draft.isBuiltIn {
                    Button("Reset to Default") {
                        Task { await resetSelected() }
                    }
                    .disabled(!draft.isEditedBuiltIn && !hasChanges)
                }
                Spacer()
                Button("Revert") {
                    draft = original
                }
                .disabled(!hasChanges)
                Button("Save") {
                    Task { await saveDraft() }
                }
                .keyboardShortcut("s")
                .prominentActionButtonStyle()
                .disabled(!canSave)
            }
        }
        .padding(Chrome.Space.xl)
        .frame(height: Self.height)
        .task {
            await reload(selecting: nil)
        }
        .onChange(of: selectedId) { previous, current in
            Task { await moveSelection(from: previous, to: current) }
        }
        .onDisappear {
            // Tab switched or window closed: the editors' rule applies —
            // unsaved edits are kept, an untouched "+" is not.
            guard let draft else { return }
            if hasChanges {
                Task { try? await actions.save(draft) }
            } else if draft.isUntouchedNewRecord {
                Task { await actions.discardIfUntouched(draft) }
            }
        }
        .confirmationDialog("Delete this template?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Loading and selection

    private func reload(selecting id: String?) async {
        do {
            templates = try await actions.load()
            failure = nil
        } catch {
            failure = error.localizedDescription
            return
        }
        let target = id ?? selectedId ?? templates.first?.id
        if let target, templates.contains(where: { $0.id == target }) {
            if selectedId != target {
                selectedId = target   // `moveSelection` loads the draft
            } else {
                showDraft(for: target)
            }
        } else {
            selectedId = templates.first?.id
        }
    }

    /// Leaving a row saves its edits or drops an untouched "+", as the record
    /// editors do; a save that fails keeps the row selected with its edits.
    private func moveSelection(from previous: String?, to current: String?) async {
        if let leaving = draft, leaving.id != current {
            if hasChanges {
                do {
                    try await actions.save(leaving)
                    replace(leaving)
                } catch {
                    failure = error.localizedDescription
                    selectedId = leaving.id
                    return
                }
            } else if leaving.isUntouchedNewRecord {
                await actions.discardIfUntouched(leaving)
                templates.removeAll { $0.id == leaving.id }
            }
        }
        guard let current else {
            draft = nil
            original = nil
            return
        }
        showDraft(for: current)
    }

    private func showDraft(for id: String) {
        // Keep an in-flight draft for the same row; never clobber typing.
        if let draft, draft.id == id { return }
        guard let template = templates.first(where: { $0.id == id }) else { return }
        draft = template
        original = template
    }

    private func replace(_ template: NoteTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        if draft?.id == template.id {
            draft = template
            original = template
        }
    }

    // MARK: - Actions

    private func saveDraft() async {
        guard let draft, canSave else { return }
        do {
            try await actions.save(draft)
            failure = nil
            replace(draft)
            // Customs sort by name; the rows may have moved.
            await reload(selecting: draft.id)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func addTemplate() async {
        do {
            let created = try await actions.create()
            failure = nil
            templates.append(created)
            selectedId = created.id
            isNameFocused = true
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Copies what is on screen — unsaved edits included — into a custom
    /// template named after it, and moves on to it.
    private func duplicateSelected() async {
        guard let draft else { return }
        let copy = draft.duplicate()
        do {
            try await actions.save(copy)
            failure = nil
            templates.append(copy)
            selectedId = copy.id
            isNameFocused = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard let draft, !draft.isBuiltIn else { return }
        do {
            try await actions.delete(draft.id)
            failure = nil
            self.draft = nil
            original = nil
            templates.removeAll { $0.id == draft.id }
            selectedId = templates.first?.id
        } catch {
            failure = error.localizedDescription
        }
    }

    private func resetSelected() async {
        guard let draft, draft.isBuiltIn else { return }
        do {
            let shipped = try await actions.reset(draft.id)
            failure = nil
            self.draft = shipped
            original = shipped
            replace(shipped)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Name on the left, provenance on the right: shipped, shipped-and-edited,
/// or the user's own.
private struct TemplateRow: View {
    let template: NoteTemplate

    var body: some View {
        HStack(spacing: Chrome.Space.sm) {
            Text(verbatim: DisplayCopy.title(template.name))
                .lineLimit(1)
            Spacer(minLength: Chrome.Space.sm)
            if template.isEditedBuiltIn {
                StatusPill("Edited", tint: .accentColor)
            } else if template.isBuiltIn {
                StatusPill("Built-in")
            } else {
                StatusPill("Custom")
            }
        }
        .padding(.vertical, Chrome.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG

extension TemplateActions {
    /// A store in memory, for offscreen renders and the render test. Custom
    /// templates keep their insertion order; the real store sorts by name.
    static func inMemory(_ initial: [NoteTemplate]) -> TemplateActions {
        final class Box: @unchecked Sendable {
            var templates: [NoteTemplate]
            init(_ templates: [NoteTemplate]) { self.templates = templates }
        }
        let box = Box(initial)
        func upsert(_ template: NoteTemplate) {
            if let index = box.templates.firstIndex(where: { $0.id == template.id }) {
                box.templates[index] = template
            } else {
                box.templates.append(template)
            }
        }
        return TemplateActions(
            load: { box.templates.map(\.displayed) },
            save: { upsert($0) },
            create: {
                let template = NoteTemplate.newRecord()
                upsert(template)
                return template
            },
            delete: { id in
                guard !TemplateService.builtInIDs.contains(id) else {
                    throw TemplateError.builtInCannotBeDeleted(id)
                }
                box.templates.removeAll { $0.id == id }
            },
            reset: { id in
                guard let shipped = TemplateService.builtIns.first(where: { $0.id == id }) else {
                    throw TemplateError.notBuiltIn(id)
                }
                upsert(shipped)
                return shipped.displayed
            },
            discardIfUntouched: { template in
                if template.isUntouchedNewRecord {
                    box.templates.removeAll { $0.id == template.id }
                }
            })
    }
}

#endif
