import CryptoKit
import Foundation

/// Derives the stored wiki-link edges (`wikilinks`, `link_sources`) from note
/// text. Everything here is a function of the notes and patients tables, so
/// the index can be thrown away and rebuilt, and every function is safe to
/// repeat.
///
/// All of it runs on a `SQLConnection` inside the caller's transaction (or
/// its own savepoint), with no suspension point between reading the index and
/// writing the rows, so two overlapping saves cannot leave an edge resolved
/// against a stale view.
enum LinkIndex {
    static let resolved = "resolved"
    static let unresolved = "unresolved"
    static let ambiguous = "ambiguous"
    static let noteKind = "note"
    static let patientKind = "patient"

    /// A migration marker: the link tables were first derived on this store.
    static let derivedMarker = "5.1-links-derived"

    struct Counts: Equatable, Sendable {
        var notes = 0
        var links = 0
        var unresolved = 0
        var ambiguous = 0
        /// Notes whose rows were derived again by this pass.
        var derivedNotes = 0
        /// Notes whose derivation failed; their rows stay stale and are tried
        /// again on the next open.
        var failedNotes = 0
    }

    /// Stored with each note's rows; a note whose version is older is derived
    /// again. Moves whenever the link rules or the metadata rules do.
    static var derivationVersion: Int { WikiLinkParser.version + NoteMetadata.version }

    #if DEBUG
    /// Test seam: derivation of a note fails when this returns true for its id.
    nonisolated(unsafe) static var failDerivationForTesting: ((String) -> Bool)?
    #endif

    struct Resolution: Equatable {
        var state: String
        var kind: String?
        var id: String?
    }

    /// Titles and patient names by normalized key. Ids are the stored text.
    struct Index {
        var noteIDsByKey: [String: [String]] = [:]
        var patientIDsByKey: [String: [String]] = [:]
        var noteKeyByID: [String: String] = [:]
        var patientKeysByID: [String: Set<String>] = [:]
    }

    // MARK: - Resolution

