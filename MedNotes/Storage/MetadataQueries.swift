import Foundation

/// A tag as the Tags list shows it.
struct TagCount: Equatable, Sendable, Identifiable {
    /// `WikiLinkParser.normalizedKey` of the tag; what filters match on.
    let key: String
    /// The spelling used most often (ties: `localizedStandardCompare`).
    let display: String
    /// Notes carrying the tag or a tag nested under it (`cardio` counts
    /// `cardio/ward`).
    let count: Int

    var id: String { key }
}

struct PropertyKeyUsage: Equatable, Sendable, Identifiable {
    let key: String
    let kind: String
    let notes: Int
    /// A key used with two kinds is two entries.
    var id: String { "\(key)|\(kind)" }
}

struct AliasMatch: Equatable, Sendable {
    let noteId: UUID
    let title: String
    let alias: String
}

struct HeadingRow: Equatable, Sendable {
    let level: Int
    let text: String
    let offset: Int
}

extension Database {
    // MARK: - Tags

    /// Every note's tags from all three sources: `#tags` in the text, the
    /// `tags:` property (both derived), and the note's own tag field. A note
    /// counts once per tag however many sources name it, and under every
    /// ancestor of a nested tag. Read in one pass, so counts and filters from
    /// one call agree with each other.
    func tagIndex() throws -> (notesByKey: [String: Set<String>], spellings: [String: [String: Int]]) {
        var notesByKey: [String: Set<String>] = [:]
        var spellings: [String: [String: Int]] = [:]

        func add(_ text: String, key: String, note: String) {
            let keyParts = key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let textParts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !keyParts.isEmpty else { return }
            for depth in 1...keyParts.count {
                let ancestor = keyParts[0..<depth].joined(separator: "/")
                let spelling = textParts.isEmpty
                    ? ancestor : textParts[0..<min(depth, textParts.count)].joined(separator: "/")
                notesByKey[ancestor, default: []].insert(note)
                spellings[ancestor, default: [:]][spelling, default: 0] += 1
            }
        }

        let derived = try conn.prepare("SELECT note_id, tag, tag_key FROM note_tags")
        while try derived.step() {
            guard let note = derived.columnText(0), let tag = derived.columnText(1),
                  let key = derived.columnText(2) else { continue }
            add(tag, key: key, note: note)
        }
        derived.finalize()

        let field = try conn.prepare("SELECT id, tags_json FROM notes WHERE tags_json != '[]'")
        while try field.step() {
            guard let note = field.columnText(0), let json = field.columnText(1),
                  let data = json.data(using: .utf8),
                  let tags = try? JSONDecoder().decode([String].self, from: data) else { continue }
            for raw in tags {
                // The tag field stores what was typed, often with its #.
                var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                while text.hasPrefix("#") { text = text.dropFirst() }
                let key = WikiLinkParser.normalizedKey(String(text))
                if !key.isEmpty { add(String(text), key: key, note: note) }
            }
        }
        field.finalize()
        return (notesByKey, spellings)
    }

    func tagCounts() throws -> [TagCount] {
        let index = try tagIndex()
        return index.notesByKey.map { key, notes in
            let spelling = index.spellings[key] ?? [:]
            let display = spelling.max { lhs, rhs in
                lhs.value != rhs.value
                    ? lhs.value < rhs.value
                    : lhs.key.localizedStandardCompare(rhs.key) == .orderedDescending
            }?.key ?? key
            return TagCount(key: key, display: display, count: notes.count)
        }
        .sorted { $0.display.localizedStandardCompare($1.display) == .orderedAscending }
    }

