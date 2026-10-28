import Foundation

/// Writes the derived note metadata (`note_headings`, `note_blocks`,
/// `note_tags`, `note_aliases`, `note_properties`) for one note, in the
/// caller's transaction. Everything is replaced, nothing patched: the rows are
/// a function of the note's text.
///
/// Errors thrown here never carry property, tag or heading text: they come
/// from SQLite with the statement text only.
enum MetadataIndex {
    static let inline = "inline"
    static let property = "property"

    static func write(_ conn: SQLConnection, noteID: String, scan: NoteMetadata.Scan) throws {
        try clear(conn, noteID: noteID)

        let heading = try conn.prepare("""
            INSERT INTO note_headings (note_id, ordinal, level, text, key, start_offset)
            VALUES (?,?,?,?,?,?)
            """)
        for (ordinal, item) in scan.headings.enumerated() {
            heading.reset()
            heading.bind(1, noteID)
            heading.bind(2, ordinal)
            heading.bind(3, item.level)
            heading.bind(4, item.text)
            heading.bind(5, item.key)
            heading.bind(6, item.offset)
            _ = try heading.step()
        }
        heading.finalize()

        let block = try conn.prepare("""
            INSERT OR REPLACE INTO note_blocks (note_id, block_id, start_offset) VALUES (?,?,?)
            """)
        for item in scan.blocks {
            block.reset()
            block.bind(1, noteID)
            block.bind(2, item.id)
            block.bind(3, item.offset)
            _ = try block.step()
        }
        block.finalize()

        let tag = try conn.prepare("""
            INSERT INTO note_tags (note_id, ordinal, tag, tag_key, source, start_offset)
            VALUES (?,?,?,?,?,?)
            """)
        var ordinal = 0
        func addTag(_ text: String, source: String, offset: Int?) throws {
            let key = WikiLinkParser.normalizedKey(text)
            guard !key.isEmpty else { return }
            tag.reset()
            tag.bind(1, noteID)
            tag.bind(2, ordinal)
            tag.bind(3, text)
            tag.bind(4, key)
            tag.bind(5, source)
            tag.bind(6, offset)
            _ = try tag.step()
            ordinal += 1
        }
        for item in scan.tags { try addTag(item.tag, source: inline, offset: item.range.location) }
        for item in propertyList("tags", in: scan) { try addTag(stripHash(item), source: property, offset: nil) }
        tag.finalize()

        let alias = try conn.prepare("""
            INSERT INTO note_aliases (note_id, ordinal, alias, alias_key) VALUES (?,?,?,?)
            """)
        var aliasOrdinal = 0
        for item in propertyList("aliases", in: scan) + propertyList("alias", in: scan) {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = WikiLinkParser.normalizedKey(trimmed)
            guard !key.isEmpty else { continue }
            alias.reset()
            alias.bind(1, noteID)
            alias.bind(2, aliasOrdinal)
            alias.bind(3, trimmed)
            alias.bind(4, key)
            _ = try alias.step()
            aliasOrdinal += 1
        }
        alias.finalize()

        let prop = try conn.prepare("""
            INSERT INTO note_properties (note_id, ordinal, key, key_norm, kind, text_value, number_value, list_json)
            VALUES (?,?,?,?,?,?,?,?)
            """)
        for (index, item) in (scan.properties?.properties ?? []).enumerated() {
            prop.reset()
            prop.bind(1, noteID)
            prop.bind(2, index)
            prop.bind(3, item.key)
            prop.bind(4, item.keyNorm)
            prop.bind(5, item.value.kind)
            var text: String?
            var number: Double?
            var list: String?
            switch item.value {
            case .text(let s), .date(let s), .dateTime(let s): text = s
            case .number(let s): text = s; number = Double(s)
            case .checkbox(let b): text = b ? "true" : "false"
            case .list(let items):
                list = (try? JSONSerialization.data(withJSONObject: items))
                    .flatMap { String(data: $0, encoding: .utf8) }
            case .empty, .unsupported: break
            }
            prop.bind(6, text)
            if let number { prop.bind(7, number) } else { prop.bind(7, nil as String?) }
            prop.bind(8, list)
            _ = try prop.step()
        }
        prop.finalize()
    }

    static func clear(_ conn: SQLConnection, noteID: String) throws {
        for table in ["note_headings", "note_blocks", "note_tags", "note_aliases", "note_properties"] {
            let delete = try conn.prepare("DELETE FROM \(table) WHERE note_id = ?")
            delete.bind(1, noteID)
            _ = try delete.step()
            delete.finalize()
        }
    }

    // MARK: - Helpers

    /// The items of a list-valued property (`tags`, `aliases`).
    private static func propertyList(_ key: String, in scan: NoteMetadata.Scan) -> [String] {
        guard let set = scan.properties else { return [] }
        var out: [String] = []
        for item in set.properties where item.keyNorm == key {
            if case .list(let items) = item.value { out += items }
        }
        return out
    }

    private static func stripHash(_ item: String) -> String {
        var s = Substring(item.trimmingCharacters(in: .whitespacesAndNewlines))
        while s.hasPrefix("#") { s = s.dropFirst() }
        return String(s)
    }
}
