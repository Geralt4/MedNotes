import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The notes list: loading, search, creating, saving, deleting and pinning.
extension AppSession {
    /// Refreshes the Tags menu: every tag in the store with its count.
    func reloadNoteTags() async {
        guard let store else { return }
        let counts = (try? await store.notes.tagCounts()) ?? []
        guard store === self.store else { return }
        noteTags = counts
        // A tag that no longer exists cannot filter anything.
        if let filter = noteTagFilter, !counts.contains(where: { $0.key == filter }) { noteTagFilter = nil }
    }

    func reload() async {
        guard let store else { return }
        notesReloadGeneration += 1
        let generation = notesReloadGeneration
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = noteTagFilter
            let result: [Note]
            let totalCount: Int?
            if query.isEmpty && tag == nil {
                result = try await store.notes.loadAll()
                totalCount = result.count
            } else {
                // The search text (with its operators) and the tag are read
                // together, so they agree. Quick open and `[[` completion use
                // the plain `search` instead.
                result = try await store.notes.list(search: query, tagKey: tag)
                totalCount = nil
            }
            // Snippets are made before the list changes, off the main actor,
            // so a row never shows a snippet of an older search.
            let terms = query.isEmpty ? [] : SearchQuery.parse(query).highlightTerms
            let snippets = terms.isEmpty ? [:] : await Self.snippets(for: result, terms: terms)
            guard generation == notesReloadGeneration else { return }
            if let totalCount { sidebarNoteCount = totalCount }
            noteSnippets = snippets
            notes = result
        } catch {
            guard generation == notesReloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func snippets(for notes: [Note], terms: [String]) async -> [UUID: SearchSnippet] {
        await Task.detached(priority: .userInitiated) {
            var out: [UUID: SearchSnippet] = [:]
            for note in notes {
                if let snippet = SearchSnippet.make(content: note.content, terms: terms) { out[note.id] = snippet }
            }
            return out
        }.value
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func newNote() async {
        guard let store else { return }
        var note = Note.newRecord()
        // A default template seeds the body; no patient is linked yet, so
        // {{patient}} renders as the placeholder dash.
        if let templateID = defaultNoteTemplateID,
           let template = (try? await store.templates.allTemplates())?.first(where: { $0.id == templateID }) {
            note.content = template.rendered(patientName: nil)
            seededNoteContent[note.id] = note.content
        }
        do {
            try await store.notes.save(note)
            await newNoteDidSave()
            // A lock that landed during the save has already torn the session
            // down: opening an editor now would mount one under the curtain,
            // and nothing would ever discard the untouched row just saved.
            guard canUseStore, self.store === store else {
                // The store is closing, so it cannot be asked to delete the row
                // now: it goes when the store next opens.
                notesAbandonedAtLock.insert(note.id)
                return
            }
            selectedNoteId = note.id
            pendingFocusRecordId = note.id
            noteEpoch += 1
            // Clear the text before cancelling so the didSet-scheduled
            // debounce task is the one that gets cancelled.
            if !searchText.isEmpty { searchText = "" }
            searchTask?.cancel()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            if await noteExists(id: note.id) == true {
                selectedNoteId = note.id
                pendingFocusRecordId = note.id
                if !searchText.isEmpty { searchText = "" }
                searchTask?.cancel()
            }
            noteEpoch += 1
            await reload()
        }
    }

    /// Removes the untouched "New Note" rows that a lock left behind: a note
    /// saved at the moment the session locked is never opened, so no editor will
    /// discard it. Runs when the store opens again.
    func discardNotesAbandonedAtLock() async {
        let ids = notesAbandonedAtLock
        notesAbandonedAtLock = []
        guard let store, !ids.isEmpty else { return }
        var removed = false
        for id in ids {
            guard let note = try? await store.notes.load(id: id), isUntouchedNewNote(note) else { continue }
            try? await store.notes.discard(id: id)
            seededNoteContent[id] = nil
            removed = true
        }
        if removed {
            noteEpoch += 1
            await reload()
        }
    }

    func select(_ noteId: UUID?) {
        selectedNoteId = noteId
    }

    @discardableResult
    func save(_ note: Note) async -> Bool {
        guard let store else { return false }
        do {
            try await store.notes.save(note)
            // Once the body is the user's own, the seed no longer matters.
            if seededNoteContent[note.id] != nil, !isUntouchedNewNote(note) {
                seededNoteContent[note.id] = nil
            }
            noteEpoch += 1
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            noteEpoch += 1
            await reload()
            return false
        }
    }

    func deleteNote(id: UUID) async {
        await removeNote(id: id, discarding: false)
    }

    /// Drops a note the user created and then left exactly as created, so an
    /// abandoned "+" never leaves a "New Note" row behind. The editor calls
    /// this on the way out; see `Note.isUntouchedNewRecord`.
    func discardIfUntouched(_ note: Note) async {
        guard isUntouchedNewNote(note),
              await noteExists(id: note.id) == true else { return }
        await removeNote(id: note.id, discarding: true)
        seededNoteContent[note.id] = nil
    }

    private func removeNote(id: UUID, discarding: Bool) async {
        guard let store else { return }
        do {
            if discarding {
                try await store.notes.discard(id: id)
            } else {
                try await store.notes.delete(id: id)
            }
            if selectedNoteId == id { selectedNoteId = nil }
            noteEpoch += 1
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            if selectedNoteId == id,
               await noteExists(id: id) == false {
                selectedNoteId = nil
            }
            noteEpoch += 1
            await reload()
        }
    }

    func deleteSelected() async {
        guard let id = selectedNoteId else { return }
        await deleteNote(id: id)
    }

    @discardableResult
    func togglePin(_ note: Note) async -> Bool {
        guard let store else { return false }
        do {
            try await store.notes.togglePin(id: note.id)
            noteEpoch += 1
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            noteEpoch += 1
            await reload()
            return false
        }
    }

    func loadSelectedNote() async -> Note? {
        guard let store, let id = selectedNoteId else { return nil }
        do {
            return try await store.notes.load(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tri-state: true/false = existence, nil = the lookup itself failed
    /// (error surfaced via errorMessage). Callers must compare explicitly so a
    /// transient store error is never mistaken for "does not exist".
    func noteExists(id: UUID) async -> Bool? {
        guard let store else { return nil }
        do {
            return try await store.notes.load(id: id) != nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
