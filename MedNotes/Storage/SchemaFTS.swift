import Foundation

/// The full-text triggers and refill statements, built in one place so the
/// migration, the index rebuild and the restore check cannot drift apart.
///
/// The index holds a folded copy of the text (`GreekFold.sql`): accents,
/// capitals and the final sigma are gone, and a typed query is folded the same
/// way (`Schema.ftsQuery`). Phone, e-mail and AMKA are copied as they are.
extension Schema {
    static let ftsTriggerNames = [
        "patients_fts_insert", "patients_fts_delete", "patients_fts_update",
        "notes_fts_insert", "notes_fts_delete", "notes_fts_update"
    ]

    private static func patientValues(_ row: String) -> String {
        """
        \(row)rowid, \(row)id, \(GreekFold.sql("\(row)first_name")), \(GreekFold.sql("\(row)last_name")),
                    \(GreekFold.sql("\(row)first_name || ' ' || \(row)last_name")),
                    \(row)phone, \(row)email, \(row)amka, \(GreekFold.sql("\(row)fathers_name"))
        """
    }

    private static func noteValues(_ row: String) -> String {
        "\(row)rowid, \(row)id, \(GreekFold.sql("\(row)title")), \(GreekFold.sql("\(row)content")), \(GreekFold.sql("\(row)tags_json"))"
    }

    /// The six triggers as `sqlite_master` stores them: no `IF NOT EXISTS`.
    static var ftsTriggers: [(name: String, sql: String)] {
        let patientColumns = "rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name"
        let noteColumns = "rowid, id, title, content, tags"
        return [
            ("patients_fts_insert", """
                CREATE TRIGGER patients_fts_insert AFTER INSERT ON patients BEGIN
                    INSERT INTO patients_fts(\(patientColumns))
                    VALUES (\(patientValues("NEW.")));
                END
                """),
            ("patients_fts_delete", """
                CREATE TRIGGER patients_fts_delete AFTER DELETE ON patients BEGIN
                    DELETE FROM patients_fts WHERE rowid = OLD.rowid;
                END
                """),
            ("patients_fts_update", """
                CREATE TRIGGER patients_fts_update AFTER UPDATE OF
                    first_name, last_name, phone, email, amka, fathers_name ON patients BEGIN
                    DELETE FROM patients_fts WHERE rowid = OLD.rowid;
                    INSERT INTO patients_fts(\(patientColumns))
                    VALUES (\(patientValues("NEW.")));
                END
                """),
            ("notes_fts_insert", """
                CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
                    INSERT INTO notes_fts(\(noteColumns))
                    VALUES (\(noteValues("NEW.")));
                END
                """),
            ("notes_fts_delete", """
                CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
                    DELETE FROM notes_fts WHERE rowid = OLD.rowid;
                END
                """),
            ("notes_fts_update", """
                CREATE TRIGGER notes_fts_update AFTER UPDATE OF title, content, tags_json ON notes BEGIN
                    DELETE FROM notes_fts WHERE rowid = OLD.rowid;
                    INSERT INTO notes_fts(\(noteColumns))
                    VALUES (\(noteValues("NEW.")));
                END
                """)
        ]
    }

    /// Empties nothing: fills `notes_fts` from `notes` exactly as the insert
    /// trigger would.
    static var ftsRefillNotes: String {
        """
        INSERT INTO notes_fts(rowid, id, title, content, tags)
        SELECT \(noteValues("")) FROM notes
        """
    }

    static var ftsRefillPatients: String {
        """
        INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
        SELECT \(patientValues("")) FROM patients
        """
    }

    /// The six triggers as `Schema.v1` creates them; SQLite stores them without
    /// `IF NOT EXISTS`. An older backup or store carries exactly this text.
    static var originalFTSTriggers: [(name: String, sql: String)] {
        v1.compactMap { statement in
            let prefix = "CREATE TRIGGER IF NOT EXISTS "
            guard statement.hasPrefix(prefix) else { return nil }
            let name = String(statement.dropFirst(prefix.count).prefix { !$0.isWhitespace })
            return (name, "CREATE TRIGGER " + statement.dropFirst(prefix.count))
        }
    }

    /// The patients triggers `Database.migratePatientsFTSFathersName` wrote for
    /// a store whose index predated the father's name: the same statements as
    /// `v1` laid out differently, so their stored text differs. Kept byte for
    /// byte, because a pre-migration backup can carry them.
    static let migrationCopyPatientTriggers: [(name: String, sql: String)] = [
        ("patients_fts_insert", """
        CREATE TRIGGER patients_fts_insert AFTER INSERT ON patients BEGIN
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
            VALUES (NEW.rowid, NEW.id, NEW.first_name, NEW.last_name,
                    NEW.first_name || ' ' || NEW.last_name, NEW.phone, NEW.email, NEW.amka, NEW.fathers_name);
        END
        """),
        ("patients_fts_delete", """
        CREATE TRIGGER patients_fts_delete AFTER DELETE ON patients BEGIN
            DELETE FROM patients_fts WHERE rowid = OLD.rowid;
        END
        """),
        ("patients_fts_update", """
        CREATE TRIGGER patients_fts_update AFTER UPDATE OF
            first_name, last_name, phone, email, amka, fathers_name ON patients BEGIN
            DELETE FROM patients_fts WHERE rowid = OLD.rowid;
            INSERT INTO patients_fts(rowid, id, first_name, last_name, full_name, phone, email, amka, fathers_name)
            VALUES (NEW.rowid, NEW.id, NEW.first_name, NEW.last_name,
                    NEW.first_name || ' ' || NEW.last_name, NEW.phone, NEW.email, NEW.amka, NEW.fathers_name);
        END
        """)
    ]

    /// Every spelling of each full-text trigger an older build may have left
    /// in a backup or store: the original, the migration's copy, the current.
    static var acceptedFTSTriggerTexts: [String: [String]] {
        var accepted: [String: [String]] = [:]
        for trigger in originalFTSTriggers + migrationCopyPatientTriggers + ftsTriggers {
            accepted[trigger.name, default: []].append(trigger.sql)
        }
        return accepted
    }

    /// The tokens of a typed search, folded like the index: what a `MATCH`
    /// is built from. Letters and digits only.
    static func foldedTokens(_ rawQuery: String) -> [String] {
        splitTokens(GreekFold.fold(rawQuery))
    }
}
