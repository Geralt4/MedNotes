import Foundation

/// Wiki-style `[[links]]`: the editor's autocomplete helpers, and the stored
/// edge set (`wikilinks`) that backlinks and the graph read. Parsing is
/// `WikiLinkParser`; deriving and resolving the rows is `LinkIndex`. Pure
/// helpers are static so the rules are unit-testable without a database.
actor LinkingService {
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

    /// One distinct link out of a note, as its panel lists it: where it
    /// leads, or why it leads nowhere.
    struct OutgoingLink: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable {
            case note
            case patient
            /// No note or patient has this name.
            case unresolved
            /// Several notes or patients have this name.
            case ambiguous
        }
        let id: String
        let kind: Kind
        /// The title or name it resolves to; the link text when it does not.
        let label: String
        let targetID: UUID?
        /// The name as written between the brackets.
        let target: String
        let heading: String?
        let blockID: String?
        let isEmbed: Bool
        /// A resolved link whose `#heading` or `#^block` is not in the note it
        /// points at.
        var warning: Warning?

        enum Warning: String, Sendable {
            case missingHeading
            case missingBlock
        }

        /// Whether "create a note with this title" makes sense. A link such
        /// as `![[scan.png]]` names a file, not a note.
        var canCreateNote: Bool {
            kind == .unresolved && !LinkingService.namesAFile(target)
        }
    }

    /// How the notes are linked together: counts only resolved links between
    /// notes and to patients, and never a note's link to itself.
    struct LinkStats: Sendable, Equatable {
        /// Notes with no resolved link in or out.
        var orphans: [UUID] = []
        /// Notes that link to nothing.
        var deadEnds: [UUID] = []
        /// Distinct notes and patients linked from the note, plus distinct
        /// notes linking to it.
        var degree: [UUID: Int] = [:]
    }

    private static let fileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "bmp", "webp", "svg",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "rtf",
        "mp3", "m4a", "wav", "aac", "mp4", "mov", "m4v", "dcm",
    ]

    /// Whether a link target reads as a file name (`scan.png`), so it is
    /// never offered as a note to create.
    static func namesAFile(_ target: String) -> Bool {
        guard let dot = target.lastIndex(of: "."), dot != target.startIndex else { return false }
        return fileExtensions.contains(target[target.index(after: dot)...].lowercased())
    }

    static let openMarker = "[["
    static let closeMarker = "]]"

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    // MARK: - Extraction (pure)

    /// The names linked in a note, in order of appearance, each once: the
    /// target of every `[[...]]` that names something (a link to a heading of
    /// the note itself does not). Read through `WikiLinkParser`, so links in
    /// code and comments do not count.
    static func extractAnchors(from content: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for link in WikiLinkParser.scan(content).links where !link.isSameNote {
            guard seen.insert(WikiLinkParser.normalizedKey(link.target)).inserted else { continue }
            out.append(link.target)
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

    // MARK: - Persistence

    /// Derives the note's link rows from its saved text and resolves every
    /// link against the current notes and patients. All of it happens inside
    /// the database in one step (`LinkIndex`); see there for the rules.
    func relink(note: Note) async throws {
        try await db.relinkNote(id: note.id)
    }

    /// Resolves every stored link again: after anything that can change what
    /// a link names, such as a patient saved, renamed or archived.
    func reresolve() async throws {
        try await db.resolveAllLinks()
    }

    func backlinks(noteId: UUID) async throws -> [(noteId: UUID, title: String)] {
        try await db.backlinksForNote(noteId: noteId)
    }

    /// The notes and patients this note links to, resolved links only.
    func linksFrom(noteId: UUID) async throws -> [(label: String, kind: String)] {
        try await db.linksFromNote(noteId: noteId)
    }

    /// Every distinct link out of the note, resolved or not, in the order
    /// first written. Links to the note's own headings are left out.
    func outgoingLinks(noteId: UUID) async throws -> [OutgoingLink] {
        try await db.outgoingLinksFromNote(noteId: noteId)
    }

    /// Notes whose text names this note's title without linking to it. Text
    /// in code and comments, and in existing links, does not count; neither
    /// does a title shorter than three characters.
    func unlinkedMentions(noteId: UUID) async throws -> [(noteId: UUID, title: String)] {
        guard let note = try await db.loadNote(id: noteId) else { return [] }
        // The title and the aliases, each at least three characters.
        var keys = [WikiLinkParser.normalizedKey(note.title)]
        keys += try await db.aliasKeys(noteId: noteId)
        keys = keys.filter { $0.count >= 3 }
        guard !keys.isEmpty else { return [] }
        let linking = try await db.noteIDsLinking(to: noteId)
        var out: [(noteId: UUID, title: String)] = []
        for other in try await db.noteTexts() where other.id != noteId && !linking.contains(other.id) {
            if keys.contains(where: { Self.mentions($0, in: other.content) }) { out.append((other.id, other.title)) }
        }
        return out
    }

    func linkStats() async throws -> LinkStats {
        let ids = try await db.allNoteIDs()
        let edges = try await db.resolvedLinkEdges()
        var outgoing: [UUID: Set<String>] = [:]
        var incoming: [UUID: Set<UUID>] = [:]
        for edge in edges {
            outgoing[edge.source, default: []].insert(edge.destination)
            if let note = UUID(uuidString: edge.destination), edge.kind == LinkIndex.noteKind {
                incoming[note, default: []].insert(edge.source)
            }
        }
        var stats = LinkStats()
        for id in ids {
            let out = outgoing[id]?.count ?? 0
            let into = incoming[id]?.count ?? 0
            if out == 0 { stats.deadEnds.append(id) }
            if out == 0 && into == 0 { stats.orphans.append(id) }
            stats.degree[id] = out + into
        }
        return stats
    }

    /// Whether `key` (a normalized title) appears in `text` as a word or
    /// phrase of its own, outside code, comments and wiki-links.
    static func mentions(_ key: String, in text: String) -> Bool {
        let scan = WikiLinkParser.scan(text)
        let ns = text as NSString
        var skipped = scan.protectedRanges + scan.links.map(\.range)
        // Another note's `aliases:` line is not a mention of anything.
        if let properties = FrontMatter.properties(in: ns) { skipped.append(properties.range) }
        skipped.sort { $0.location < $1.location }
        var kept: [String] = []
        var cursor = 0
        for range in skipped {
            if range.location > cursor {
                kept.append(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < ns.length { kept.append(ns.substring(from: cursor)) }
        // Separated by a character that is neither a letter nor whitespace, so
        // a phrase cannot match across a skipped range.
        let folded = WikiLinkParser.normalizedKey(kept.joined(separator: "\u{1F}"))
        var from = folded.startIndex
        while from < folded.endIndex, let found = folded.range(of: key, range: from..<folded.endIndex) {
            let before = found.lowerBound == folded.startIndex ? nil : folded[folded.index(before: found.lowerBound)]
            let after = found.upperBound == folded.endIndex ? nil : folded[found.upperBound]
            let wordBefore = before.map { $0.isLetter || $0.isNumber } ?? false
            let wordAfter = after.map { $0.isLetter || $0.isNumber } ?? false
            if !wordBefore && !wordAfter { return true }
            from = folded.index(after: found.lowerBound)
        }
        return false
    }

    func graph() async throws -> GraphData {
        try await db.buildGraph()
    }
}

// MARK: - Database support

extension Database {
    func backlinksForNote(noteId: UUID) throws -> [(noteId: UUID, title: String)] {
        let s = try conn.prepare("""
            SELECT n.id, n.title FROM wikilinks w
            JOIN notes n ON n.id = w.src_note_id
            WHERE w.state = 'resolved' AND w.dst_kind = 'note' AND w.dst_id = ?
              AND w.src_note_id != w.dst_id
            GROUP BY n.id
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

    /// Where a note's resolved links lead, one entry per target in the order
    /// first linked. A link to the note itself is not listed.
    func linksFromNote(noteId: UUID) throws -> [(label: String, kind: String)] {
        let s = try conn.prepare("""
            SELECT w.dst_kind, COALESCE(n.title, TRIM(p.first_name || ' ' || p.last_name))
            FROM wikilinks w
            LEFT JOIN notes n ON w.dst_kind = 'note' AND n.id = w.dst_id
            LEFT JOIN patients p ON w.dst_kind = 'patient' AND p.id = w.dst_id
            WHERE w.src_note_id = ? AND w.state = 'resolved' AND w.dst_id != w.src_note_id
              AND (n.id IS NOT NULL OR p.id IS NOT NULL)
            GROUP BY w.dst_kind, w.dst_id
            ORDER BY MIN(w.ordinal)
            """)
        s.bind(1, noteId.uuidString)
        var out: [(String, String)] = []
        while try s.step() {
            out.append((s.columnText(1) ?? "", s.columnText(0) ?? "note"))
        }
        s.finalize()
        return out.map { ($0.0, $0.1) }
    }

    func outgoingLinksFromNote(noteId: UUID) throws -> [LinkingService.OutgoingLink] {
        let s = try conn.prepare("""
            SELECT w.state, w.dst_kind, w.dst_id, w.raw_target, w.target_key, w.heading, w.block_id,
                   w.is_embed, COALESCE(n.title, TRIM(p.first_name || ' ' || p.last_name))
            FROM wikilinks w
            LEFT JOIN notes n ON w.dst_kind = 'note' AND n.id = w.dst_id
            LEFT JOIN patients p ON w.dst_kind = 'patient' AND p.id = w.dst_id
            WHERE w.src_note_id = ? AND w.target_key != ''
            ORDER BY w.ordinal
            """)
        s.bind(1, noteId.uuidString)
        var position: [String: Int] = [:]
        var out: [LinkingService.OutgoingLink] = []
        while try s.step() {
            let state = s.columnText(0) ?? LinkIndex.unresolved
            let target = s.columnText(3) ?? ""
            let heading = s.columnText(5)
            let block = s.columnText(6)
            let kind: LinkingService.OutgoingLink.Kind
            var label = target
            var targetID: UUID?
            var warning: LinkingService.OutgoingLink.Warning?
            let identity: String
            if state == LinkIndex.resolved, let dst = s.columnText(2), dst != noteId.uuidString,
               let resolvedLabel = s.columnText(8) {
                kind = s.columnText(1) == LinkIndex.patientKind ? .patient : .note
                label = resolvedLabel
                targetID = UUID(uuidString: dst)
                identity = "r|\(dst)"
                // Checked per link, before the links to one destination are
                // merged: `[[A#H1]]` and `[[A#H2]]` are two questions.
                if kind == .note, let destination = targetID {
                    if let heading, !(try hasHeading(noteId: destination, reference: heading)) {
                        warning = .missingHeading
                    } else if let block, !(try hasBlock(noteId: destination, id: block)) {
                        warning = .missingBlock
                    }
                }
            } else if state == LinkIndex.resolved {
                continue   // to itself, or to something that is gone
            } else {
                kind = state == LinkIndex.ambiguous ? .ambiguous : .unresolved
                identity = "u|\(kind.rawValue)|\(s.columnText(4) ?? target)"
            }
            if let existing = position[identity] {
                if out[existing].warning == nil { out[existing].warning = warning }
                continue
            }
            position[identity] = out.count
            out.append(.init(
                id: identity, kind: kind, label: label, targetID: targetID, target: target,
                heading: heading, blockID: block, isEmbed: s.columnBool(7) ?? false, warning: warning))
        }
        s.finalize()
        return out
    }

    /// Notes with a resolved link to the note.
    func noteIDsLinking(to noteId: UUID) throws -> Set<UUID> {
        let s = try conn.prepare("""
            SELECT DISTINCT src_note_id FROM wikilinks
            WHERE state = 'resolved' AND dst_kind = 'note' AND dst_id = ?
            """)
        s.bind(1, noteId.uuidString)
        var out = Set<UUID>()
        while try s.step() {
            if let id = s.columnText(0).flatMap(UUID.init(uuidString:)) { out.insert(id) }
        }
        s.finalize()
        return out
    }

    /// Every note's id, title and text, newest first, for scans that read
    /// the text itself.
    func noteTexts() throws -> [(id: UUID, title: String, content: String)] {
        let s = try conn.prepare("SELECT id, title, content FROM notes ORDER BY updated_at DESC")
        var out: [(UUID, String, String)] = []
        while try s.step() {
            guard let id = s.columnText(0).flatMap(UUID.init(uuidString:)) else { continue }
            out.append((id, s.columnText(1) ?? "", s.columnText(2) ?? ""))
        }
        s.finalize()
        return out.map { ($0.0, $0.1, $0.2) }
    }

    func allNoteIDs() throws -> [UUID] {
        let s = try conn.prepare("SELECT id FROM notes")
        var out: [UUID] = []
        while try s.step() {
            if let id = s.columnText(0).flatMap(UUID.init(uuidString:)) { out.append(id) }
        }
        s.finalize()
        return out
    }

    /// Distinct resolved links between notes, and from notes to patients,
    /// never a note to itself.
    func resolvedLinkEdges() throws -> [(source: UUID, kind: String, destination: String)] {
        let s = try conn.prepare("""
            SELECT DISTINCT src_note_id, dst_kind, dst_id FROM wikilinks
            WHERE state = 'resolved' AND dst_id IS NOT NULL AND dst_id != src_note_id
            """)
        var out: [(UUID, String, String)] = []
        while try s.step() {
            guard let src = s.columnText(0).flatMap(UUID.init(uuidString:)),
                  let kind = s.columnText(1), let dst = s.columnText(2) else { continue }
            out.append((src, kind, dst))
        }
        s.finalize()
        return out.map { (source: $0.0, kind: $0.1, destination: $0.2) }
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

        let linkStmt = try conn.prepare("""
            SELECT DISTINCT src_note_id, dst_kind, dst_id FROM wikilinks
            WHERE state = 'resolved' AND dst_id IS NOT NULL AND dst_id != src_note_id
            """)
        while try linkStmt.step() {
            guard let src = linkStmt.columnText(0), let kind = linkStmt.columnText(1),
                  let dst = linkStmt.columnText(2) else { continue }
            data.edges.append(.init(sourceID: "n:\(src)", targetID: (kind == "patient" ? "p:" : "n:") + dst))
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
