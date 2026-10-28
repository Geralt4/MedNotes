import Foundation

/// Answers a parsed `SearchQuery` over the notes. Every leaf becomes a set of
/// note ids, and AND, OR and NOT are plain set algebra; the order of the
/// result is the notes list's own (pinned first, then newest).
///
/// The full-text index is only ever given `SearchQuery.matchString`, which is
/// quoted letters and digits, so no typed text can make FTS5 reject a query.
extension Database {
    /// Notes matching `query`, optionally also carrying the tag `tagKey` (or
    /// a tag nested under it). Returns `[]` when the query holds nothing
    /// searchable.
    func notesMatching(_ query: SearchQuery, tagKey: String? = nil) throws -> [Note] {
        guard let root = query.root else { return [] }
        var context = SearchContext()
        var ids = try evaluate(root, &context)
        if let tagKey, !tagKey.isEmpty {
            ids.formIntersection(try tagNotes(&context)[tagKey] ?? [])
        }
        guard !ids.isEmpty else { return [] }

        let s = try conn.prepare("""
            SELECT id, title, content, created_at, updated_at, tags_json,
                   mentioned_patients_json, is_pinned
            FROM notes
            ORDER BY is_pinned DESC, updated_at DESC
            """)
        defer { s.finalize() }
        var out: [Note] = []
        while try s.step() {
            // Only the id is read until the row is known to match.
            guard let id = s.columnText(0), ids.contains(id) else { continue }
            if let note = try decodeNote(s) { out.append(note) }
        }
        return out
    }

    /// The ids (as stored) of the notes matching `query`, in no particular
    /// order and without reading their text: what the graph's filter and
    /// colour groups need.
    func noteIDs(matching query: SearchQuery) throws -> Set<String> {
        guard let root = query.root else { return [] }
        var context = SearchContext()
        return try evaluate(root, &context)
    }

    // MARK: - Evaluation

    /// Things read at most once per search, and only if a leaf needs them.
    fileprivate struct SearchContext {
        var everyNote: Set<String>?
        var tagNotes: [String: Set<String>]?
    }

    private func allNoteIDs(_ context: inout SearchContext) throws -> Set<String> {
        if let known = context.everyNote { return known }
        let s = try conn.prepare("SELECT id FROM notes")
        defer { s.finalize() }
        var ids = Set<String>()
        while try s.step() { if let id = s.columnText(0) { ids.insert(id) } }
        context.everyNote = ids
        return ids
    }

    private func tagNotes(_ context: inout SearchContext) throws -> [String: Set<String>] {
        if let known = context.tagNotes { return known }
        let index = try tagIndex().notesByKey
        context.tagNotes = index
        return index
    }

    private func evaluate(_ node: SearchQuery.Node, _ context: inout SearchContext) throws -> Set<String> {
        switch node {
        case .and(let items):
            var result: Set<String>?
            for item in items {
                let ids = try evaluate(item, &context)
                result = result.map { $0.intersection(ids) } ?? ids
                if result?.isEmpty == true { return [] }   // nothing left to narrow
            }
            return result ?? []
        case .or(let items):
            var result = Set<String>()
            for item in items { result.formUnion(try evaluate(item, &context)) }
            return result
        case .not(let inner):
            let excluded = try evaluate(inner, &context)
            return try allNoteIDs(&context).subtracting(excluded)
        case .word(let token):
            return try textMatches(tokens: [token], prefix: true)
        case .phrase(let tokens, let prefix):
            return try textMatches(tokens: tokens, prefix: prefix)
        case .tag(let key):
            return try tagNotes(&context)[key] ?? []
        case .property(let key, let value):
            return try propertyMatches(key: key, value: value)
        case .patient(let tokens):
            return try patientMatches(tokens: tokens)
        case .linked(let key):
            return try linkedMatches(key: key)
        }
    }

    /// A word or phrase in a note's text, title or tag field, or in the name
    /// of a patient the note is about (every token of the leaf must match
    /// that patient, as in the plain search).
    private func textMatches(tokens: [String], prefix: Bool) throws -> Set<String> {
        guard let match = SearchQuery.matchString(tokens: tokens, prefix: prefix) else { return [] }
        var ids = Set<String>()

        let fts = try conn.prepare("SELECT id FROM notes_fts WHERE notes_fts MATCH ?")
        defer { fts.finalize() }
        fts.bind(1, match)
        while try fts.step() { if let id = fts.columnText(0) { ids.insert(id) } }

        let patientTokens = tokens.flatMap { Schema.splitTokens($0) }
        guard !patientTokens.isEmpty else { return ids }
        let viaPatient = try conn.prepare("""
            SELECT note_id FROM patient_notes
            WHERE patient_id IN (SELECT id FROM patients WHERE \(Self.patientClause(count: patientTokens.count)))
            """)
        defer { viaPatient.finalize() }
        var index: Int32 = 1
        Self.bindPatientTokens(viaPatient, patientTokens, &index)
        while try viaPatient.step() { if let id = viaPatient.columnText(0) { ids.insert(id) } }
        return ids
    }

