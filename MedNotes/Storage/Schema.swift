import Foundation

enum Schema {
    static let currentVersion = 9

    static let v1: [String] = [
        """
        CREATE TABLE IF NOT EXISTS migrations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version TEXT NOT NULL UNIQUE,
            description TEXT NOT NULL,
            applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            execution_time REAL NOT NULL DEFAULT 0.0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS patients (
            id TEXT PRIMARY KEY NOT NULL,
            first_name TEXT NOT NULL DEFAULT '',
            last_name TEXT NOT NULL DEFAULT '',
            fathers_name TEXT,
            date_of_birth TEXT NOT NULL,
            gender TEXT NOT NULL DEFAULT 'preferNotToSay',
            phone TEXT NOT NULL DEFAULT '',
            email TEXT NOT NULL DEFAULT '',
            amka TEXT NOT NULL DEFAULT '',
            afm TEXT,
            id_number TEXT,
            address_json TEXT NOT NULL DEFAULT '{}',
            emergency_contact_json TEXT,
            insurance_json TEXT,
            photo BLOB,
            medical_json TEXT NOT NULL DEFAULT '{}',
            tags_json TEXT NOT NULL DEFAULT '[]',
            visits_json TEXT NOT NULL DEFAULT '[]',
            appointments_json TEXT NOT NULL DEFAULT '[]',
            hospitalizations_json TEXT NOT NULL DEFAULT '[]',
            files_json TEXT NOT NULL DEFAULT '[]',
            alerts_json TEXT NOT NULL DEFAULT '[]',
            notes_json TEXT NOT NULL DEFAULT '[]',
            tasks_json TEXT NOT NULL DEFAULT '[]',
            is_archived INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            last_modified TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now'))
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_patients_amka ON patients(amka) WHERE amka != ''",
        "CREATE INDEX IF NOT EXISTS idx_patients_last_first ON patients(last_name, first_name)",
        "CREATE INDEX IF NOT EXISTS idx_patients_dob ON patients(date_of_birth)",
        "CREATE INDEX IF NOT EXISTS idx_patients_archived ON patients(is_archived)",
        "CREATE INDEX IF NOT EXISTS idx_patients_modified ON patients(last_modified)",
        """
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            tags_json TEXT NOT NULL DEFAULT '[]',
            mentioned_patients_json TEXT NOT NULL DEFAULT '[]',
            is_pinned INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at)",
        "CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at)",
        """
        CREATE TABLE IF NOT EXISTS todo_items (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            is_completed INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            completed_at TEXT,
            priority TEXT NOT NULL DEFAULT 'Medium',
            due_date TEXT,
            notes TEXT,
            patient_name TEXT,
            patient_id TEXT REFERENCES patients(id) ON DELETE SET NULL,
            reminder_identifier TEXT,
            reminder_list_identifier TEXT,
            sync_status TEXT NOT NULL DEFAULT 'localOnly',
            last_sync_date TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]'
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_todos_completed ON todo_items(is_completed)",
        "CREATE INDEX IF NOT EXISTS idx_todos_due ON todo_items(due_date)",
        "CREATE INDEX IF NOT EXISTS idx_todos_priority ON todo_items(priority)",
        "CREATE INDEX IF NOT EXISTS idx_todos_sync ON todo_items(sync_status)",
        "CREATE INDEX IF NOT EXISTS idx_todos_patient ON todo_items(patient_id)",
        """
        CREATE TABLE IF NOT EXISTS calendar_events (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            start_date TEXT NOT NULL,
            end_date TEXT NOT NULL,
            is_all_day INTEGER NOT NULL DEFAULT 0,
            patient_id TEXT REFERENCES patients(id) ON DELETE SET NULL,
            event_type TEXT NOT NULL DEFAULT 'Appointment',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now'))
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_events_start ON calendar_events(start_date)",
        "CREATE INDEX IF NOT EXISTS idx_events_end ON calendar_events(end_date)",
        "CREATE INDEX IF NOT EXISTS idx_events_patient ON calendar_events(patient_id)",
        "CREATE INDEX IF NOT EXISTS idx_events_type ON calendar_events(event_type)",
        """
        CREATE TABLE IF NOT EXISTS patient_notes (
            patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            PRIMARY KEY (patient_id, note_id)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_patient_notes_note ON patient_notes(note_id)",
        """
        CREATE TABLE IF NOT EXISTS patient_files (
            id TEXT PRIMARY KEY NOT NULL,
            patient_id TEXT NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
            file_name TEXT NOT NULL,
            file_type TEXT NOT NULL DEFAULT 'other',
            file_path TEXT NOT NULL DEFAULT '',
            file_size INTEGER NOT NULL DEFAULT 0,
            upload_date TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            notes TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]'
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_files_patient ON patient_files(patient_id)",
        """
        CREATE TABLE IF NOT EXISTS audit_logs (
            id TEXT PRIMARY KEY NOT NULL,
            timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            user_id TEXT NOT NULL DEFAULT 'system',
            action TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            details TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_logs(timestamp)",
        "CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs(entity_type, entity_id)",
        "CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_logs(action)",
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS patients_fts USING fts5(
            id UNINDEXED,
            first_name,
            last_name,
            full_name,
            phone,
            email,
            amka,
            fathers_name
        )
        """,
        // The six full-text triggers below are the original text. `migrateV8`
        // replaces them with the folded versions in `SchemaFTS.swift`, which is
        // the text to edit; these are kept only so older databases still open.
        """
        CREATE TRIGGER IF NOT EXISTS patients_fts_insert AFTER INSERT ON patients BEGIN
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
            VALUES (NEW.rowid, NEW.id, NEW.first_name, NEW.last_name,
                    NEW.first_name || ' ' || NEW.last_name, NEW.phone, NEW.email, NEW.amka, NEW.fathers_name);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS patients_fts_delete AFTER DELETE ON patients BEGIN
            DELETE FROM patients_fts WHERE rowid = OLD.rowid;
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS patients_fts_update AFTER UPDATE OF
            first_name, last_name, phone, email, amka, fathers_name ON patients BEGIN
            DELETE FROM patients_fts WHERE rowid = OLD.rowid;
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
            VALUES (NEW.rowid, NEW.id, NEW.first_name, NEW.last_name,
                    NEW.first_name || ' ' || NEW.last_name, NEW.phone, NEW.email, NEW.amka, NEW.fathers_name);
        END
        """,
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
            id UNINDEXED,
            title,
            content,
            tags
        )
        """,
        """
        CREATE TRIGGER IF NOT EXISTS notes_fts_insert AFTER INSERT ON notes BEGIN
            INSERT INTO notes_fts(rowid, id, title, content, tags)
            VALUES (NEW.rowid, NEW.id, NEW.title, NEW.content, NEW.tags_json);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS notes_fts_delete AFTER DELETE ON notes BEGIN
            DELETE FROM notes_fts WHERE rowid = OLD.rowid;
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS notes_fts_update AFTER UPDATE OF title, content, tags_json ON notes BEGIN
            DELETE FROM notes_fts WHERE rowid = OLD.rowid;
            INSERT INTO notes_fts(rowid, id, title, content, tags)
            VALUES (NEW.rowid, NEW.id, NEW.title, NEW.content, NEW.tags_json);
        END
        """
    ]

    // MARK: - v2 (Obsidian core: links, templates, calendar sync columns)

    /// Idempotent table creations for schema v2. Column additions for
    /// pre-existing tables live in `Database.migrateV2` (ALTER TABLE cannot be
    /// IF NOT EXISTS, so each is guarded by a PRAGMA check there).
    static let v2: [String] = [
        """
        CREATE TABLE IF NOT EXISTS note_links (
            id TEXT PRIMARY KEY NOT NULL,
            src_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            dst_note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
            dst_patient_id TEXT REFERENCES patients(id) ON DELETE SET NULL,
            anchor_text TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now'))
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_note_links_src ON note_links(src_note_id)",
        "CREATE INDEX IF NOT EXISTS idx_note_links_dst_note ON note_links(dst_note_id)",
        "CREATE INDEX IF NOT EXISTS idx_note_links_dst_patient ON note_links(dst_patient_id)",
        """
        CREATE TABLE IF NOT EXISTS note_templates (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'custom',
            content TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now'))
        )
        """
    ]

