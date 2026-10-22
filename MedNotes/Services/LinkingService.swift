import Foundation

/// Wiki-style `[[links]]`: extraction, resolution against notes/patients, and
/// the persisted edge set in `note_links`. Pure helpers are static so the
/// rules are unit-testable without a database.
actor LinkingService {
    struct ResolvedLink: Hashable, Sendable {
        enum Target: Hashable, Sendable {
            case note(UUID)
            case patient(UUID)
        }
        let target: Target
        let anchor: String
    }

    /// A flattened graph node. `kind` drives icon/tint in the graph UI.
    struct GraphNode: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable {
            case note
            case patient
            case event
        }
        let id: String
        let label: String
        let kind: Kind
    }

    struct GraphEdge: Hashable, Sendable {
        let sourceID: String
        let targetID: String
    }

    struct GraphData: Sendable {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
    }

    static let openMarker = "[["
    static let closeMarker = "]]"

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    // MARK: - Extraction (pure)

    /// Anchors inside [[...]] in order of appearance, deduplicated.
    static func extractAnchors(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: content, range: range) {
            guard let full = Range(match.range(at: 1), in: content) else { continue }
            let anchor = content[full].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !anchor.isEmpty, seen.insert(anchor.lowercased()).inserted else { continue }
            out.append(anchor)
        }
        return out
    }

    /// Longest text after "[[" that still counts as a link being typed.
    /// Past it the "[[" is taken for stray text, so a completion replaces at
    /// most this much of what the user wrote, and a link's closing "]]".
    static let maxOpenAnchorLength = 100

    /// How far back from the caret an open "[[" is looked for, in UTF-16
    /// units. A Character is rarely more than a few units, so this covers
    /// any query within `maxOpenAnchorLength`; a query of that many very
    /// wide Characters (family emoji) gets no popover. Keeps the lookup,
    /// which runs on every keystroke, off the length of a one-line paste.
    private static let anchorWindowUTF16 = 8 * (maxOpenAnchorLength + 2)

    /// Where a link completion goes: `range` of the note, in UTF-16 units as
    /// `NSTextView` counts them, becomes `replacement`.
    struct AnchorCompletion: Equatable, Sendable {
        let range: NSRange
        let replacement: String
    }

    /// The link being typed at `caret` — drives editor autocomplete.
    ///
    /// It is the text from the last "[[" before the caret on the caret's
    /// line up to the caret: nil when a "]]" closes it first, when it is
    /// longer than `maxOpenAnchorLength`, when the caret sits between the
    /// two brackets of a "[[" or "]]", or when the caret is outside the
    /// text. `caret` counts UTF-16 units, as `NSTextView.selectedRange()`.
    static func openAnchor(in text: String, caretUTF16 caret: Int) -> String? {
        let ns = text as NSString
        guard let query = anchorQuery(in: ns, caret: caret) else { return nil }
        return ns.substring(with: query).trimmingCharacters(in: .whitespaces)
    }

    /// The edit that completes the link at `caret` with `choice`.
    ///
    /// The typed query becomes `choice]]`; the rest of the line and of the
    /// note stay. With the caret inside a link already closed further along
    /// the line, the rest of that link goes too, so "[[Ward Ro|unds]]"
    /// becomes "[[choice]]" and not "[[choice]]unds]]".
    static func completion(in text: String, caretUTF16 caret: Int, choice: String) -> AnchorCompletion? {
        let ns = text as NSString
        guard let query = anchorQuery(in: ns, caret: caret) else { return nil }
        var end = caret
        let ahead = min(ns.length, caret + anchorWindowUTF16)
        let lineBreak = ns.rangeOfCharacter(from: .newlines, range: NSRange(location: caret, length: ahead - caret))
        let rest = NSRange(location: caret, length: (lineBreak.location == NSNotFound ? ahead : lineBreak.location) - caret)
        let close = ns.range(of: closeMarker, options: .literal, range: rest)
        if close.location != NSNotFound,
           ns.range(of: openMarker, options: .literal,
                    range: NSRange(location: caret, length: close.location - caret)).location == NSNotFound,
           isOpenQuery(ns.substring(with: NSRange(location: query.location, length: close.location - query.location))) {
            end = NSMaxRange(close)
        }
        return AnchorCompletion(
            range: NSRange(location: query.location, length: end - query.location),
            replacement: choice + closeMarker)
    }

    /// The link being typed at the very end of the note: the rule for when
    /// the editor cannot tell where the caret is. Only the note's last line
    /// can hold one, so a "[[" above existing text never makes the rest of
    /// the note the query.
    static func openAnchor(in text: String) -> String? {
        openAnchor(in: text, caretUTF16: (text as NSString).length)
    }

    /// Replaces the open anchor's text with the chosen completion (wrapped
    /// in closing brackets) and keeps everything after it.
    ///
    /// The anchor runs from the last "[[" to the end of its line. Text
    /// comes back unchanged when there is no anchor left to complete.
    static func complete(openAnchorText text: String, choice: String) -> String {
        guard let query = openAnchorQuery(in: text) else { return text }
        var completed = text
        completed.replaceSubrange(query, with: choice + closeMarker)
        return completed
    }

    /// The text between the last "[[" and the end of its line, when that
    /// "[[" is still open and short enough to be a link being typed.
    private static func openAnchorQuery(in text: String) -> Range<String.Index>? {
        guard let openRange = text.range(of: openMarker, options: [.backwards, .literal]) else { return nil }
        // One character past the limit is enough to reject a longer anchor,
        // so a long single-line paste is never scanned to its end.
        let ahead = text[openRange.upperBound...].prefix(maxOpenAnchorLength + 1)
        let query = openRange.upperBound..<(ahead.firstIndex(where: \.isNewline) ?? ahead.endIndex)
        return isOpenQuery(text[query]) ? query : nil
    }

    /// The query of the link open at `caret`, as a range of `text`.
    private static func anchorQuery(in text: NSString, caret: Int) -> NSRange? {
        guard caret >= 0, caret <= text.length, !caretSplitsMarker(in: text, at: caret) else { return nil }
        let windowStart = max(0, caret - anchorWindowUTF16)
        let open = text.range(
            of: openMarker, options: [.backwards, .literal],
            range: NSRange(location: windowStart, length: caret - windowStart))
        guard open.location != NSNotFound else { return nil }
        let query = NSRange(location: NSMaxRange(open), length: caret - NSMaxRange(open))
        // On the caret's own line, and still open.
        guard text.rangeOfCharacter(from: .newlines, range: query).location == NSNotFound else { return nil }
        return isOpenQuery(text.substring(with: query)) ? query : nil
    }

    /// The caret between the two brackets of a "]]" is past a closed link;
    /// between those of a "[[" it is before an opener, not inside one —
    /// unless a whole "[[" starts right at the caret. Completing there
    /// would leave a stray "]" or swallow the neighbouring link.
    private static func caretSplitsMarker(in text: NSString, at caret: Int) -> Bool {
        guard caret > 0, caret < text.length else { return false }
        let open = unichar(UInt8(ascii: "[")), close = unichar(UInt8(ascii: "]"))
        let before = text.character(at: caret - 1), after = text.character(at: caret)
        if before == close, after == close { return true }
        if before == open, after == open {
            return !(caret + 1 < text.length && text.character(at: caret + 1) == open)
        }
        return false
    }

    /// Whether text typed after "[[" is still a link being typed: nothing
    /// closes it, and it is short enough. Literal, like `extractAnchors`: a
    /// combining mark after a bracket must not hide a "]]".
    private static func isOpenQuery<S: StringProtocol>(_ typed: S) -> Bool {
        typed.range(of: closeMarker, options: .literal) == nil && typed.count <= maxOpenAnchorLength
    }

    // MARK: - Resolution (pure)

    /// Exact case-insensitive title match first; unique contains-match second.
    static func resolve(
        anchor: String,
        notes: [(id: UUID, title: String)],
        patients: [(id: UUID, displayName: String)]) -> ResolvedLink.Target? {
        let needle = anchor.lowercased()
        if let hit = notes.first(where: { $0.title.lowercased() == needle }) {
            return .note(hit.id)
        }
        if let hit = patients.first(where: { $0.displayName.lowercased() == needle }) {
            return .patient(hit.id)
        }
        let noteHits = notes.filter { $0.title.lowercased().contains(needle) && !needle.isEmpty }
        if noteHits.count == 1, let only = noteHits.first {
            return .note(only.id)
        }
        let patientHits = patients.filter { $0.displayName.lowercased().contains(needle) && !needle.isEmpty }
        if patientHits.count == 1, let only = patientHits.first {
            return .patient(only.id)
        }
        return nil
    }

    static func linkRowID(srcNoteID: UUID, target: ResolvedLink.Target) -> String {
        switch target {
        case .note(let id): return "\(srcNoteID.uuidString)->n:\(id.uuidString)"
        case .patient(let id): return "\(srcNoteID.uuidString)->p:\(id.uuidString)"
        }
    }

    // MARK: - Persistence

    /// Re-derives the outgoing link rows for a saved note. Safe to call after
    /// every save; diffs instead of blindly rewriting.
    func relink(note: Note) async throws {
        let anchors = Self.extractAnchors(from: note.content)
        let notes = try await db.noteDirectory()
        let patients = try await db.patientNameDirectory()
        var wanted: Set<String> = []
        var rowsToInsert: [(id: String, target: ResolvedLink.Target, anchor: String)] = []
        for anchor in anchors {
            guard let target = Self.resolve(anchor: anchor, notes: notes, patients: patients) else { continue }
            if case .note(let id) = target, id == note.id { continue }
            let rowID = Self.linkRowID(srcNoteID: note.id, target: target)
            guard wanted.insert(rowID).inserted else { continue }
            rowsToInsert.append((rowID, target, anchor))
        }
        try await db.replaceLinks(srcNoteId: note.id, keepIDs: wanted, rows: rowsToInsert)
    }

    func backlinks(noteId: UUID) async throws -> [(noteId: UUID, title: String)] {
        try await db.backlinksForNote(noteId: noteId)
    }

    func linksFrom(noteId: UUID) async throws -> [(label: String, kind: String)] {
        try await db.linksFromNote(noteId: noteId)
    }

    func graph() async throws -> GraphData {
        try await db.buildGraph()
    }
}