    /// Notes about a patient whose name matches every token: those that
    /// mention the patient, and those with a link that resolves to them.
    /// Archived patients count.
    private func patientMatches(tokens: [String]) throws -> Set<String> {
        guard !tokens.isEmpty else { return [] }
        let clause = Self.patientClause(count: tokens.count)
        let s = try conn.prepare("""
            SELECT note_id FROM patient_notes
            WHERE patient_id IN (SELECT id FROM patients WHERE \(clause))
            UNION
            SELECT src_note_id FROM wikilinks
            WHERE dst_kind = 'patient' AND state = 'resolved'
              AND dst_id IN (SELECT id FROM patients WHERE \(clause))
            """)
        defer { s.finalize() }
        var index: Int32 = 1
        Self.bindPatientTokens(s, tokens, &index)
        Self.bindPatientTokens(s, tokens, &index)
        var ids = Set<String>()
        while try s.step() { if let id = s.columnText(0) { ids.insert(id) } }
        return ids
    }

    /// Notes with a link written as `key`, whether or not it resolves. A
    /// link keeps its destination only while the written key still names it,
    /// so the written key is what a resolved link was matched on too.
    private func linkedMatches(key: String) throws -> Set<String> {
        let s = try conn.prepare("""
            SELECT DISTINCT src_note_id FROM wikilinks
            WHERE target_key = ?1 OR inner_key = ?1 OR head_key = ?1
            """)
        defer { s.finalize() }
        s.bind(1, key)
        var ids = Set<String>()
        while try s.step() { if let id = s.columnText(0) { ids.insert(id) } }
        return ids
    }

    /// Notes with the property `key` and, when given, a value that equals
    /// `value` or holds it as whole words (text, number, date or a list item).
    /// Keys and values compare with `WikiLinkParser.normalizedKey`, which
    /// folds more than the stored `key_norm`.
    private func propertyMatches(key: String, value: String?) throws -> Set<String> {
        let s = try conn.prepare("SELECT note_id, key_norm, text_value, list_json FROM note_properties")
        defer { s.finalize() }
        var keyMatches: [String: Bool] = [:]
        let wanted = value.map { Schema.splitTokens($0) } ?? []
        var ids = Set<String>()
        while try s.step() {
            guard let note = s.columnText(0), let stored = s.columnText(1) else { continue }
            if ids.contains(note) { continue }
            let isKey: Bool
            if let known = keyMatches[stored] {
                isKey = known
            } else {
                isKey = WikiLinkParser.normalizedKey(stored) == key
                keyMatches[stored] = isKey
            }
            guard isKey else { continue }
            if value == nil || wanted.isEmpty { ids.insert(note); continue }

            var candidates: [String] = []
            if let text = s.columnText(2) { candidates.append(text) }
            if let json = s.columnText(3), let data = json.data(using: .utf8),
               let items = try? JSONDecoder().decode([String].self, from: data) {
                candidates.append(contentsOf: items)
            }
            if candidates.contains(where: { Self.holds($0, words: wanted) }) { ids.insert(note) }
        }
        return ids
    }

    /// `words` (already tokens) appear in `text` next to each other, in order.
    private static func holds(_ text: String, words: [String]) -> Bool {
        let have = Schema.splitTokens(WikiLinkParser.normalizedKey(text))
        let want = words.map { WikiLinkParser.normalizedKey($0) }
        guard !want.isEmpty, have.count >= want.count else { return false }
        for start in 0...(have.count - want.count) where Array(have[start..<(start + want.count)]) == want {
            return true
        }
        return false
    }

    // MARK: - Patient name clauses (the plain search's own)

    private static func patientClause(count: Int) -> String {
        (0..<count).map { _ in
            """
            (id IN (SELECT id FROM patients_fts WHERE patients_fts MATCH ?)
             OR instr(\(GreekFold.sql("ifnull(fathers_name, '')")), ?) > 0)
            """
        }.joined(separator: " AND ")
    }

    private static func bindPatientTokens(_ s: Statement, _ tokens: [String], _ index: inout Int32) {
        for token in tokens {
            s.bind(index, Schema.ftsQuery(token))
            index += 1
            s.bind(index, GreekFold.fold(token))
            index += 1
        }
    }
}