    /// The notes carrying the tag, or any tag nested under it.
    func noteIDs(withTagKey key: String) throws -> Set<UUID> {
        let ids = try tagIndex().notesByKey[key] ?? []
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    /// The notes list for a search text and a tag filter, read together so
    /// the two agree. Both are optional.
    func notesFiltered(query: String?, tagKey: String?) throws -> [Note] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return try notesMatching(SearchQuery.parse(trimmed), tagKey: tagKey)
        }
        let base = try loadAllNotes()
        guard let tagKey, !tagKey.isEmpty else { return base }
        let ids = try noteIDs(withTagKey: tagKey)
        return base.filter { ids.contains($0.id) }
    }

    // MARK: - Headings, properties, aliases

    func headings(noteId: UUID) throws -> [HeadingRow] {
        let s = try conn.prepare("""
            SELECT level, text, start_offset FROM note_headings WHERE note_id = ? ORDER BY ordinal
            """)
        s.bind(1, noteId.uuidString)
        defer { s.finalize() }
        var out: [HeadingRow] = []
        while try s.step() {
            out.append(HeadingRow(level: s.columnInt(0) ?? 1, text: s.columnText(1) ?? "", offset: s.columnInt(2) ?? 0))
        }
        return out
    }

    /// Property names and kinds already in use, commonest first, for "Add property".
    func propertyKeys() throws -> [PropertyKeyUsage] {
        let s = try conn.prepare("""
            SELECT MIN(key), kind, COUNT(DISTINCT note_id) AS uses FROM note_properties
            WHERE kind NOT IN ('unsupported', 'empty')
            GROUP BY key_norm, kind ORDER BY uses DESC, MIN(key)
            """)
        defer { s.finalize() }
        var out: [PropertyKeyUsage] = []
        while try s.step() {
            out.append(PropertyKeyUsage(
                key: s.columnText(0) ?? "", kind: s.columnText(1) ?? "text", notes: s.columnInt(2) ?? 0))
        }
        return out
    }

    /// Notes with an alias that contains `key` (a normalized key), newest first.
    func aliasMatches(key: String, limit: Int) throws -> [AliasMatch] {
        guard !key.isEmpty else { return [] }
        let s = try conn.prepare("""
            SELECT n.id, n.title, a.alias FROM note_aliases a JOIN notes n ON n.id = a.note_id
            WHERE instr(a.alias_key, ?) > 0 ORDER BY n.updated_at DESC LIMIT ?
            """)
        s.bind(1, key)
        s.bind(2, limit)
        defer { s.finalize() }
        var out: [AliasMatch] = []
        while try s.step() {
            guard let id = s.columnText(0).flatMap(UUID.init(uuidString:)) else { continue }
            out.append(AliasMatch(noteId: id, title: s.columnText(1) ?? "", alias: s.columnText(2) ?? ""))
        }
        return out
    }

    func aliasKeys(noteId: UUID) throws -> [String] {
        let s = try conn.prepare("SELECT alias_key FROM note_aliases WHERE note_id = ? ORDER BY ordinal")
        s.bind(1, noteId.uuidString)
        defer { s.finalize() }
        var out: [String] = []
        while try s.step() { if let key = s.columnText(0) { out.append(key) } }
        return out
    }

    /// Whether a note has a heading (or, for a nested `A#H1#H2` reference,
    /// the last part of it) matching `reference`.
    func hasHeading(noteId: UUID, reference: String) throws -> Bool {
        var candidates = [WikiLinkParser.normalizedKey(reference)]
        if let last = reference.split(separator: "#").last {
            candidates.append(WikiLinkParser.normalizedKey(String(last)))
        }
        for key in candidates where !key.isEmpty {
            let s = try conn.prepare("SELECT 1 FROM note_headings WHERE note_id = ? AND key = ? LIMIT 1")
            s.bind(1, noteId.uuidString)
            s.bind(2, key)
            defer { s.finalize() }
            if try s.step() { return true }
        }
        return false
    }

    func hasBlock(noteId: UUID, id: String) throws -> Bool {
        let s = try conn.prepare("SELECT 1 FROM note_blocks WHERE note_id = ? AND block_id = ? LIMIT 1")
        s.bind(1, noteId.uuidString)
        s.bind(2, id)
        defer { s.finalize() }
        return try s.step()
    }
}