// MARK: - Database support

extension Database {
    struct NoteDirectoryEntry {
        let id: UUID
        let title: String
    }

    struct PatientDirectoryEntry {
        let id: UUID
        let displayName: String
    }

    func noteDirectory() throws -> [(id: UUID, title: String)] {
        let s = try conn.prepare("SELECT id, title FROM notes ORDER BY updated_at DESC")
        var out: [(UUID, String)] = []
        while try s.step() {
            guard let idStr = s.columnText(0), let id = UUID(uuidString: idStr) else { continue }
            out.append((id, s.columnText(1) ?? ""))
        }
        return out.map { ($0.0, $0.1) }
    }

    func patientNameDirectory() throws -> [(id: UUID, displayName: String)] {
        let s = try conn.prepare("SELECT id, first_name, last_name FROM patients")
        var out: [(id: UUID, displayName: String)] = []
        while try s.step() {
            guard let idStr = s.columnText(0), let id = UUID(uuidString: idStr) else { continue }
            let name = [s.columnText(1) ?? "", s.columnText(2) ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !name.isEmpty { out.append((id, name)) }
        }
        return out
    }

    func replaceLinks(
        srcNoteId: UUID,
        keepIDs: Set<String>,
        rows: [(id: String, target: LinkingService.ResolvedLink.Target, anchor: String)]) throws {
        try transaction {
            let existing = try conn.prepare("SELECT id FROM note_links WHERE src_note_id = ?")
            existing.bind(1, srcNoteId.uuidString)
            var have = Set<String>()
            while try existing.step() {
                if let rowID = existing.columnText(0) { have.insert(rowID) }
            }
            existing.finalize()

            let delete = try conn.prepare("DELETE FROM note_links WHERE id = ?")
            for rowID in have where !keepIDs.contains(rowID) {
                delete.reset()
                delete.bind(1, rowID)
                _ = try delete.step()
            }
            delete.finalize()

            let insert = try conn.prepare("""
                INSERT OR REPLACE INTO note_links (id, src_note_id, dst_note_id, dst_patient_id, anchor_text)
                VALUES (?, ?, ?, ?, ?)
                """)
            for row in rows {
                insert.reset()
                insert.bind(1, row.id)
                insert.bind(2, srcNoteId.uuidString)
                switch row.target {
                case .note(let id):
                    insert.bind(3, id.uuidString)
                    insert.bind(4, nil as String?)
                case .patient(let id):
                    insert.bind(3, nil as String?)
                    insert.bind(4, id.uuidString)
                }
                insert.bind(5, row.anchor)
                _ = try insert.step()
            }
            insert.finalize()
        }
    }

    func backlinksForNote(noteId: UUID) throws -> [(noteId: UUID, title: String)] {
        let s = try conn.prepare("""
            SELECT n.id, n.title FROM note_links l
            JOIN notes n ON n.id = l.src_note_id
            WHERE l.dst_note_id = ?
            ORDER BY n.updated_at DESC
            """)
        s.bind(1, noteId.uuidString)
        var out: [(UUID, String)] = []
        while try s.step() {
            guard let idStr = s.columnText(0), let id = UUID(uuidString: idStr) else { continue }
            out.append((id, s.columnText(1) ?? ""))
        }
        s.finalize()
        return out.map { ($0.0, $0.1) }
    }

    func linksFromNote(noteId: UUID) throws -> [(label: String, kind: String)] {
        let s = try conn.prepare("""
            SELECT l.dst_note_id, l.dst_patient_id, COALESCE(n.title, p.first_name || ' ' || p.last_name)
            FROM note_links l
            LEFT JOIN notes n ON n.id = l.dst_note_id
            LEFT JOIN patients p ON p.id = l.dst_patient_id
            WHERE l.src_note_id = ?
            """)
        s.bind(1, noteId.uuidString)
        var out: [(String, String)] = []
        while try s.step() {
            let label = s.columnText(2) ?? "(missing)"
            let kind = s.columnText(0) != nil ? "note" : "patient"
            out.append((label, kind))
        }
        s.finalize()
        return out.map { ($0.0, $0.1) }
    }

    func buildGraph() throws -> LinkingService.GraphData {
        var data = LinkingService.GraphData()

        let noteStmt = try conn.prepare("SELECT id, title FROM notes")
        while try noteStmt.step() {
            guard let idStr = noteStmt.columnText(0), UUID(uuidString: idStr) != nil else { continue }
            data.nodes.append(.init(id: "n:\(idStr)", label: noteStmt.columnText(1) ?? "", kind: .note))
        }
        noteStmt.finalize()

        let patientStmt = try conn.prepare("SELECT id, first_name, last_name FROM patients")
        while try patientStmt.step() {
            guard let idStr = patientStmt.columnText(0) else { continue }
            let name = [patientStmt.columnText(1) ?? "", patientStmt.columnText(2) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            data.nodes.append(.init(id: "p:\(idStr)", label: name, kind: .patient))
        }
        patientStmt.finalize()

        let eventStmt = try conn.prepare("SELECT id, title FROM calendar_events")
        while try eventStmt.step() {
            guard let idStr = eventStmt.columnText(0), let _ = UUID(uuidString: idStr) else { continue }
            data.nodes.append(.init(id: "e:\(idStr)", label: eventStmt.columnText(1) ?? "", kind: .event))
        }
        eventStmt.finalize()

        let linkStmt = try conn.prepare("SELECT src_note_id, dst_note_id, dst_patient_id FROM note_links")
        while try linkStmt.step() {
            guard let src = linkStmt.columnText(0) else { continue }
            if let dst = linkStmt.columnText(1) {
                data.edges.append(.init(sourceID: "n:\(src)", targetID: "n:\(dst)"))
            } else if let dstPatient = linkStmt.columnText(2) {
                data.edges.append(.init(sourceID: "n:\(src)", targetID: "p:\(dstPatient)"))
            }
        }
        linkStmt.finalize()

        let eventEdgeStmt = try conn.prepare(
            "SELECT id, patient_id FROM calendar_events WHERE patient_id IS NOT NULL")
        while try eventEdgeStmt.step() {
            guard let eid = eventEdgeStmt.columnText(0), let pid = eventEdgeStmt.columnText(1) else { continue }
            data.edges.append(.init(sourceID: "e:\(eid)", targetID: "p:\(pid)"))
        }
        eventEdgeStmt.finalize()

        let known = Set(data.nodes.map(\.id))
        data.edges = data.edges.filter { known.contains($0.sourceID) && known.contains($0.targetID) }
        data.nodes.sort { $0.kind.rawValue == $1.kind.rawValue ? $0.label < $1.label : $0.kind.rawValue < $1.kind.rawValue }
        return data
    }

    // MARK: Templates storage

    func customTemplates() throws -> [NoteTemplate] {
        let s = try conn.prepare("SELECT id, name, kind, content FROM note_templates ORDER BY name")
        var out: [NoteTemplate] = []
        while try s.step() {
            out.append(NoteTemplate(
                id: s.columnText(0) ?? "",
                name: s.columnText(1) ?? "",
                kind: TemplateKind.parse(s.columnText(2) ?? ""),
                content: s.columnText(3) ?? ""))
        }
        s.finalize()
        return out
    }

    func saveTemplate(_ template: NoteTemplate) throws {
        let s = try conn.prepare("""
            INSERT INTO note_templates (id, name, kind, content)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, kind=excluded.kind, content=excluded.content,
                updated_at=(strftime('%Y-%m-%dT%H:%M:%f','now'))
            """)
        s.bind(1, template.id)
        s.bind(2, template.name)
        s.bind(3, template.kind.rawValue)
        s.bind(4, template.content)
        _ = try s.step()
        s.finalize()
    }

    func deleteTemplate(id: String) throws {
        let s = try conn.prepare("DELETE FROM note_templates WHERE id = ?")
        s.bind(1, id)
        _ = try s.step()
        s.finalize()
    }
}
