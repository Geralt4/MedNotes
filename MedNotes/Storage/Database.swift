import Foundation

/// A swap failed and putting the original database back failed too.
struct RestoreRollbackError: Error, LocalizedError {
    let underlying: Error
    let rollback: Error

    var errorDescription: String? {
        String(localized: "\(underlying.localizedDescription) The original data could not be put back: \(rollback.localizedDescription)")
    }
}

/// A draft was saved with attachment references the database no longer holds:
/// another save replaced or removed the file after the draft was loaded.
struct StaleAttachmentError: Error, LocalizedError {
    var errorDescription: String? {
        String(localized: "This patient's attachments changed after you opened the record. Use Revert to load the current files, then repeat your edit.")
    }
}

actor Database {
    private(set) var conn: SQLConnection
    /// The folded full-text triggers could not be put in place when the store
    /// opened (the old ones and the old indexes are still there): the app says
    /// so and Rebuild Indexes repairs it.
    private(set) var searchIndexNeedsRebuild = false
    /// The raw database key, kept so `replaceDatabaseFile` and
    /// `reinstateDatabaseFile` can rebuild the connection without another
    /// Keychain round-trip.
    private let databaseKey: Data?
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(LenientDate.encodeSQL(date))
        }
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self) {
                return try LenientDate.decode(s)
            }
            if let t = try? c.decode(Double.self) {
                return try LenientDate.decodeTimestamp(t)
            }
            throw LenientDateError.unsupported
        }
        return d
    }

    /// `deriveLinks: false` opens a store only to read it (the owner's original
    /// plaintext store during encryption migration): the schema is brought up
    /// to date, but no derived link rows are written into it.
    init(path: String, deriveLinks: Bool = true) throws {
        self.databaseKey = nil
        self.conn = try SQLConnection(path: path)
        try Self.configure(conn)
        searchIndexNeedsRebuild = try Self.migrate(conn, deriveLinks: deriveLinks)
    }

    /// Production construction: an encrypted connection keyed from the device
    /// root key. Every connection is verified before migrations run.
    init(path: String, key: Data) throws {
        self.databaseKey = key
        self.conn = try SQLConnection(path: path, key: key)
        try Self.configure(conn)
        searchIndexNeedsRebuild = try Self.migrate(conn)
    }

    private nonisolated static func configure(_ conn: SQLConnection) throws {
        try conn.exec("PRAGMA busy_timeout = 5000")
        do {
            try conn.exec("PRAGMA journal_mode = WAL")
        } catch {
            Thread.sleep(forTimeInterval: 0.2)
            try conn.exec("PRAGMA journal_mode = WAL")
        }
        try conn.exec("PRAGMA synchronous = NORMAL")
        try conn.exec("PRAGMA foreign_keys = ON")
        // SQLCipher: temp tables and sort spills stay in memory only, and the
        // defensive mode blocks writable_schema-style attacks plus the
        // `PRAGMA` surfaces that could be used to exfiltrate page contents.
        try conn.exec("PRAGMA temp_store = MEMORY")
        try conn.exec("PRAGMA cache_size = -8000")
        try conn.exec("PRAGMA trusted_schema = OFF")
        try conn.exec("PRAGMA defensive = ON")
    }

    /// The refold that failed at open has been done by a rebuild.
    func markSearchIndexRebuilt() { searchIndexNeedsRebuild = false }

    func close() {
        transactionDepth = 0
        conn.close()
    }

    private nonisolated static func open(path: String, key: Data?) throws -> SQLConnection {
        if let key {
            return try SQLConnection(path: path, key: key)
        }
        return try SQLConnection(path: path)
    }

    /// Writes a consistent copy of the database to `path`, encrypted under
    /// `key`. The snapshot is never a plaintext file, whatever the source is.
    ///
    /// An encrypted source uses SQLite's `VACUUM INTO`, which inherits the
    /// source codec's key, and the result is rekeyed to `key` before it is
    /// returned. A plaintext source (the store being migrated) would produce a
    /// plaintext snapshot that a restore, which always opens the snapshot under
    /// the archive key, could not read; it is exported into a database created
    /// under `key` with SQLCipher's `sqlcipher_export` instead.
    func vacuumInto(path: String, key: Data) throws {
        guard key.count == 32 else { throw SQLiteError.invalidRawKey }
        try? FileManager.default.removeItem(atPath: path)
        do {
            if databaseKey == nil {
                try conn.exec("PRAGMA wal_checkpoint(TRUNCATE)")
                let hex = key.map { String(format: "%02x", $0) }.joined()
                try conn.exec("ATTACH DATABASE '\(escapedPath(path))' AS snapshot KEY \"x'\(hex)'\"")
                do {
                    try conn.exec("SELECT sqlcipher_export('snapshot')")
                } catch {
                    try? conn.exec("DETACH DATABASE snapshot")
                    throw error
                }
                try conn.exec("DETACH DATABASE snapshot")
                return
            }
            try conn.exec("VACUUM INTO '\(escapedPath(path))'")
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        // The snapshot is keyed with the live database key; move it to the
        // archive key so the live key never leaves the process.
        if let liveKey = databaseKey, liveKey != key {
            try Self.rekey(path: path, from: liveKey, to: key)
        }
    }

    private func escapedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "''")
    }

    /// Replaces the live database with `sourcePath`. The live database keeps
    /// this actor's device key: an incoming snapshot encrypted under another
    /// key (an archive key, a restore-point key) is rekeyed before it is
    /// opened, so a backup made on another device never imports that device's
    /// key.
    func replaceDatabaseFile(with sourcePath: String, sourceKey: Data? = nil) throws {
        transactionDepth = 0
        let dest = conn.path
        let targetKey = databaseKey
        conn.close()
        do {
            Self.removeSQLiteSidecars(at: dest)
            try Self.replaceItem(at: dest, with: sourcePath)
            Self.removeSQLiteSidecars(at: dest)
            if let sourceKey, let targetKey, sourceKey != targetKey {
                try Self.rekey(path: dest, from: sourceKey, to: targetKey)
            }
            conn = try Self.open(path: dest, key: targetKey)
            try Self.configure(conn)
            searchIndexNeedsRebuild = try Self.migrate(conn)
        } catch {
            if FileManager.default.fileExists(atPath: dest) {
                conn = try Self.open(path: dest, key: targetKey)
                try Self.configure(conn)
                searchIndexNeedsRebuild = try Self.migrate(conn)
            }
            throw error
        }
    }

    /// Like `replaceDatabaseFile`, but the live database is moved into `folder`
    /// rather than deleted, so `reinstateDatabaseFile(from:)` can put exactly
    /// the original bytes back if anything later in a restore fails. If the
    /// swap itself fails the original is reinstated here before the error
    /// leaves. The caller removes `folder` once the whole restore has held.
    func replaceDatabaseFile(
        with sourcePath: String, sourceKey: Data?, preservingOriginalIn folder: URL
    ) throws {
        let fm = FileManager.default
        let dest = conn.path
        let targetKey = databaseKey
        // Fold the WAL into the main file first, so the kept copy is whole.
        try checkpoint()
        transactionDepth = 0
        conn.close()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: dest + suffix) {
                try fm.moveItem(
                    atPath: dest + suffix,
                    toPath: folder.appendingPathComponent("mednotes.db" + suffix).path)
            }
            try fm.copyItem(atPath: sourcePath, toPath: dest)
            if let sourceKey, let targetKey, sourceKey != targetKey {
                try Self.rekey(path: dest, from: sourceKey, to: targetKey)
            }
            conn = try Self.open(path: dest, key: targetKey)
            try Self.configure(conn)
            searchIndexNeedsRebuild = try Self.migrate(conn)
        } catch {
            do {
                try reinstateDatabaseFile(from: folder)
            } catch let rollbackError {
                throw RestoreRollbackError(underlying: error, rollback: rollbackError)
            }
            throw error
        }
    }

    /// Puts the database kept by `replaceDatabaseFile(…preservingOriginalIn:)`
    /// back in place and reopens it.
    func reinstateDatabaseFile(from folder: URL) throws {
        let fm = FileManager.default
        let dest = conn.path
        transactionDepth = 0
        conn.close()
        let kept = folder.appendingPathComponent("mednotes.db")
        guard fm.fileExists(atPath: kept.path) else {
            // Nothing was moved aside yet: the live file is still the original.
            conn = try Self.open(path: dest, key: databaseKey)
            try Self.configure(conn)
            return
        }
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: dest + suffix)
        }
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: kept.path + suffix) {
            try fm.moveItem(atPath: kept.path + suffix, toPath: dest + suffix)
        }
        conn = try Self.open(path: dest, key: databaseKey)
        try Self.configure(conn)
    }

    /// SQLCipher's `PRAGMA rekey` re-encrypts every page in place. SQLCipher
    /// defers attaching the codec until the first page is read, so a `SELECT`
    /// from `sqlite_master` runs first: without it `rekey` reports "can only
    /// be run on an existing encrypted database".
    nonisolated static func rekey(path: String, from oldKey: Data, to newKey: Data) throws {
        do {
            let conn = try SQLConnection(path: path, key: oldKey)
            // Touch a page so the codec is engaged, then rekey.
            try conn.exec("SELECT count(*) FROM sqlite_master")
            try conn.exec("PRAGMA journal_mode = DELETE")
            let hex = newKey.map { String(format: "%02x", $0) }.joined()
            try conn.exec("PRAGMA rekey = \"x'\(hex)'\"")
            let check = try conn.prepare("PRAGMA cipher_integrity_check")
            if try check.step(), let detail = check.columnText(0), !detail.isEmpty {
                conn.close()
                throw SQLiteError.wrongKey
            }
            conn.close()
        } catch {
            throw SQLiteError.keyingFailed(error.localizedDescription)
        }
    }

    private nonisolated static func removeSQLiteSidecars(at path: String) {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private nonisolated static func replaceItem(at dest: String, with source: String) throws {
        let fm = FileManager.default
        let tmp = dest + ".tmp-\(UUID().uuidString)"
        try fm.copyItem(atPath: source, toPath: tmp)
        if fm.fileExists(atPath: dest) {
            let old = dest + ".old-\(UUID().uuidString)"
            do {
                try fm.moveItem(atPath: dest, toPath: old)
            } catch {
                try? fm.removeItem(atPath: tmp)
                throw error
            }
            do {
                try fm.moveItem(atPath: tmp, toPath: dest)
                try? fm.removeItem(atPath: old)
            } catch {
                try? fm.removeItem(atPath: dest)
                try? fm.moveItem(atPath: old, toPath: dest)
                try? fm.removeItem(atPath: tmp)
                throw error
            }
        } else {
            try fm.moveItem(atPath: tmp, toPath: dest)
        }
        removeSQLiteSidecars(at: dest)
    }

    /// Brings the schema up to date. Returns whether the folded full-text
    /// triggers could not be put in place (the old ones stay, and the store
    /// still opens).
    #if DEBUG
    /// What opened or checked a file, in order, for tests that prove an
    /// untrusted snapshot is judged before anything migrates it.
    nonisolated(unsafe) static var eventsForTesting: [String] = []
    #endif

    @discardableResult
    private nonisolated static func migrate(_ conn: SQLConnection, deriveLinks: Bool = true) throws -> Bool {
        #if DEBUG
        eventsForTesting.append("migrate")
        #endif
        for statement in Schema.v1 {
            try conn.exec(statement)
        }
        try migrateAMKAPartialIndex(conn)
        try migratePatientsFTSFathersName(conn)
        try migrateV2(conn)
        try migrateV3(conn)
        try migrateV4(conn)
        try migrateV5(conn)
        try migrateV6(conn)
        try migrateV7(conn)
        // The plaintext store being read for a migration keeps its full-text
        // triggers and indexes as they are (they are never searched).
        var foldingFailed = false
        if deriveLinks {
            do {
                try migrateV8(conn)
            } catch {
                // The savepoint left the old triggers and indexes. Opening still
                // works, and the app says search needs rebuilding. The error text
                // carries no SQL and no row values.
                NSLog("MedNotes: the search index could not be refolded (%@); Rebuild Indexes will repair it",
                      error.localizedDescription)
                foldingFailed = true
            }
        }
        let stmt = try conn.prepare("SELECT COUNT(*) FROM migrations WHERE version = ?")
        stmt.bind(1, "1.0-clean")
        if try stmt.step(), (stmt.columnInt(0) ?? 0) == 0 {
            let insert = try conn.prepare(
                "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
            insert.bind(1, "1.0-clean")
            insert.bind(2, "Clean schema: FKs on, no computed columns, is_pinned, disk files")
            insert.bind(3, 0.0)
            _ = try insert.step()
        }
        // Last: the link tables are derived from the notes, so every other
        // table is in its final shape before they are brought up to date.
        if deriveLinks { LinkIndex.deriveOnOpen(conn) }
        return foldingFailed
    }

    /// Schema v5: the derived wiki-link tables. Only new tables, so a v4
    /// database opens unchanged and an older build ignores them.
    private nonisolated static func migrateV5(_ conn: SQLConnection) throws {
        for statement in Schema.v5 {
            try conn.exec(statement)
        }
        let marker = try conn.prepare(
            "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
        marker.bind(1, "5.0-link-tables")
        marker.bind(2, "wikilinks and link_sources: derived wiki-link edges")
        marker.bind(3, 0.0)
        _ = try marker.step()
        marker.finalize()
    }

    /// Schema v6: the derived metadata tables, and the key of the text before
    /// a link's alias (`wikilinks.head_key`), so `[[Plan #2|see]]` can resolve
    /// to a note titled "Plan #2". Additive: a v5 database opens unchanged and
    /// every note is derived again once, because its stored derivation version
    /// is older.
    private nonisolated static func migrateV6(_ conn: SQLConnection) throws {
        for statement in Schema.v6 {
            try conn.exec(statement)
        }
        try addColumnIfMissing(conn, table: "wikilinks", column: "head_key", decl: "TEXT NOT NULL DEFAULT ''")
        let marker = try conn.prepare(
            "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
        marker.bind(1, "6.0-note-metadata")
        marker.bind(2, "headings, blocks, tags, aliases and properties: derived note metadata")
        marker.bind(3, 0.0)
        _ = try marker.step()
        marker.finalize()
    }

    /// Schema v7: the `app_state` table. Additive: a v6 database opens
    /// unchanged.
    private nonisolated static func migrateV7(_ conn: SQLConnection) throws {
        for statement in Schema.v7 {
            try conn.exec(statement)
        }
        let marker = try conn.prepare(
            "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
        marker.bind(1, "7.0-app-state")
        marker.bind(2, "app_state: small named values kept by the app")
        marker.bind(3, 0.0)
        _ = try marker.step()
        marker.finalize()
    }

    /// Schema v8: the full-text indexes hold a folded copy of the text (Greek
    /// accents, capitals and the final sigma removed; see `GreekFold`), so the
    /// six triggers are replaced and both indexes are filled again. The triggers
    /// were created `IF NOT EXISTS`, so an existing database keeps the old ones
    /// until this runs. Detection is by trigger text, byte for byte; the marker
    /// only covers a database whose triggers are right but whose rows were never
    /// refilled. All of it is one savepoint: a failure leaves the old triggers
    /// and indexes, and the next open tries again.
    #if DEBUG
    /// Makes `migrateV8` fail after it has replaced the triggers, to prove
    /// the savepoint puts the old ones back.
    nonisolated(unsafe) static var failFTSFoldingForTesting = false
    #endif

    private nonisolated static func migrateV8(_ conn: SQLConnection) throws {
        var stored: [String: String] = [:]
        let names = Schema.ftsTriggerNames.map { "'\($0)'" }.joined(separator: ", ")
        let read = try conn.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name IN (\(names))")
        while try read.step() {
            if let name = read.columnText(0), let sql = read.columnText(1) { stored[name] = sql }
        }
        read.finalize()
        let current = Schema.ftsTriggers.allSatisfy { Schema.triggerIsExactly(stored[$0.name], $0.sql) }
        let marked = try conn.prepare("SELECT COUNT(*) FROM migrations WHERE version = ?")
        marked.bind(1, "8.0-fts-folding")
        let hasMarker = try marked.step() && (marked.columnInt(0) ?? 0) > 0
        marked.finalize()
        guard !current || !hasMarker else { return }

        let started = Date()
        try LinkIndex.withSavepoint(conn) {
            // Every one of the six, so a trigger that was altered is replaced too.
            for name in Schema.ftsTriggerNames { try conn.exec("DROP TRIGGER IF EXISTS \(name)") }
            for trigger in Schema.ftsTriggers { try conn.exec(trigger.sql) }
            #if DEBUG
            if failFTSFoldingForTesting { throw SQLiteError.exec("folding fault", sql: "") }
            #endif
            try conn.exec("DELETE FROM notes_fts")
            try conn.exec(Schema.ftsRefillNotes)
            try conn.exec("DELETE FROM patients_fts")
            try conn.exec(Schema.ftsRefillPatients)
            let marker = try conn.prepare(
                "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
            marker.bind(1, "8.0-fts-folding")
            marker.bind(2, "full-text indexes hold accent-, case- and final-sigma-folded text")
            marker.bind(3, Date().timeIntervalSince(started))
            _ = try marker.step()
            marker.finalize()
        }
        NSLog("MedNotes: search indexes refolded in %.2f s", Date().timeIntervalSince(started))
    }

    /// Schema v2: `[[wiki-links]]`, note templates, and Apple Calendar sync
    /// columns. Every step is idempotent so re-running after a restore or a
    /// v1-era database converges to the same shape.
    private nonisolated static func migrateV2(_ conn: SQLConnection) throws {
        try addColumnIfMissing(conn, table: "calendar_events", column: "ek_event_identifier", decl: "TEXT")
        try addColumnIfMissing(conn, table: "calendar_events", column: "sync_status", decl: "TEXT NOT NULL DEFAULT 'localOnly'")
        try addColumnIfMissing(conn, table: "calendar_events", column: "last_sync_date", decl: "TEXT")
        for statement in Schema.v2 {
            try conn.exec(statement)
        }
        // Self-heal databases written before deletePatient cleaned note_links:
        // dst_patient_id is ON DELETE SET NULL, so deleting a patient left an
        // edge pointing at nothing. Such a row is meaningless by construction —
        // replaceLinks always binds exactly one dst column non-nil — so this is
        // safe and idempotent on every open.
        try conn.exec(
            "DELETE FROM note_links WHERE dst_note_id IS NULL AND dst_patient_id IS NULL")
        for template in TemplateService.builtIns {
            let seed = try conn.prepare("""
                INSERT OR IGNORE INTO note_templates (id, name, kind, content)
                VALUES (?, ?, ?, ?)
                """)
            seed.bind(1, template.id)
            seed.bind(2, template.name)
            seed.bind(3, template.kind.rawValue)
            seed.bind(4, template.content)
            _ = try seed.step()
            seed.finalize()
        }
        let marker = try conn.prepare(
            "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
        marker.bind(1, "2.0-vault-links")
        marker.bind(2, "note_links, note_templates, calendar sync columns")
        marker.bind(3, 0.0)
        _ = try marker.step()
        marker.finalize()
    }

    /// Schema v3: the Apple Reminders bridge needs to know when a todo was
    /// last edited locally, exactly as `calendar_events.updated_at` serves the
    /// calendar bridge. ALTER TABLE cannot carry a non-constant default, so
    /// the column is nullable in SQL and backfilled from `created_at`; the
    /// decoder falls back the same way for any row that slips through.
    private nonisolated static func migrateV3(_ conn: SQLConnection) throws {
        try addColumnIfMissing(conn, table: "todo_items", column: "updated_at", decl: "TEXT")
        try conn.exec("UPDATE todo_items SET updated_at = created_at WHERE updated_at IS NULL")
        let marker = try conn.prepare(
            "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
        marker.bind(1, "3.0-reminders-sync")
        marker.bind(2, "todo_items.updated_at for the Apple Reminders bridge")
        marker.bind(3, 0.0)
        _ = try marker.step()
        marker.finalize()
    }

    /// Schema v4: explicit sync destinations and encrypted attachment metadata.
    /// The attachment columns use additive ALTERs (idempotent via the PRAGMA
    /// check) while the two new tables are `CREATE TABLE IF NOT EXISTS`.
    private nonisolated static func migrateV4(_ conn: SQLConnection) throws {
        for statement in Schema.v4 {
            try conn.exec(statement)
        }
        try addColumnIfMissing(conn, table: "patient_files", column: "storage_id", decl: "TEXT")
        try addColumnIfMissing(conn, table: "patient_files", column: "plaintext_length", decl: "INTEGER")
        try addColumnIfMissing(conn, table: "patient_files", column: "content_digest", decl: "TEXT")
        let marker = try conn.prepare(
            "INSERT OR IGNORE INTO migrations(version, description, execution_time) VALUES (?, ?, ?)")
        marker.bind(1, "4.0-encrypted-store")
        marker.bind(2, "sync_destinations, sync_object_map, attachment encryption metadata")
        marker.bind(3, 0.0)
        _ = try marker.step()
        marker.finalize()
    }

    private nonisolated static func addColumnIfMissing(
        _ conn: SQLConnection, table: String, column: String, decl: String) throws {
        let info = try conn.prepare("PRAGMA table_info(\(table))")
        var exists = false
        while try info.step() {
            if info.columnText(1) == column { exists = true; break }
        }
        info.finalize()
        guard !exists else { return }
        try conn.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
    }

    private nonisolated static func migrateAMKAPartialIndex(_ conn: SQLConnection) throws {
        let check = try conn.prepare(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_patients_amka'")
        var needsMigration = false
        if try check.step(), let sql = check.columnText(0), !sql.contains("WHERE amka != ''") {
            needsMigration = true
        }
        check.finalize()
        guard needsMigration else { return }
        try conn.exec("DROP INDEX idx_patients_amka")
        try conn.exec("CREATE UNIQUE INDEX idx_patients_amka ON patients(amka) WHERE amka != ''")
    }

    /// Older DBs indexed names in FTS but left fathers_name to SQL lower(),
    /// which does not case-fold Greek. Rebuild so father's name uses FTS.
    private nonisolated static func migratePatientsFTSFathersName(_ conn: SQLConnection) throws {
        // The column list, not the stored CREATE text: a snapshot may be hostile.
        let info = try conn.prepare("PRAGMA table_info(patients_fts)")
        var hasFathersName = false
        while try info.step() {
            if info.columnText(1) == "fathers_name" { hasFathersName = true }
        }
        info.finalize()
        let needsMigration = !hasFathersName
        guard needsMigration else { return }
        try conn.exec("DROP TRIGGER IF EXISTS patients_fts_insert")
        try conn.exec("DROP TRIGGER IF EXISTS patients_fts_delete")
        try conn.exec("DROP TRIGGER IF EXISTS patients_fts_update")
        try conn.exec("DROP TABLE IF EXISTS patients_fts")
        try conn.exec("""
            CREATE VIRTUAL TABLE patients_fts USING fts5(
                id UNINDEXED,
                first_name,
                last_name,
                full_name,
                phone,
                email,
                amka,
                fathers_name
            )
            """)
        for trigger in Schema.migrationCopyPatientTriggers { try conn.exec(trigger.sql) }
        try conn.exec("""
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
            SELECT rowid, id, first_name, last_name, first_name || ' ' || last_name,
                   phone, email, amka, fathers_name
            FROM patients
            """)
    }

    func checkpoint() throws {
        try conn.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func integrityCheck() throws -> String {
        let s = try conn.prepare("PRAGMA integrity_check")
        return (try s.step()) ? (s.columnText(0) ?? "") : ""
    }

    func indexSQL(named name: String) throws -> String? {
        let s = try conn.prepare(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?")
        s.bind(1, name)
        guard try s.step() else { return nil }
        return s.columnText(0)
    }

    func foreignKeyCheck() throws -> Int {
        let s = try conn.prepare("PRAGMA foreign_key_check")
        var violations = 0
        while try s.step() { violations += 1 }
        return violations
    }

    func counts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for table in ["patients", "notes", "todo_items", "calendar_events", "audit_logs"] {
            let s = try conn.prepare("SELECT COUNT(*) FROM \(table)")
            out[table] = (try s.step()) ? (s.columnInt(0) ?? 0) : 0
        }
        return out
    }

    private var transactionDepth = 0

    func transaction<T>(_ body: () throws -> T) throws -> T {
        let isOuter = transactionDepth == 0
        if isOuter { try conn.exec("BEGIN IMMEDIATE") }
        transactionDepth += 1
        var leftTransaction = false
        do {
            let result = try body()
            transactionDepth -= 1
            leftTransaction = true
            if isOuter {
                do {
                    try conn.exec("COMMIT")
                } catch {
                    try? conn.exec("ROLLBACK")
                    throw error
                }
            }
            return result
        } catch {
            // A failed COMMIT has already left the transaction above; without
            // this guard the depth would stay elevated and every later call
            // would be misread as nested, losing BEGIN/COMMIT/ROLLBACK entirely.
            if !leftTransaction { transactionDepth -= 1 }
            if isOuter { try? conn.exec("ROLLBACK") }
            throw error
        }
    }

    func importBatch(patients: [Patient], notes: [Note], todos: [TodoItem], events: [CalendarEvent]) throws {
        try transaction {
            for patient in patients {
                try savePatient(patient)
            }
            for note in notes {
                try saveNote(note)
            }
            for todo in todos {
                try saveTodo(todo)
            }
            for event in events {
                try saveEvent(event)
            }
            // Todos are written after savePatient's name refresh, so apply
            // live directory names again or import copies win on re-import.
            var nameIds = Set(patients.map(\.id))
            for todo in todos {
                if let pid = todo.patientId { nameIds.insert(pid) }
            }
            for id in nameIds {
                guard let patient = try loadPatient(id: id) else { continue }
                let linkedName = patient.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                try updateTodoPatientNames(
                    patientId: id,
                    name: linkedName.isEmpty ? nil : linkedName)
            }
        }
        // Imported notes arrive without link rows. Derived after the import
        // has committed and never allowed to fail it.
        refreshStaleLinks()
    }

    // MARK: - Patients

    /// `attachmentReferences` is for editor saves: the draft's file entries that
    /// carried no bytes, which must still match the stored rows as the draft
    /// saw them. Importers and restores write whole records and pass nil.
    /// `knownFileIDs` are the attachment ids the draft was loaded with: a stored
    /// row outside that set (and outside the draft) was added by another save
    /// and must not be deleted as if the draft had removed it.
    func savePatient(
        _ patient: Patient, attachmentReferences: [PatientFile]? = nil,
        knownFileIDs: Set<UUID>? = nil
    ) throws {
        try transaction {
            if let attachmentReferences {
                try requireCurrentAttachmentReferences(
                    patientId: patient.id, references: attachmentReferences,
                    known: knownFileIDs.map { $0.union(patient.files.map(\.id)) })
            }
            try insertPatient(patient)
            try syncPatientFiles(patientId: patient.id, files: patient.files)
            let linkedName = patient.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            try updateTodoPatientNames(
                patientId: patient.id,
                name: linkedName.isEmpty ? nil : linkedName)
        }
    }

    /// A file arriving without bytes is a reference to a stored attachment. If
    /// the row it names has since been replaced or removed, the draft is stale
    /// and writing it back would repoint the row at a deleted object and let
    /// the post-commit sweep delete the current one. Runs inside the save
    /// transaction so no other save can interleave.
    private func requireCurrentAttachmentReferences(
        patientId: UUID, references: [PatientFile], known: Set<UUID>?
    ) throws {
        let s = try conn.prepare("SELECT id, storage_id FROM patient_files WHERE patient_id = ?")
        s.bind(1, patientId.uuidString)
        var current: [String: String] = [:]
        while try s.step() {
            if let fid = s.columnText(0) { current[fid.uppercased()] = s.columnText(1) ?? "" }
        }
        if let known {
            let knownKeys = Set(known.map { $0.uuidString.uppercased() })
            if current.keys.contains(where: { !knownKeys.contains($0) }) { throw StaleAttachmentError() }
        }
        for file in references {
            guard let stored = current[file.id.uuidString.uppercased()],
                  stored.lowercased() == (file.storageID ?? "").lowercased()
            else { throw StaleAttachmentError() }
        }
    }

    private func insertPatient(_ patient: Patient) throws {
        let p = patient.profile
        func enc<T: Encodable>(_ v: T) throws -> String {
            String(data: try encoder.encode(v), encoding: .utf8) ?? "{}"
        }
        let sql = """
        INSERT INTO patients (
            id, first_name, last_name, fathers_name, date_of_birth, gender, phone, email,
            amka, afm, id_number, address_json, emergency_contact_json, insurance_json,
            photo, medical_json, tags_json, visits_json, appointments_json,
            hospitalizations_json, files_json, alerts_json, notes_json, tasks_json,
            is_archived, created_at, last_modified
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            first_name=excluded.first_name, last_name=excluded.last_name,
            fathers_name=excluded.fathers_name, date_of_birth=excluded.date_of_birth,
            gender=excluded.gender, phone=excluded.phone, email=excluded.email,
            amka=excluded.amka, afm=excluded.afm, id_number=excluded.id_number,
            address_json=excluded.address_json,
            emergency_contact_json=excluded.emergency_contact_json,
            insurance_json=excluded.insurance_json, photo=excluded.photo,
            medical_json=excluded.medical_json, tags_json=excluded.tags_json,
            visits_json=excluded.visits_json, appointments_json=excluded.appointments_json,
            hospitalizations_json=excluded.hospitalizations_json,
            files_json=excluded.files_json, alerts_json=excluded.alerts_json,
            notes_json=excluded.notes_json, tasks_json=excluded.tasks_json,
            is_archived=excluded.is_archived, last_modified=excluded.last_modified
        """
        let s = try conn.prepare(sql)
        s.bind(1, patient.id.uuidString)
        s.bind(2, p.firstName)
        s.bind(3, p.lastName)
        s.bind(4, p.fathersName)
        s.bind(5, LenientDate.encodeSQL(p.dateOfBirth))
        s.bind(6, p.gender.rawValue)
        s.bind(7, p.phone)
        s.bind(8, p.email)
        s.bind(9, p.amka.trimmingCharacters(in: .whitespacesAndNewlines))
        s.bind(10, p.afm)
        s.bind(11, p.idNumber)
        s.bind(12, try enc(p.address))
        s.bind(13, try p.emergencyContact.map { try enc($0) })
        s.bind(14, try p.insurance.map { try enc($0) })
        s.bind(15, p.photo)
        s.bind(16, try enc(patient.medical))
        s.bind(17, try enc(patient.tags))
        s.bind(18, try enc(patient.visits))
        s.bind(19, try enc(patient.upcomingAppointments))
        s.bind(20, try enc(patient.hospitalizations))
        // Never let file bytes into the DB: patient_files.file_path + disk is
        // the authoritative record, and decodePatient reads that table when it
        // has rows, so this copy is write-only anyway. Stripping here enforces
        // the invariant at the storage boundary instead of trusting callers to
        // have gone through a filesRoot staging path.
        s.bind(21, try enc(patient.files.map { file -> PatientFile in
            var stripped = file
            stripped.data = nil
            return stripped
        }))
        s.bind(22, try enc(patient.alerts))
        s.bind(23, try enc(patient.notes))
        s.bind(24, try enc(patient.tasks))
        s.bind(25, patient.isArchived)
        s.bind(26, LenientDate.encodeSQL(patient.createdAt))
        s.bind(27, LenientDate.encodeSQL(patient.lastModified))
        _ = try s.step()
    }

    private func syncPatientFiles(patientId: UUID, files: [PatientFile]) throws {
        let existing = try conn.prepare("SELECT id FROM patient_files WHERE patient_id = ?")
        existing.bind(1, patientId.uuidString)
        var have = Set<String>()
        while try existing.step() {
            if let fid = existing.columnText(0) { have.insert(fid) }
        }
        let wanted = Set(files.map(\.id.uuidString))

        let delete = try conn.prepare("DELETE FROM patient_files WHERE patient_id = ? AND id = ?")
        for fid in have where !wanted.contains(fid) {
            delete.reset()
            delete.bind(1, patientId.uuidString)
            delete.bind(2, fid)
            _ = try delete.step()
        }

        let upsert = try conn.prepare("""
            INSERT INTO patient_files (id, patient_id, file_name, file_type, file_path,
                                       file_size, upload_date, notes, tags_json,
                                       storage_id, plaintext_length, content_digest)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                patient_id=excluded.patient_id,
                file_name=excluded.file_name, file_type=excluded.file_type,
                file_path=excluded.file_path, file_size=excluded.file_size,
                upload_date=excluded.upload_date, notes=excluded.notes,
                tags_json=excluded.tags_json,
                storage_id=excluded.storage_id,
                plaintext_length=excluded.plaintext_length,
                content_digest=excluded.content_digest
            """)
        for file in files {
            upsert.reset()
            upsert.bind(1, file.id.uuidString)
            upsert.bind(2, patientId.uuidString)
            upsert.bind(3, file.name)
            upsert.bind(4, file.type.rawValue)
            upsert.bind(5, filePath(for: file, patientId: patientId))
            upsert.bind(6, file.fileSize > 0 ? file.fileSize : (file.data?.count ?? file.plaintextLength ?? 0))
            upsert.bind(7, LenientDate.encodeSQL(file.uploadDate))
            upsert.bind(8, file.notes)
            let tagsJSON = String(data: (try? encoder.encode(file.tags)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            upsert.bind(9, tagsJSON)
            upsert.bind(10, file.storageID)
            upsert.bind(11, file.plaintextLength)
            upsert.bind(12, file.contentDigest)
            _ = try upsert.step()
        }
    }

    private func filePath(for file: PatientFile, patientId: UUID) -> String {
        "\(patientId.uuidString)/\(file.id.uuidString)"
    }

    /// The opaque storage ID for an attachment, if one was assigned. New files
    /// always get one; legacy rows return nil until the migration upgrades them.
    func attachmentStorageID(patientId: UUID, fileId: UUID) throws -> String? {
        let s = try conn.prepare(
            "SELECT storage_id FROM patient_files WHERE patient_id = ? AND id = ?")
        s.bind(1, patientId.uuidString)
        s.bind(2, fileId.uuidString)
        guard try s.step(), let raw = s.columnText(0), !raw.isEmpty else { return nil }
        return raw
    }

    /// Every storage ID any attachment row points at, lowercased.
    func referencedStorageIDs() throws -> Set<String> {
        let s = try conn.prepare(
            "SELECT storage_id FROM patient_files WHERE storage_id IS NOT NULL AND storage_id != ''")
        var out = Set<String>()
        while try s.step() {
            if let raw = s.columnText(0) { out.insert(raw.lowercased()) }
        }
        return out
    }

    /// Records the encrypted representation of an attachment: its opaque
    /// storage ID, the plaintext length and the digest.
    func setAttachmentEncryption(
        patientId: UUID, fileId: UUID,
        storageID: String, plaintextLength: Int, digest: String) throws {
        let s = try conn.prepare("""
            UPDATE patient_files
            SET storage_id = ?, plaintext_length = ?, content_digest = ?
            WHERE patient_id = ? AND id = ?
            """)
        s.bind(1, storageID)
        s.bind(2, plaintextLength)
        s.bind(3, digest)
        s.bind(4, patientId.uuidString)
        s.bind(5, fileId.uuidString)
        _ = try s.step()
    }

    /// The patient a stored attachment row belongs to, if any. `patient_files.id`
    /// is unique across all patients.
    func patientOwningFile(_ fileId: UUID) throws -> UUID? {
        let s = try conn.prepare("SELECT patient_id FROM patient_files WHERE id = ?")
        s.bind(1, fileId.uuidString)
        guard try s.step(), let text = s.columnText(0) else { return nil }
        return UUID(uuidString: text)
    }

    /// Archives or restores one patient: the flag and the modified stamp, and
    /// nothing else. A whole-record save from a copy read earlier would also
    /// rewrite the patient's attachment list and could undo a file added since.
    func setPatientArchived(id: UUID, archived: Bool, lastModified: Date) throws {
        let s = try conn.prepare("UPDATE patients SET is_archived = ?, last_modified = ? WHERE id = ?")
        s.bind(1, archived)
        s.bind(2, LenientDate.encodeSQL(lastModified))
        s.bind(3, id.uuidString)
        _ = try s.step()
    }

    /// Removes a row whose file the migration could not find. Only for the
    /// encrypted copy being built: the plaintext original is not touched.
    func dropAttachmentRecord(patientId: UUID, fileId: UUID) throws {
        let s = try conn.prepare("DELETE FROM patient_files WHERE patient_id = ? AND id = ?")
        s.bind(1, patientId.uuidString)
        s.bind(2, fileId.uuidString)
        _ = try s.step()
    }

    /// Every attachment row that still lacks an encrypted storage ID. The
    /// migration uses this to stream each legacy file into the encrypted store.
    func attachmentsNeedingEncryption() throws -> [(patientId: String, fileId: String, relativePath: String)] {
        let s = try conn.prepare("""
            SELECT patient_id, id, file_path FROM patient_files
            WHERE storage_id IS NULL OR storage_id = ''
            """)
        var out: [(String, String, String)] = []
        while try s.step() {
            guard let pid = s.columnText(0), let fid = s.columnText(1) else { continue }
            out.append((pid, fid, s.columnText(2) ?? ""))
        }
        return out
    }

    struct AttachmentEncryptionRow: Sendable, Equatable {
        var storageID: String
        var plaintextLength: Int
        var digest: String
    }

    /// Every encrypted attachment's recorded metadata, for the migration's
    /// full-decrypt verification pass.
    func allAttachmentEncryptionRows() throws -> [AttachmentEncryptionRow] {
        let s = try conn.prepare("""
            SELECT storage_id, plaintext_length, content_digest FROM patient_files
            WHERE storage_id IS NOT NULL AND storage_id != ''
            """)
        var out: [AttachmentEncryptionRow] = []
        while try s.step() {
            guard let storageID = s.columnText(0) else { continue }
            out.append(AttachmentEncryptionRow(
                storageID: storageID,
                plaintextLength: s.columnInt(1) ?? 0,
                digest: s.columnText(2) ?? ""))
        }
        return out
    }

    struct AttachmentRecordRow: Sendable, Equatable {
        var fileID: String
        var patientID: String
        var name: String
        var type: String
        var storageID: String
        var plaintextLength: Int
        var digest: String
        var uploadDate: Date
        var notes: String
        var tags: [String]
    }

    private func attachmentRecordRow(_ s: Statement, storageID: String) -> AttachmentRecordRow {
        var tags: [String] = []
        if let raw = s.columnText(9), let data = raw.data(using: .utf8) {
            tags = decodeLossyStrings(from: data)
        }
        return AttachmentRecordRow(
            fileID: s.columnText(0) ?? "",
            patientID: s.columnText(1) ?? "",
            name: s.columnText(2) ?? "",
            type: s.columnText(3) ?? "other",
            storageID: storageID,
            plaintextLength: s.columnInt(5) ?? 0,
            digest: s.columnText(6) ?? "",
            uploadDate: (s.columnText(7).flatMap { try? LenientDate.decode($0) }) ?? Date(),
            notes: s.columnText(8) ?? "",
            tags: tags)
    }

    /// Every attachment as the backup format needs it, ordered by patient and
    /// file ID so a backup's record order is deterministic.
    func allAttachmentRecords() throws -> [AttachmentRecordRow] {
        let s = try conn.prepare("""
            SELECT id, patient_id, file_name, file_type, storage_id,
                   plaintext_length, content_digest, upload_date, notes, tags_json
            FROM patient_files
            WHERE storage_id IS NOT NULL AND storage_id != ''
            ORDER BY patient_id, id
            """)
        var out: [AttachmentRecordRow] = []
        while try s.step() {
            guard let storageID = s.columnText(4), !storageID.isEmpty else { continue }
            out.append(attachmentRecordRow(s, storageID: storageID))
        }
        return out
    }

    /// The attachments a plaintext store still keeps as files under `Files/`
    /// (no storage ID yet), with the path each one is read from.
    func legacyAttachmentRecords() throws -> [(row: AttachmentRecordRow, relativePath: String)] {
        let s = try conn.prepare("""
            SELECT id, patient_id, file_name, file_type, storage_id,
                   plaintext_length, content_digest, upload_date, notes, tags_json, file_path
            FROM patient_files
            WHERE storage_id IS NULL OR storage_id = ''
            ORDER BY patient_id, id
            """)
        var out: [(AttachmentRecordRow, String)] = []
        while try s.step() {
            out.append((attachmentRecordRow(s, storageID: ""), s.columnText(10) ?? ""))
        }
        return out
    }

    private func decodePatient(_ row: Statement) throws -> Patient? {
        func dec<T: Decodable>(_ type: T.Type, _ col: Int32, fallback: T) -> T {
            guard let txt = row.columnText(col), let data = txt.data(using: .utf8) else {
                return fallback
            }
            return (try? decoder.decode(type, from: data)) ?? fallback
        }
        func decArray<T: Decodable>(_ type: T.Type, _ col: Int32) -> [T] {
            guard let txt = row.columnText(col), let data = txt.data(using: .utf8),
                  let raw = try? decoder.decode([LossyDecodable<T>].self, from: data)
            else { return [] }
            return raw.compactMap(\.value)
        }
        guard let idStr = row.columnText(0), let id = UUID(uuidString: idStr)
        else { return nil }
        let dob = (row.columnText(4).flatMap { try? LenientDate.decode($0) })
            ?? Date(timeIntervalSince1970: 0)

        let genderRaw = row.columnText(5) ?? Gender.fallback.rawValue
        var profile = PatientProfile(
            firstName: row.columnText(1) ?? "",
            lastName: row.columnText(2) ?? "",
            fathersName: row.columnText(3),
            dateOfBirth: dob,
            gender: Gender.parse(genderRaw),
            amka: row.columnText(8) ?? "",
            afm: row.columnText(9),
            idNumber: row.columnText(10),
            phone: row.columnText(6) ?? "",
            email: row.columnText(7) ?? "",
            photo: row.columnData(14))
        profile.address = dec(Address.self, 11, fallback: Address())
        if let ecTxt = row.columnText(12), let data = ecTxt.data(using: .utf8) {
            profile.emergencyContact = try? decoder.decode(EmergencyContact.self, from: data)
        }
        if let insTxt = row.columnText(13), let data = insTxt.data(using: .utf8) {
            profile.insurance = try? decoder.decode(InsuranceInfo.self, from: data)
        }

        let created = (row.columnText(25).flatMap { try? LenientDate.decode($0) }) ?? Date()
        let modified = (row.columnText(26).flatMap { try? LenientDate.decode($0) }) ?? created

        let filesFromTable = try loadPatientFiles(patientId: id)
        let files = filesFromTable.isEmpty
            ? decArray(PatientFile.self, 20)
            : filesFromTable

        return Patient(
            id: id,
            profile: profile,
            medical: dec(MedicalInfo.self, 15, fallback: MedicalInfo()),
            tags: decArray(PatientTag.self, 16),
            alerts: decArray(MedicalAlert.self, 21),
            visits: decArray(Visit.self, 17),
            upcomingAppointments: decArray(Appointment.self, 18),
            hospitalizations: decArray(Hospitalization.self, 19),
            files: files,
            notes: row.columnText(22).flatMap { $0.data(using: .utf8) }.map(decodeLossyStrings(from:)) ?? [],
            tasks: row.columnText(23).flatMap { $0.data(using: .utf8) }.map(decodeLossyStrings(from:)) ?? [],
            createdAt: created,
            lastModified: modified,
            isArchived: row.columnBool(24) ?? false)
    }

    private static let patientColumns = """
        SELECT id, first_name, last_name, fathers_name, date_of_birth, gender, phone, email,
               amka, afm, id_number, address_json, emergency_contact_json, insurance_json,
               photo, medical_json, tags_json, visits_json, appointments_json,
               hospitalizations_json, files_json, alerts_json, notes_json, tasks_json,
               is_archived, created_at, last_modified
        FROM patients
        """

    func loadPatient(id: UUID) throws -> Patient? {
        let s = try conn.prepare("\(Self.patientColumns) WHERE id = ?")
        s.bind(1, id.uuidString)
        if try s.step() {
            return try decodePatient(s)
        }
        return nil
    }

    func loadAllPatients(includeArchived: Bool = true) throws -> [Patient] {
        let sql = includeArchived
            ? "\(Self.patientColumns) ORDER BY last_name COLLATE NOCASE, first_name COLLATE NOCASE"
            : "\(Self.patientColumns) WHERE is_archived = 0 ORDER BY last_name COLLATE NOCASE, first_name COLLATE NOCASE"
        let s = try conn.prepare(sql)
        var out: [Patient] = []
        while try s.step() {
            if let p = try decodePatient(s) { out.append(p) }
        }
        return out
    }

    func deletePatient(id: UUID) throws {
        try transaction {
            // Clear denormalized names before the FK nulls patient_id,
            // otherwise the rows can no longer be found by patient_id.
            try updateTodoPatientNames(patientId: id, name: nil)
            try unlinkPatientFromNotes(patientId: id)
            let s = try conn.prepare("DELETE FROM patients WHERE id = ?")
            s.bind(1, id.uuidString)
            _ = try s.step()
            s.finalize()
            // Links that named the patient stay in their notes as unresolved
            // links (`wikilinks.dst_id` has no foreign key to cascade).
            try LinkIndex.resolveAll(conn)
        }
    }

    /// Resolves every stored wiki-link again. Cheap; call after anything that
    /// can change what a link names (a patient saved, renamed or archived).
    func resolveAllLinks() throws {
        try transaction { try LinkIndex.resolveAll(conn) }
    }

    /// Derives one note's wiki-link rows from its current text and resolves
    /// every link. Separate from `saveNote` on purpose: a failure here must
    /// never undo the save.
    func relinkNote(id: UUID) throws {
        try transaction { try LinkIndex.relink(conn, noteID: id.uuidString) }
    }

    /// Derives again every note whose text changed since its link rows were
    /// made. Never throws.
    func refreshStaleLinks() {
        _ = try? transaction { try LinkIndex.refreshStale(conn) }
    }

    private func unlinkPatientFromNotes(patientId: UUID) throws {
        let notes = try loadAllNotes()
        for note in notes where note.mentionedPatients.contains(patientId) {
            var updated = note
            updated.mentionedPatients.removeAll { $0 == patientId }
            try saveNote(updated)
        }
    }

    func loadPatientFiles(patientId: UUID) throws -> [PatientFile] {
        let s = try conn.prepare("""
            SELECT id, file_name, file_type, file_path, file_size, upload_date, notes, tags_json,
                   storage_id, plaintext_length, content_digest
            FROM patient_files WHERE patient_id = ? ORDER BY upload_date DESC
            """)
        s.bind(1, patientId.uuidString)
        var out: [PatientFile] = []
        while try s.step() {
            guard let idStr = s.columnText(0), let id = UUID(uuidString: idStr) else { continue }
            let upload = (s.columnText(5).flatMap { try? LenientDate.decode($0) }) ?? Date()
            var tags: [String] = []
            if let t = s.columnText(7), let d = t.data(using: .utf8) {
                tags = decodeLossyStrings(from: d)
            }
            out.append(PatientFile(
                id: id,
                name: s.columnText(1) ?? "",
                type: s.columnText(2).map(PatientFileType.parse) ?? .other,
                data: nil,
                fileSize: s.columnInt(4) ?? 0,
                uploadDate: upload,
                notes: s.columnText(6) ?? "",
                tags: tags,
                storageID: s.columnText(8),
                plaintextLength: s.columnInt(9),
                contentDigest: s.columnText(10)))
        }
        return out
    }

    func loadFileRelativePath(patientId: UUID, fileId: UUID) throws -> String? {
        let s = try conn.prepare("SELECT file_path FROM patient_files WHERE patient_id = ? AND id = ?")
        s.bind(1, patientId.uuidString)
        s.bind(2, fileId.uuidString)
        guard try s.step(), let rel = s.columnText(0), !rel.isEmpty else { return nil }
        return rel
    }

    func searchPatients(_ query: String, limit: Int = 10_000, includeArchived: Bool = false) throws -> [Patient] {
        let tokens = Schema.splitTokens(query)
        guard !tokens.isEmpty else { return [] }
        let tokenClauses = tokens.map { _ in
            """
            (id IN (SELECT id FROM patients_fts WHERE patients_fts MATCH ?)
             OR instr(\(GreekFold.sql("ifnull(fathers_name, '')")), ?) > 0)
            """
        }.joined(separator: " AND ")
        let sql = Self.patientColumns + """
             WHERE (\(tokenClauses))
               AND (? = 1 OR is_archived = 0)
            ORDER BY last_name COLLATE NOCASE, first_name COLLATE NOCASE
            LIMIT ?
            """
        let s = try conn.prepare(sql)
        var idx: Int32 = 1
        for token in tokens {
            s.bind(idx, Schema.ftsQuery(token))
            idx += 1
            s.bind(idx, GreekFold.fold(token))
            idx += 1
        }
        s.bind(idx, includeArchived)
        s.bind(idx + 1, limit)
        var out: [Patient] = []
        while try s.step() {
            if let p = try decodePatient(s) { out.append(p) }
        }
        return out
    }

    // MARK: - Notes

    func saveNote(_ note: Note) throws {
        try transaction {
            var seenMentions = Set<UUID>()
            let mentions = try note.mentionedPatients.filter { id in
                guard seenMentions.insert(id).inserted else { return false }
                return try patientExists(id: id)
            }
            let tagsJSON = String(
                data: try encoder.encode(note.tags), encoding: .utf8) ?? "[]"
            let mentionsJSON = String(
                data: try encoder.encode(mentions), encoding: .utf8) ?? "[]"
            let sql = """
            INSERT INTO notes (id, title, content, created_at, updated_at, tags_json,
                               mentioned_patients_json, is_pinned)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, content=excluded.content,
                updated_at=excluded.updated_at, tags_json=excluded.tags_json,
                mentioned_patients_json=excluded.mentioned_patients_json,
                is_pinned=excluded.is_pinned
            """
            let s = try conn.prepare(sql)
            s.bind(1, note.id.uuidString)
            s.bind(2, note.title)
            s.bind(3, note.content)
            s.bind(4, LenientDate.encodeSQL(note.createdAt))
            s.bind(5, LenientDate.encodeSQL(note.updatedAt))
            s.bind(6, tagsJSON)
            s.bind(7, mentionsJSON)
            s.bind(8, note.isPinned)
            _ = try s.step()
            try syncNoteMentions(noteId: note.id.uuidString, patientIds: mentions)
        }
    }

    private func syncNoteMentions(noteId: String, patientIds: [UUID]) throws {
        let existing = try conn.prepare("SELECT patient_id FROM patient_notes WHERE note_id = ?")
        existing.bind(1, noteId)
        var have = Set<String>()
        while try existing.step() {
            if let pid = existing.columnText(0) { have.insert(pid) }
        }
        let wanted = Set(patientIds.map(\.uuidString))
        let delete = try conn.prepare("DELETE FROM patient_notes WHERE note_id = ? AND patient_id = ?")
        for pid in have where !wanted.contains(pid) {
            delete.reset()
            delete.bind(1, noteId)
            delete.bind(2, pid)
            _ = try delete.step()
        }
        let patientExists = try conn.prepare("SELECT 1 FROM patients WHERE id = ?")
        let insert = try conn.prepare(
            "INSERT OR IGNORE INTO patient_notes (patient_id, note_id) VALUES (?, ?)")
        for pid in wanted where !have.contains(pid) {
            patientExists.reset()
            patientExists.bind(1, pid)
            guard try patientExists.step() else { continue }
            insert.reset()
            insert.bind(1, pid)
            insert.bind(2, noteId)
            _ = try insert.step()
        }
    }

    func decodeNote(_ row: Statement) throws -> Note? {
        guard let idStr = row.columnText(0), let id = UUID(uuidString: idStr) else { return nil }
        func strArray(_ col: Int32) -> [String] {
            guard let t = row.columnText(col), let d = t.data(using: .utf8) else { return [] }
            var seen = Set<String>()
            return decodeLossyStrings(from: d).filter { seen.insert($0).inserted }
        }
        func uuidArray(_ col: Int32) -> [UUID] {
            guard let t = row.columnText(col), let d = t.data(using: .utf8) else { return [] }
            return decodeLossyUUIDs(from: d)
        }
        let created = (row.columnText(3).flatMap { try? LenientDate.decode($0) }) ?? Date()
        let updated = (row.columnText(4).flatMap { try? LenientDate.decode($0) }) ?? created
        return Note(
            id: id,
            title: row.columnText(1) ?? "",
            content: row.columnText(2) ?? "",
            createdAt: created,
            updatedAt: updated,
            tags: strArray(5),
            mentionedPatients: uuidArray(6),
            isPinned: row.columnBool(7) ?? false)
    }

    func loadNote(id: UUID) throws -> Note? {
        let s = try conn.prepare("SELECT id, title, content, created_at, updated_at, tags_json, mentioned_patients_json, is_pinned FROM notes WHERE id = ?")
        s.bind(1, id.uuidString)
        if try s.step() { return try decodeNote(s) }
        return nil
    }

    func loadAllNotes() throws -> [Note] {
        let s = try conn.prepare("""
            SELECT id, title, content, created_at, updated_at, tags_json,
                   mentioned_patients_json, is_pinned
            FROM notes
            ORDER BY is_pinned DESC, updated_at DESC
            """)
        var out: [Note] = []
        while try s.step() {
            if let n = try decodeNote(s) { out.append(n) }
        }
        return out
    }

    func deleteNote(id: UUID) throws {
        try transaction {
            let s = try conn.prepare("DELETE FROM notes WHERE id = ?")
            s.bind(1, id.uuidString)
            _ = try s.step()
            s.finalize()
            // The note's own links go with it (foreign-key cascade); links in
            // other notes that named it stay, and now resolve to another note
            // with that title or to nothing.
            try LinkIndex.resolveAll(conn)
        }
    }

    func toggleNotePinned(id: UUID) throws {
        let s = try conn.prepare("""
            UPDATE notes
            SET is_pinned = CASE is_pinned WHEN 1 THEN 0 ELSE 1 END,
                updated_at = ?
            WHERE id = ?
            """)
        s.bind(1, LenientDate.encodeSQL(Date()))
        s.bind(2, id.uuidString)
        _ = try s.step()
    }

    func searchNotes(_ query: String, limit: Int = 10_000) throws -> [Note] {
        let tokens = Schema.splitTokens(query)
        guard !tokens.isEmpty else { return [] }
        let patientTokenClauses = tokens.map { _ in
            """
            (id IN (SELECT id FROM patients_fts WHERE patients_fts MATCH ?)
             OR instr(\(GreekFold.sql("ifnull(fathers_name, '')")), ?) > 0)
            """
        }.joined(separator: " AND ")
        let s = try conn.prepare("""
            SELECT id, title, content, created_at, updated_at, tags_json,
                   mentioned_patients_json, is_pinned
            FROM notes
            WHERE id IN (SELECT id FROM notes_fts WHERE notes_fts MATCH ?)
               OR id IN (
                   SELECT pn.note_id FROM patient_notes pn
                   WHERE pn.patient_id IN (
                       SELECT id FROM patients WHERE \(patientTokenClauses)
                   )
               )
            ORDER BY is_pinned DESC, updated_at DESC
            LIMIT ?
            """)
        var idx: Int32 = 1
        s.bind(idx, Schema.ftsQuery(query))
        idx += 1
        for token in tokens {
            s.bind(idx, Schema.ftsQuery(token))
            idx += 1
            s.bind(idx, GreekFold.fold(token))
            idx += 1
        }
        s.bind(idx, limit)
        var out: [Note] = []
        while try s.step() {
            if let n = try decodeNote(s) { out.append(n) }
        }
        return out
    }

    // MARK: - Todos

    func saveTodo(_ todo: TodoItem) throws {
        let tagsJSON = String(data: try encoder.encode(todo.tags), encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO todo_items (id, title, is_completed, created_at, completed_at, priority,
                                due_date, notes, patient_name, patient_id, reminder_identifier,
                                reminder_list_identifier, sync_status, last_sync_date, tags_json,
                                updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, is_completed=excluded.is_completed,
            completed_at=excluded.completed_at, priority=excluded.priority,
            due_date=excluded.due_date, notes=excluded.notes,
            patient_name=excluded.patient_name, patient_id=excluded.patient_id,
            reminder_identifier=excluded.reminder_identifier,
            reminder_list_identifier=excluded.reminder_list_identifier,
            sync_status=excluded.sync_status, last_sync_date=excluded.last_sync_date,
            tags_json=excluded.tags_json, updated_at=excluded.updated_at
        """
        let s = try conn.prepare(sql)
        s.bind(1, todo.id.uuidString)
        s.bind(2, todo.title)
        s.bind(3, todo.isCompleted)
        s.bind(4, LenientDate.encodeSQL(todo.createdAt))
        s.bind(5, todo.completedAt.map(LenientDate.encodeSQL))
        s.bind(6, todo.priority.rawValue)
        s.bind(7, todo.dueDate.map(LenientDate.encodeSQL))
        s.bind(8, todo.notes)
        s.bind(9, todo.patientName)
        s.bind(10, todo.patientId?.uuidString)
        s.bind(11, todo.reminderIdentifier)
        s.bind(12, todo.reminderListIdentifier)
        s.bind(13, todo.syncStatus.sqlValue)
        s.bind(14, todo.lastSyncDate.map(LenientDate.encodeSQL))
        s.bind(15, tagsJSON)
        s.bind(16, LenientDate.encodeSQL(todo.updatedAt))
        _ = try s.step()
    }

    private func decodeTodo(_ row: Statement) throws -> TodoItem? {
        guard let idStr = row.columnText(0), let id = UUID(uuidString: idStr) else { return nil }
        func date(_ i: Int32) -> Date? { row.columnText(i).flatMap { try? LenientDate.decode($0) } }
        var tags: [String] = []
        if let t = row.columnText(14), let d = t.data(using: .utf8) {
            var seen = Set<String>()
            tags = decodeLossyStrings(from: d).filter { seen.insert($0).inserted }
        }
        let priority = row.columnText(5).map(TodoPriority.parse) ?? .medium
        let completed = row.columnBool(2) ?? false
        return TodoItem(
            id: id,
            title: row.columnText(1) ?? "",
            isCompleted: completed,
            createdAt: date(3) ?? Date(),
            updatedAt: date(15) ?? date(3) ?? Date(),
            completedAt: completed ? date(4) : nil,
            priority: priority,
            dueDate: date(6),
            notes: row.columnText(7),
            patientName: row.columnText(8),
            patientId: row.columnText(9).flatMap(UUID.init(uuidString:)),
            tags: tags,
            reminderIdentifier: row.columnText(10),
            reminderListIdentifier: row.columnText(11),
            syncStatus: SyncStatus.fromSQL(row.columnText(12)),
            lastSyncDate: date(13))
    }

    func loadTodo(id: UUID) throws -> TodoItem? {
        let s = try conn.prepare(Self.todoSelect + " WHERE id = ?")
        s.bind(1, id.uuidString)
        if try s.step() { return try decodeTodo(s) }
        return nil
    }

    private static let todoSelect = """
        SELECT id, title, is_completed, created_at, completed_at, priority, due_date, notes,
               patient_name, patient_id, reminder_identifier, reminder_list_identifier,
               sync_status, last_sync_date, tags_json, updated_at
        FROM todo_items
        """

    func loadAllTodos(includeCompleted: Bool = true) throws -> [TodoItem] {
        let sql = includeCompleted
            ? "\(Self.todoSelect) ORDER BY is_completed ASC, due_date IS NULL, due_date ASC"
            : "\(Self.todoSelect) WHERE is_completed = 0 ORDER BY due_date IS NULL, due_date ASC"
        let s = try conn.prepare(sql)
        var out: [TodoItem] = []
        while try s.step() {
            if let t = try decodeTodo(s) { out.append(t) }
        }
        return out
    }

    func deleteTodo(id: UUID) throws {
        let s = try conn.prepare("DELETE FROM todo_items WHERE id = ?")
        s.bind(1, id.uuidString)
        _ = try s.step()
    }

    func toggleTodoCompleted(id: UUID) throws {
        let s = try conn.prepare("""
            UPDATE todo_items
            SET is_completed = CASE is_completed WHEN 1 THEN 0 ELSE 1 END,
                completed_at = CASE is_completed WHEN 1 THEN NULL ELSE ? END,
                updated_at = ?
            WHERE id = ?
            """)
        // A toggle is a user edit: stamp it so the Reminders bridge pushes it.
        let now = LenientDate.encodeSQL(Date())
        s.bind(1, now)
        s.bind(2, now)
        s.bind(3, id.uuidString)
        _ = try s.step()
    }

    func updateTodoPatientNames(patientId: UUID, name: String?) throws {
        let s = try conn.prepare("UPDATE todo_items SET patient_name = ? WHERE patient_id = ?")
        s.bind(1, name)
        s.bind(2, patientId.uuidString)
        _ = try s.step()
    }

    // MARK: - Calendar events

    func saveEvent(_ event: CalendarEvent) throws {
        var stored = event
        stored.ensureEndNotBeforeStart()
        let sql = """
        INSERT INTO calendar_events (id, title, description, start_date, end_date, is_all_day,
                                     patient_id, event_type, created_at, updated_at,
                                     ek_event_identifier, sync_status, last_sync_date)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, description=excluded.description,
            start_date=excluded.start_date, end_date=excluded.end_date,
            is_all_day=excluded.is_all_day, patient_id=excluded.patient_id,
            event_type=excluded.event_type, updated_at=excluded.updated_at,
            ek_event_identifier=excluded.ek_event_identifier,
            sync_status=excluded.sync_status, last_sync_date=excluded.last_sync_date
        """
        let s = try conn.prepare(sql)
        s.bind(1, stored.id.uuidString)
        s.bind(2, stored.title)
        s.bind(3, stored.description)
        s.bind(4, LenientDate.encodeSQL(stored.startDate))
        s.bind(5, LenientDate.encodeSQL(stored.endDate))
        s.bind(6, stored.isAllDay)
        s.bind(7, stored.patientId?.uuidString)
        s.bind(8, stored.eventType.rawValue)
        s.bind(9, LenientDate.encodeSQL(stored.createdAt))
        s.bind(10, LenientDate.encodeSQL(stored.updatedAt))
        s.bind(11, stored.ekEventIdentifier)
        s.bind(12, stored.syncStatus.sqlValue)
        s.bind(13, stored.lastSyncDate.map { LenientDate.encodeSQL($0) })
        _ = try s.step()
    }

    private func decodeEvent(_ row: Statement) throws -> CalendarEvent? {
        guard let idStr = row.columnText(0), let id = UUID(uuidString: idStr) else { return nil }
        func date(_ i: Int32) -> Date? { row.columnText(i).flatMap { try? LenientDate.decode($0) } }
        let start = date(3) ?? Date()
        let isAllDay = row.columnBool(5) ?? false
        var event = CalendarEvent(
            id: id,
            title: row.columnText(1) ?? "",
            description: row.columnText(2) ?? "",
            startDate: start,
            endDate: date(4) ?? (isAllDay ? start : start.addingTimeInterval(1800)),
            isAllDay: isAllDay,
            patientId: row.columnText(6).flatMap(UUID.init(uuidString:)),
            eventType: row.columnText(7).map(EventType.parse) ?? .appointment,
            createdAt: date(8) ?? Date(),
            updatedAt: date(9) ?? date(8) ?? Date(),
            ekEventIdentifier: row.columnText(10),
            syncStatus: SyncStatus.fromSQL(row.columnText(11)),
            lastSyncDate: date(12))
        event.ensureEndNotBeforeStart()
        return event
    }

    func loadEvent(id: UUID) throws -> CalendarEvent? {
        let s = try conn.prepare(Self.eventSelect + " WHERE id = ?")
        s.bind(1, id.uuidString)
        if try s.step() { return try decodeEvent(s) }
        return nil
    }

    private static let eventSelect = """
        SELECT id, title, description, start_date, end_date, is_all_day, patient_id,
               event_type, created_at, updated_at, ek_event_identifier, sync_status,
               last_sync_date
        FROM calendar_events
        """

    func loadAllEvents() throws -> [CalendarEvent] {
        let s = try conn.prepare("\(Self.eventSelect) ORDER BY start_date ASC")
        var out: [CalendarEvent] = []
        while try s.step() {
            if let e = try decodeEvent(s) { out.append(e) }
        }
        return out
    }

    func loadEvents(from start: Date, to end: Date) throws -> [CalendarEvent] {
        let s = try conn.prepare("\(Self.eventSelect) WHERE start_date <= ? AND end_date >= ? ORDER BY start_date ASC")
        s.bind(1, LenientDate.encodeSQL(end))
        s.bind(2, LenientDate.encodeSQL(start))
        var out: [CalendarEvent] = []
        while try s.step() {
            if let e = try decodeEvent(s) { out.append(e) }
        }
        return out
    }

    func deleteEvent(id: UUID) throws {
        let s = try conn.prepare("DELETE FROM calendar_events WHERE id = ?")
        s.bind(1, id.uuidString)
        _ = try s.step()
    }

    func patientExists(id: UUID) throws -> Bool {
        let s = try conn.prepare("SELECT 1 FROM patients WHERE id = ?")
        s.bind(1, id.uuidString)
        return try s.step()
    }

    func noteLinkCount(noteId: UUID) throws -> Int {
        let s = try conn.prepare("SELECT COUNT(*) FROM patient_notes WHERE note_id = ?")
        s.bind(1, noteId.uuidString)
        return (try s.step()) ? (s.columnInt(0) ?? 0) : 0
    }

    // MARK: - Audit

    func logAudit(_ entry: AuditLogEntry) throws {
        guard !entry.action.isEmpty, !entry.entityType.isEmpty, !entry.entityId.isEmpty else {
            throw SQLiteError.exec("audit entry requires action, entityType and entityId", sql: "INSERT INTO audit_logs")
        }
        let s = try conn.prepare("""
            INSERT INTO audit_logs (id, timestamp, user_id, action, entity_type, entity_id, details)
            VALUES (?,?,?,?,?,?,?)
            """)
        s.bind(1, entry.id.uuidString)
        s.bind(2, LenientDate.encodeSQL(entry.timestamp))
        s.bind(3, entry.userId)
        s.bind(4, entry.action)
        s.bind(5, entry.entityType)
        s.bind(6, entry.entityId)
        s.bind(7, entry.details)
        _ = try s.step()
    }

    func recentAuditLogs(limit: Int = 100) throws -> [AuditLogEntry] {
        let s = try conn.prepare("""
            SELECT id, timestamp, user_id, action, entity_type, entity_id, details
            FROM audit_logs ORDER BY timestamp DESC LIMIT ?
            """)
        s.bind(1, limit)
        var out: [AuditLogEntry] = []
        while try s.step() {
            if let entry = Self.auditEntry(from: s) { out.append(entry) }
        }
        return out
    }

    /// The newest row for one action — "when was the last backup made".
    func latestAuditLog(action: String) throws -> AuditLogEntry? {
        let s = try conn.prepare("""
            SELECT id, timestamp, user_id, action, entity_type, entity_id, details
            FROM audit_logs WHERE action = ? ORDER BY timestamp DESC LIMIT 1
            """)
        s.bind(1, action)
        guard try s.step() else { return nil }
        return Self.auditEntry(from: s)
    }

    private static func auditEntry(from s: Statement) -> AuditLogEntry? {
        guard let idStr = s.columnText(0), let id = UUID(uuidString: idStr) else { return nil }
        let ts = (s.columnText(1).flatMap { try? LenientDate.decode($0) }) ?? Date()
        return AuditLogEntry(
            id: id, timestamp: ts,
            userId: s.columnText(2) ?? "system",
            action: s.columnText(3) ?? "",
            entityType: s.columnText(4) ?? "",
            entityId: s.columnText(5) ?? "",
            details: s.columnText(6) ?? "")
    }
}
