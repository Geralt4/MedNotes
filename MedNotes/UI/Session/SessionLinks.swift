import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Links and backlinks of the open note, link completion, and jumping to a record.
extension AppSession {
    // MARK: - Wiki-links & graph data

    struct LinkCandidate: Identifiable, Hashable {
        enum Kind: Hashable {
            case note
            case patient
        }
        let id: UUID
        /// What the popover shows.
        let title: String
        let kind: Kind
        /// What completing writes between the brackets: the title, or
        /// `Title|alias` for a note found by one of its aliases.
        let insert: String

        init(id: UUID, title: String, kind: Kind, insert: String? = nil) {
            self.id = id
            self.title = title
            self.kind = kind
            self.insert = insert ?? title
        }
    }

    /// Completions for an open `[[` anchor, over the whole store rather than
    /// the list column's current load: notes whose title starts with the
    /// text, then titles containing it, then bodies mentioning it, then
    /// patients by name. An empty anchor offers the notes touched most
    /// recently; one character is too little to ask.
    func linkCandidates(anchor: String, excluding noteId: UUID?) async -> [LinkCandidate] {
        guard let store else { return [] }
        let query = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if query.isEmpty {
                return try await store.notes.loadAll()
                    .filter { $0.id != noteId && !Self.isUntitled($0) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(6)
                    .map { LinkCandidate(id: $0.id, title: DisplayCopy.title($0.title), kind: .note) }
            }
            guard query.count >= 2 else { return [] }
            let lowered = WikiLinkParser.normalizedKey(query)
            let notes = try await store.notes.search(query, limit: 12)
                .filter { $0.id != noteId && !Self.isUntitled($0) }
            let ranked = notes.enumerated()
                .sorted { lhs, rhs in
                    let l = Self.linkRank(title: lhs.element.title, query: lowered)
                    let r = Self.linkRank(title: rhs.element.title, query: lowered)
                    return l == r ? lhs.offset < rhs.offset : l < r
                }
                .map(\.element)
            var out = ranked.prefix(4).map {
                LinkCandidate(id: $0.id, title: DisplayCopy.title($0.title), kind: .note)
            }
            // A note found by an alias is shown as "alias — Title" and written
            // `Title|alias`, so the link names the note and reads as the alias.
            // When the alias is why the note matches (its title does not
            // contain the text), that form replaces the plain title.
            let queryKey = WikiLinkParser.normalizedKey(query)
            let aliasHits = (try? await store.notes.aliasMatches(query, limit: 4)) ?? []
            var aliasCandidates: [LinkCandidate] = []
            for hit in aliasHits where hit.noteId != noteId
                && !hit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidate = LinkCandidate(
                    id: hit.noteId, title: "\(hit.alias) — \(DisplayCopy.title(hit.title))", kind: .note,
                    insert: "\(hit.title)|\(hit.alias)")
                if let index = out.firstIndex(where: { $0.id == hit.noteId }) {
                    if !WikiLinkParser.normalizedKey(hit.title).contains(queryKey) { out[index] = candidate }
                } else if aliasCandidates.count < 2 {
                    aliasCandidates.append(candidate)
                }
            }
            out += aliasCandidates
            let patients = try await store.patients.search(query, limit: 5)
            out += patients.prefix(3).map {
                LinkCandidate(id: $0.id, title: DisplayCopy.patient($0), kind: .patient)
            }
            return Array(out.prefix(6))
        } catch {
            return []
        }
    }

    /// A note with a blank title is nothing a link can name, so it is never
    /// offered as a completion (the list would show it as "Untitled").
    private static func isUntitled(_ note: Note) -> Bool {
        note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 0 = the title starts with the text, 1 = contains it, 2 = body only.
    private static func linkRank(title: String, query: String) -> Int {
        // `query` is already folded (`WikiLinkParser.normalizedKey`).
        let folded = WikiLinkParser.normalizedKey(title)
        if folded.hasPrefix(query) { return 0 }
        if folded.contains(query) { return 1 }
        return 2
    }

    func refreshLinks(noteId: UUID) async {
        guard let store else { return }
        var incoming: [(noteId: UUID, title: String)] = []
        var outgoing: [LinkingService.OutgoingLink] = []
        do {
            incoming = try await store.linking.backlinks(noteId: noteId)
            outgoing = try await store.linking.outgoingLinks(noteId: noteId)
        } catch {
            incoming = []
            outgoing = []
        }
        // A lock may have come in while the links were read.
        guard store === self.store else { return }
        backlinks = incoming
        linksOut = outgoing
    }

    /// Notes that name this note's title without linking to it. Read apart
    /// from `refreshLinks`: it scans every note's text, so the panel asks for
    /// it only while it is open.
    func refreshUnlinkedMentions(noteId: UUID) async {
        guard let store else { return }
        let found = (try? await store.linking.unlinkedMentions(noteId: noteId)) ?? []
        guard selectedNoteId == noteId else { return }
        unlinkedMentions = found
        unlinkedMentionsNoteId = noteId
    }

    /// Creates a note titled with an unresolved link's text and opens it. The
    /// save links the note that asked for it to the new one.
    func createNoteFromLink(_ target: String) async {
        guard let store, canUseStore else { return }
        let title = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var note = Note.newRecord()
        note.title = title
        do {
            try await store.notes.save(note)
            await revealNote(note.id)
            guard canUseStore else { return }
            pendingFocusRecordId = note.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func jumpToNote(_ noteId: UUID) async {
        await revealNote(noteId)
    }

    /// Opens a patient from elsewhere (an event's linked patient), revealing
    /// it even when the patient list's search or filter would hide it.
    func jumpToPatient(_ patientId: UUID) async {
        await revealPatient(patientId)
    }
}
