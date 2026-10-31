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

/// Leaving the open template row before another row is selected or added.
/// Kept apart from the view so the failure path can be tested without a store.
enum TemplateDraftLeave {
    enum Outcome: Equatable {
        case none
        case saved(NoteTemplate)
        case discarded(NoteTemplate)
    }

    static func perform(
        draft: NoteTemplate?, original: NoteTemplate?, hasChanges: Bool,
        save: (NoteTemplate) async throws -> Void,
        discardIfUntouched: (NoteTemplate) async -> Void
    ) async -> Result<Outcome, Error> {
        guard let draft else { return .success(.none) }
        if hasChanges {
            var leaving = draft
            if leaving.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let original {
                leaving.name = original.name
            }
            do {
                try await save(leaving)
                return .success(.saved(leaving))
            } catch {
                return .failure(error)
            }
        }
        if draft.isUntouchedNewRecord {
            await discardIfUntouched(draft)
            return .success(.discarded(draft))
        }
        return .success(.none)
    }
}

/// "+" first leaves the open row, then creates the next one. A failed save
/// stops before `create`, so it cannot leave an untouched row behind.
enum TemplateAddFlow {
    static func perform(
        draft: NoteTemplate?, original: NoteTemplate?, hasChanges: Bool,
        save: (NoteTemplate) async throws -> Void,
        discardIfUntouched: (NoteTemplate) async -> Void,
        create: () async throws -> NoteTemplate
    ) async -> Result<(created: NoteTemplate, leave: TemplateDraftLeave.Outcome), Error> {
        let left = await TemplateDraftLeave.perform(
            draft: draft, original: original, hasChanges: hasChanges,
            save: save, discardIfUntouched: discardIfUntouched)
        switch left {
        case .failure(let error):
            return .failure(error)
        case .success(let outcome):
            do {
                return .success((try await create(), outcome))
            } catch {
                return .failure(error)
            }
        }
    }
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
    /// fixed heights of their own; only the footer note wraps with the text,
    /// and the 41 pt below the English content leaves room for the Greek.
    static let height: CGFloat = 786
    private static let listHeight: CGFloat = 148
    private static let contentHeight: CGFloat = 200

    private var hasChanges: Bool {
        draft != nil && draft != original
    }

    private var canSave: Bool {
        guard hasChanges, let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `draft` as it is stored when it is left rather than saved with the
    /// button: Save refuses an empty name, so leaving keeps the old one.
    private func leavingVersion(of draft: NoteTemplate) -> NoteTemplate {
        var out = draft
        if out.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let original {
            out.name = original.name
        }
        return out
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
        // Cards like the other panes. The list keeps its own selection and
        // arrow keys; only its chrome changes to sit inside the card.
        Form {
            Section {
                Picker("New notes start from", selection: defaultSelection) {
                    Text("A blank note").tag(String?.none)
                    ForEach(templates) { template in
                        Text(verbatim: DisplayCopy.title(template.name)).tag(String?.some(template.id))
                    }
                }
            }

            Section {
                List(selection: $selectedId) {
                    ForEach(templates) { template in
                        TemplateRow(template: template)
                            .tag(template.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: Self.listHeight)
                .accessibilityLabel("Templates")

                listButtons
            } header: {
                DetailSectionHeader(title: "Templates", systemImage: "doc.on.doc")
            }

            Section {
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

                if let failure {
                    Text(verbatim: failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                saveButtons
            } header: {
                DetailSectionHeader(title: "Template", systemImage: "pencil")
            } footer: {
                SettingsNote("{{date}}, {{time}} and {{patient}} are filled in when a template is inserted into a note. Built-in templates can be edited here and reset to their shipped copy; custom templates can be deleted.")
            }
        }
        .formStyle(.grouped)
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
            guard let shown = draft else { return }
            if hasChanges {
                let draft = leavingVersion(of: shown)
                Task {
                    guard (try? await actions.save(draft)) != nil else { return }
                    // The pane's state outlives a tab switch. Without this the
                    // saved edits still read as unsaved against `original`, and
                    // Revert would bring back the text from before them.
                    if self.draft?.id == draft.id { original = draft }
                    if let index = templates.firstIndex(where: { $0.id == draft.id }) {
                        templates[index] = draft
                    }
                }
            } else if shown.isUntouchedNewRecord {
                Task { await actions.discardIfUntouched(shown) }
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

    private var listButtons: some View {
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
    }

    private var saveButtons: some View {
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
            switch await TemplateDraftLeave.perform(
                draft: leaving, original: original, hasChanges: hasChanges,
                save: actions.save, discardIfUntouched: actions.discardIfUntouched) {
            case .failure(let error):
                failure = error.localizedDescription
                selectedId = leaving.id
                return
            case .success(let outcome):
                applyLeave(outcome)
            }
        }
        guard let current else {
            draft = nil
            original = nil
            return
        }
        showDraft(for: current)
    }

    private func applyLeave(_ outcome: TemplateDraftLeave.Outcome) {
        switch outcome {
        case .none:
            break
        case .saved(let saved):
            replace(saved)
        case .discarded(let gone):
            templates.removeAll { $0.id == gone.id }
        }
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
        switch await TemplateAddFlow.perform(
            draft: draft, original: original, hasChanges: hasChanges,
            save: actions.save, discardIfUntouched: actions.discardIfUntouched,
            create: actions.create) {
        case .failure(let error):
            failure = error.localizedDescription
        case .success(let result):
            applyLeave(result.leave)
            failure = nil
            templates.append(result.created)
            selectedId = result.created.id
            isNameFocused = true
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