    // MARK: - v3 (Apple Reminders sync: todo modification stamp)
    //
    // No new tables. `todo_items.updated_at` is added in `Database.migrateV3`
    // (ALTER TABLE, guarded by the same PRAGMA check as the v2 columns) and
    // backfilled from `created_at`, so v1 and v2 databases upgrade in place.

    // MARK: - v4 (security hardening: sync destinations, encrypted attachments)

    /// Explicit EventKit destinations plus the attachment encryption metadata.
    ///
    /// `sync_destinations` stores the exact calendar/list and source the user
    /// consented to. Nothing here is matched by title: the identifiers are
    /// authoritative and a missing one means "Needs Reconnection", never a
    /// fallback to a name scan. `app_created` records whether MedNotes made
    /// the container, and `needs_reconnection`/`confirmed_at` gate writes.
    static let v4: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_destinations (
            id TEXT PRIMARY KEY NOT NULL,
            bridge_type TEXT NOT NULL,
            calendar_identifier TEXT NOT NULL,
            calendar_title TEXT NOT NULL DEFAULT '',
            source_identifier TEXT NOT NULL,
            source_title TEXT NOT NULL DEFAULT '',
            source_type TEXT NOT NULL DEFAULT 'other',
            app_created INTEGER NOT NULL DEFAULT 0,
            consent_at TEXT,
            confirmed_at TEXT,
            needs_reconnection INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            UNIQUE(bridge_type)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_object_map (
            id TEXT PRIMARY KEY NOT NULL,
            domain TEXT NOT NULL,
            local_id TEXT NOT NULL,
            remote_identifier TEXT NOT NULL,
            destination_id TEXT NOT NULL REFERENCES sync_destinations(id) ON DELETE CASCADE,
            marker TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f','now')),
            UNIQUE(domain, local_id),
            UNIQUE(domain, remote_identifier)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_sync_map_remote ON sync_object_map(domain, remote_identifier)",
        "CREATE INDEX IF NOT EXISTS idx_sync_map_destination ON sync_object_map(destination_id)"
    ]

    // MARK: - v5 (derived wiki-link edges)

    /// The link index, derived from note text by `LinkIndex`; deleting both
    /// tables loses nothing, the next open derives them again.
    ///
    /// `wikilinks` holds one row per `[[...]]` occurrence, resolved or not.
    /// `dst_id` has no foreign key on purpose: an edge outlives the note or
    /// patient it pointed at and is resolved again, rather than cascading
    /// away. `link_sources` records which text each note's rows were derived
    /// from, so a stale note (restored, imported, saved by an older build)
    /// is found by comparing hashes.
    ///
    /// `note_links` (v2) is superseded and no longer read or written. It is
    /// kept because dropping a table cannot be undone.
    static let v5: [String] = [
        """
        CREATE TABLE IF NOT EXISTS wikilinks (
            id TEXT PRIMARY KEY NOT NULL,
            src_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            raw_target TEXT NOT NULL DEFAULT '',
            target_key TEXT NOT NULL DEFAULT '',
            inner_key TEXT NOT NULL DEFAULT '',
            heading TEXT,
            block_id TEXT,
            alias TEXT,
            is_embed INTEGER NOT NULL DEFAULT 0,
            start_offset INTEGER NOT NULL,
            end_offset INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'unresolved',
            dst_kind TEXT,
            dst_id TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_wikilinks_src ON wikilinks(src_note_id)",
        "CREATE INDEX IF NOT EXISTS idx_wikilinks_dst ON wikilinks(dst_id)",
        "CREATE INDEX IF NOT EXISTS idx_wikilinks_target_key ON wikilinks(target_key)",
        """
        CREATE TABLE IF NOT EXISTS link_sources (
            note_id TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            content_hash TEXT NOT NULL,
            parser_version INTEGER NOT NULL
        )
        """
    ]

    // MARK: - v6 (derived note metadata)

    /// What a note's text says about itself, derived with the links
    /// (`LinkIndex.deriveRows`, `MetadataIndex`): headings for the Outline,
    /// block ids, tags (inline `#tags` and the `tags:` property), aliases and
    /// the typed properties. Like the link tables these can be thrown away
    /// and rebuilt from the notes; they hold nothing the text does not.
    ///
    /// A note's own tag field (`notes.tags_json`) is not copied here: it is
    /// edited without touching the text, so a copy would go stale. Tag
    /// queries read it alongside these tables.
    ///
    /// Also adds `wikilinks.head_key` (see `migrateV6`).
    static let v6: [String] = [
        """
        CREATE TABLE IF NOT EXISTS note_headings (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            level INTEGER NOT NULL,
            text TEXT NOT NULL,
            key TEXT NOT NULL,
            start_offset INTEGER NOT NULL,
            PRIMARY KEY (note_id, ordinal)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS note_blocks (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            block_id TEXT NOT NULL,
            start_offset INTEGER NOT NULL,
            PRIMARY KEY (note_id, block_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS note_tags (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            tag TEXT NOT NULL,
            tag_key TEXT NOT NULL,
            source TEXT NOT NULL,
            start_offset INTEGER,
            PRIMARY KEY (note_id, ordinal)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_note_tags_key ON note_tags(tag_key)",
        """
        CREATE TABLE IF NOT EXISTS note_aliases (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            alias TEXT NOT NULL,
            alias_key TEXT NOT NULL,
            PRIMARY KEY (note_id, ordinal)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_note_aliases_key ON note_aliases(alias_key)",
        """
        CREATE TABLE IF NOT EXISTS note_properties (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            key TEXT NOT NULL,
            key_norm TEXT NOT NULL,
            kind TEXT NOT NULL,
            text_value TEXT,
            number_value REAL,
            list_json TEXT,
            PRIMARY KEY (note_id, ordinal)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_note_properties_key ON note_properties(key_norm)"
    ]

    /// The two values of `sync_tombstones.domain`, named here because the storage
    /// layer writes them.
    static let tombstoneCalendarDomain = "calendar"
    static let tombstoneRemindersDomain = "reminders"

    /// Schema v9: the records deleted here whose Apple Calendar or Reminders
    /// counterpart may still exist. An Apple object made by MedNotes whose row is
    /// gone used to be imported as a new, unlinked row by the next pull; the pull
    /// now skips any record named here. One row per deleted record, written by the
    /// delete itself. Additive, and carried by backups with the rest of the store.
    static let v9: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sync_tombstones (
            domain TEXT NOT NULL,
            local_id TEXT NOT NULL,
            deleted_at TEXT NOT NULL,
            PRIMARY KEY (domain, local_id)
        )
        """
    ]

    /// Schema v7: small named values the app keeps for itself, such as the
    /// graph's settings. Encrypted with the rest of the store and carried by
    /// backups; no triggers, and not derived from anything, so an index
    /// rebuild leaves it alone.
    static let v7: [String] = [
        """
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    ]

    /// Whether a stored trigger is exactly the expected text, byte for byte.
    /// SQLite keeps a trigger's text as it was written (minus `IF NOT EXISTS`),
    /// so a trigger the app created compares equal. Nothing is normalized: a
    /// Unicode space is not whitespace to SQLite, and Swift's `==` would treat a
    /// letter and its decomposed form as the same.
    static func triggerIsExactly(_ stored: String?, _ expected: String) -> Bool {
        guard let stored else { return false }
        return Array(stored.utf8) == Array(expected.utf8)
    }

    static func ftsQuery(_ rawQuery: String) -> String {
        let tokens = foldedTokens(rawQuery)
        if tokens.isEmpty {
            return "\"\""
        }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// Runs of letters and digits (with their combining marks). Decided scalar
    /// by scalar: a character-level test looks only at the first scalar, so a
    /// letter that takes a following `"` into its cluster would let the quote
    /// into a `MATCH` string.
    static func splitTokens(_ rawQuery: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        var hasBase = false
        func flush() {
            if !current.isEmpty, hasBase { tokens.append(String(current)) }
            current = String.UnicodeScalarView()
            hasBase = false
        }
        for scalar in rawQuery.unicodeScalars {
            let props = scalar.properties
            let isMark = [.nonspacingMark, .spacingMark, .enclosingMark].contains(props.generalCategory)
            if props.isAlphabetic || props.numericType != nil {
                current.append(scalar)
                hasBase = true
            } else if isMark, hasBase {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