    static func buildIndex(_ conn: SQLConnection) throws -> Index {
        var index = Index()
        let notes = try conn.prepare("SELECT id, title FROM notes")
        while try notes.step() {
            guard let id = notes.columnText(0) else { continue }
            let key = WikiLinkParser.normalizedKey(notes.columnText(1) ?? "")
            // An untitled note is nothing a link can name.
            guard !key.isEmpty else { continue }
            index.noteIDsByKey[key, default: []].append(id)
            index.noteKeyByID[id] = key
        }
        notes.finalize()

        let patients = try conn.prepare("SELECT id, first_name, last_name FROM patients")
        while try patients.step() {
            guard let id = patients.columnText(0) else { continue }
            let first = (patients.columnText(1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let last = (patients.columnText(2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var keys = Set<String>()
            for parts in [[first, last], [last, first]] {
                let key = WikiLinkParser.normalizedKey(parts.filter { !$0.isEmpty }.joined(separator: " "))
                if !key.isEmpty { keys.insert(key) }
            }
            for key in keys { index.patientIDsByKey[key, default: []].append(id) }
            index.patientKeysByID[id] = keys
        }
        patients.finalize()
        return index
    }

    /// Where one link points.
    ///
    /// A link keeps its current destination for as long as that destination
    /// still exists and its title still has the link's key, so creating a
    /// second note with the same title never breaks a working link. Otherwise
    /// the whole text between the brackets is tried as a title first (a note
    /// called "Plan #2"), then the target alone; notes come before patients;
    /// exactly one candidate resolves, none leaves it unresolved, several
    /// make it ambiguous.
    static func resolve(
        innerKey: String, headKey: String = "", targetKey: String, sourceID: String,
        current: (kind: String, id: String)?, index: Index
    ) -> Resolution {
        if targetKey.isEmpty {
            return Resolution(state: resolved, kind: noteKind, id: sourceID)
        }
        // The whole text first (a note called "Plan #2|x"), then the text
        // before the alias (`[[Plan #2|see]]` names "Plan #2"), then the
        // target alone.
        var keys: [String] = []
        for key in [innerKey, headKey, targetKey] where !key.isEmpty && !keys.contains(key) { keys.append(key) }

        if let current {
            let stillValid: Bool
            switch current.kind {
            case noteKind:
                stillValid = index.noteKeyByID[current.id].map(keys.contains) ?? false
            case patientKind:
                stillValid = !(index.patientKeysByID[current.id] ?? []).isDisjoint(with: keys)
            default:
                stillValid = false
            }
            if stillValid { return Resolution(state: resolved, kind: current.kind, id: current.id) }
        }
        for key in keys {
            if let ids = index.noteIDsByKey[key] {
                return ids.count == 1
                    ? Resolution(state: resolved, kind: noteKind, id: ids[0])
                    : Resolution(state: ambiguous, kind: nil, id: nil)
            }
            if let ids = index.patientIDsByKey[key] {
                return ids.count == 1
                    ? Resolution(state: resolved, kind: patientKind, id: ids[0])
                    : Resolution(state: ambiguous, kind: nil, id: nil)
            }
        }
        return Resolution(state: unresolved, kind: nil, id: nil)
    }

    /// Resolves every stored link against the current notes and patients.
    static func resolveAll(_ conn: SQLConnection) throws {
        try withSavepoint(conn) {
            let index = try buildIndex(conn)
            let rows = try conn.prepare("""
                SELECT id, src_note_id, inner_key, target_key, state, dst_kind, dst_id, head_key FROM wikilinks
                """)
            var changes: [(id: String, resolution: Resolution)] = []
            while try rows.step() {
                guard let id = rows.columnText(0), let source = rows.columnText(1) else { continue }
                var current: (kind: String, id: String)?
                if let kind = rows.columnText(5), let dst = rows.columnText(6) { current = (kind, dst) }
                let now = resolve(
                    innerKey: rows.columnText(2) ?? "", headKey: rows.columnText(7) ?? "",
                    targetKey: rows.columnText(3) ?? "",
                    sourceID: source, current: current, index: index)
                let before = Resolution(
                    state: rows.columnText(4) ?? unresolved, kind: current?.kind, id: current?.id)
                if now != before { changes.append((id, now)) }
            }
            rows.finalize()
            guard !changes.isEmpty else { return }
            let update = try conn.prepare("UPDATE wikilinks SET state = ?, dst_kind = ?, dst_id = ? WHERE id = ?")
            for change in changes {
                update.reset()
                update.bind(1, change.resolution.state)
                update.bind(2, change.resolution.kind)
                update.bind(3, change.resolution.id)
                update.bind(4, change.id)
                _ = try update.step()
            }
            update.finalize()
        }
    }

    // MARK: - Deriving rows

    static func contentHash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Derives one note's rows from its current text, then resolves every
    /// link (a note's own title may be what another note links to).
    static func relink(_ conn: SQLConnection, noteID: String) throws {
        try withSavepoint(conn) {
            let note = try conn.prepare("SELECT content FROM notes WHERE id = ?")
            note.bind(1, noteID)
            guard try note.step() else { note.finalize(); return }
            let content = note.columnText(0) ?? ""
            note.finalize()
            try deriveRows(conn, noteID: noteID, content: content)
            try resolveAll(conn)
        }
    }

    /// Derives again every note whose text changed since its rows were made
    /// (or that has none, or whose rows came from an older parser), then
    /// resolves all links. This is how an upgrade, a restored archive, an
    /// import, a save an older build made and a crash between a note's save
    /// and its relink all converge.
    @discardableResult
    static func refreshStale(_ conn: SQLConnection) throws -> Counts {
        try withSavepoint(conn) {
            let all = try conn.prepare("""
                SELECT n.id, n.content, s.content_hash, s.parser_version
                FROM notes n LEFT JOIN link_sources s ON s.note_id = n.id
                """)
            var stale: [(id: String, content: String)] = []
            while try all.step() {
                guard let id = all.columnText(0) else { continue }
                let content = all.columnText(1) ?? ""
                if all.columnText(2) != contentHash(content)
                    || (all.columnInt(3) ?? 0) < derivationVersion {
                    stale.append((id, content))
                }
            }
            all.finalize()
            // Each note in a savepoint of its own: one that cannot be derived
            // is skipped and stays stale, and never undoes the rest.
            var failed = 0
            for note in stale {
                do {
                    try withSavepoint(conn) { try deriveRows(conn, noteID: note.id, content: note.content) }
                } catch {
                    failed += 1
                }
            }
            try resolveAll(conn)
            var result = try tally(conn)
            result.derivedNotes = stale.count - failed
            result.failedNotes = failed
            return result
        }
    }

    private static let keySeparator = "\u{1F}"

    private static func deriveRows(_ conn: SQLConnection, noteID: String, content: String) throws {
        #if DEBUG
        if failDerivationForTesting?(noteID) == true { throw SQLiteError.exec("derivation fault", sql: "") }
        #endif
        // Resolutions that stand today, by the link's keys, so that a link
        // keeps its destination across the rewrite below.
        var current: [String: (kind: String, id: String)] = [:]
        let old = try conn.prepare("""
            SELECT inner_key, target_key, dst_kind, dst_id FROM wikilinks
            WHERE src_note_id = ? AND state = 'resolved' AND dst_id IS NOT NULL AND target_key != ''
            ORDER BY ordinal
            """)
        old.bind(1, noteID)
        while try old.step() {
            guard let kind = old.columnText(2), let dst = old.columnText(3) else { continue }
            let key = (old.columnText(0) ?? "") + keySeparator + (old.columnText(1) ?? "")
            if current[key] == nil { current[key] = (kind, dst) }
        }
        old.finalize()

        let delete = try conn.prepare("DELETE FROM wikilinks WHERE src_note_id = ?")
        delete.bind(1, noteID)
        _ = try delete.step()
        delete.finalize()

        let insert = try conn.prepare("""
            INSERT INTO wikilinks (id, src_note_id, ordinal, raw_target, target_key, inner_key,
                                   heading, block_id, alias, is_embed, start_offset, end_offset,
                                   state, dst_kind, dst_id, head_key)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        // One scan of the text serves the links and the metadata.
        let linkScan = WikiLinkParser.scan(content)
        for (ordinal, link) in linkScan.links.enumerated() {
            let targetKey = link.isSameNote ? "" : WikiLinkParser.normalizedKey(link.target)
            let innerKey = link.isSameNote ? "" : WikiLinkParser.normalizedKey(link.inner)
            let carried = current[innerKey + keySeparator + targetKey]
            insert.reset()
            insert.bind(1, "\(noteID)#\(ordinal)")
            insert.bind(2, noteID)
            insert.bind(3, ordinal)
            insert.bind(4, link.target)
            insert.bind(5, targetKey)
            insert.bind(6, innerKey)
            insert.bind(7, link.heading)
            insert.bind(8, link.blockID)
            insert.bind(9, link.alias)
            insert.bind(10, link.isEmbed)
            insert.bind(11, link.range.location)
            insert.bind(12, NSMaxRange(link.range))
            insert.bind(13, carried == nil ? unresolved : resolved)
            insert.bind(14, carried?.kind)
            insert.bind(15, carried?.id)
            insert.bind(16, link.isSameNote ? "" : WikiLinkParser.normalizedKey(link.head))
            _ = try insert.step()
        }
        insert.finalize()

        try MetadataIndex.write(conn, noteID: noteID, scan: NoteMetadata.scan(content, links: linkScan))

        let source = try conn.prepare("""
            INSERT OR REPLACE INTO link_sources (note_id, content_hash, parser_version) VALUES (?,?,?)
            """)
        source.bind(1, noteID)
        source.bind(2, contentHash(content))
        source.bind(3, derivationVersion)
        _ = try source.step()
        source.finalize()
    }

    private static func tally(_ conn: SQLConnection) throws -> Counts {
        var counts = Counts()
        let notes = try conn.prepare("SELECT COUNT(*) FROM notes")
        if try notes.step() { counts.notes = notes.columnInt(0) ?? 0 }
        notes.finalize()
        let states = try conn.prepare("SELECT state, COUNT(*) FROM wikilinks GROUP BY state")
        while try states.step() {
            let n = states.columnInt(1) ?? 0
            counts.links += n
            switch states.columnText(0) {
            case unresolved: counts.unresolved = n
            case ambiguous: counts.ambiguous = n
            default: break
            }
        }
        states.finalize()
        return counts
    }

    // MARK: - On open

    /// Brings the link tables up to date when a database is opened. Never
    /// throws: a failure leaves rows stale until the next open and must not
    /// keep anyone out of their records.
    ///
    /// The first time it runs on a store that has links from the older
    /// engine it records, in one audit row, how many there were and how many
    /// no longer resolve (counts only; no titles or link text).
    static func deriveOnOpen(_ conn: SQLConnection) {
        do {
            let firstTime = try !hasMarker(conn)
            var legacy = 0
            if firstTime, try tableExists(conn, "note_links") {
                let count = try conn.prepare("SELECT COUNT(*) FROM note_links")
                if try count.step() { legacy = count.columnInt(0) ?? 0 }
                count.finalize()
            }
            let counts = try refreshStale(conn)
            // A note that cannot be derived stays stale and is tried at every
            // open; this makes that visible. Counts only, never text.
            if counts.failedNotes > 0 { SecurityLog.record(.linkDerivationFailed, count: counts.failedNotes) }
            guard firstTime else { return }
            try withSavepoint(conn) {
                if legacy > 0 {
                    let notResolvedNow = try legacyLinksNoLongerResolved(conn)
                    let audit = try conn.prepare("""
                        INSERT INTO audit_logs (id, action, entity_type, entity_id, details)
                        VALUES (?, 'links_rebuilt', 'links', 'all', ?)
                        """)
                    audit.bind(1, UUID().uuidString)
                    audit.bind(2, "notes=\(counts.notes) links=\(counts.links) "
                        + "unresolved=\(counts.unresolved) ambiguous=\(counts.ambiguous) "
                        + "earlier=\(legacy) unresolvedNow=\(notResolvedNow) failed=\(counts.failedNotes)")
                    _ = try audit.step()
                    audit.finalize()
                }
                let marker = try conn.prepare("""
                    INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)
                    """)
                marker.bind(1, derivedMarker)
                marker.bind(2, "Wiki-link edges derived from note text")
                marker.bind(3, 0.0)
                _ = try marker.step()
                marker.finalize()
            }
        } catch {
            return
        }
    }

    /// How many links the older engine had resolved that the stored rows no
    /// longer resolve to the same destination under the same link text.
    private static func legacyLinksNoLongerResolved(_ conn: SQLConnection) throws -> Int {
        var now = Set<String>()
        let rows = try conn.prepare("""
            SELECT src_note_id, dst_id, target_key, inner_key FROM wikilinks
            WHERE state = 'resolved' AND dst_id IS NOT NULL
            """)
        while try rows.step() {
            guard let source = rows.columnText(0), let dst = rows.columnText(1) else { continue }
            for key in [rows.columnText(2), rows.columnText(3)] {
                if let key, !key.isEmpty { now.insert([source, dst, key].joined(separator: keySeparator)) }
            }
        }
        rows.finalize()
        var lost = 0
        let legacy = try conn.prepare("""
            SELECT src_note_id, COALESCE(dst_note_id, dst_patient_id), anchor_text FROM note_links
            """)
        while try legacy.step() {
            guard let source = legacy.columnText(0), let dst = legacy.columnText(1) else { continue }
            let key = WikiLinkParser.normalizedKey(legacy.columnText(2) ?? "")
            if !now.contains([source, dst, key].joined(separator: keySeparator)) { lost += 1 }
        }
        legacy.finalize()
        return lost
    }

    private static func hasMarker(_ conn: SQLConnection) throws -> Bool {
        let stmt = try conn.prepare("SELECT COUNT(*) FROM migrations WHERE version = ?")
        stmt.bind(1, derivedMarker)
        defer { stmt.finalize() }
        return try stmt.step() && (stmt.columnInt(0) ?? 0) > 0
    }

    private static func tableExists(_ conn: SQLConnection, _ name: String) throws -> Bool {
        let stmt = try conn.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?")
        stmt.bind(1, name)
        defer { stmt.finalize() }
        return try stmt.step() && (stmt.columnInt(0) ?? 0) > 0
    }

    // MARK: - Savepoints

    /// Runs `body` in a savepoint, so it nests inside the caller's
    /// transaction (or makes its own) and undoes itself on failure.
    static func withSavepoint<T>(_ conn: SQLConnection, _ body: () throws -> T) throws -> T {
        let name = "sp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try conn.exec("SAVEPOINT \(name)")
        do {
            let result = try body()
            try conn.exec("RELEASE \(name)")
            return result
        } catch {
            try? conn.exec("ROLLBACK TO \(name)")
            try? conn.exec("RELEASE \(name)")
            throw error
        }
    }
}
