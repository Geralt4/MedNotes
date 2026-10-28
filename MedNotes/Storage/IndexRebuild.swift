import Foundation

/// What a rebuild of the derived indexes found, counts only: nothing here
/// carries a title, tag, property or link text.
struct IndexRebuildReport: Equatable, Sendable {
    var notes = 0
    var patients = 0
    var links = 0
    var unresolvedLinks = 0
    var ambiguousLinks = 0
    var headings = 0
    var tags = 0
    var properties = 0
    /// Notes that could not be derived; they stay as they were and are tried
    /// again on the next open.
    var failedNotes = 0
    /// Any check that did not hold after the rebuild, as counts
    /// ("notes_fts 3 of 4").
    var problems: [String] = []

    var passed: Bool { failedNotes == 0 && problems.isEmpty }

    /// The audit row's details. Counts only.
    var auditDetails: String {
        "notes=\(notes) links=\(links) unresolved=\(unresolvedLinks) ambiguous=\(ambiguousLinks) "
            + "headings=\(headings) tags=\(tags) properties=\(properties) failed=\(failedNotes) "
            + "passed=\(passed ? 1 : 0)"
    }
}

/// A rebuild whose checks failed; nothing was changed.
struct IndexRebuildError: Error, LocalizedError, Equatable {
    let problems: [String]

    var errorDescription: String? {
        String(localized: "The indexes could not be rebuilt and were left as they were.")
    }
}

extension Database {
    /// Rebuilds everything derived from the notes and patients: the link
    /// tables, the note metadata, and both full-text indexes. Notes, patients
    /// and every other table are untouched.
    ///
    /// Derivation keeps each link's current target (`LinkIndex` reads it
    /// before rewriting a note's rows), so a link whose title has since been
    /// shared by another note stays where it pointed; only the stale marker is
    /// reset. The full-text tables are emptied and refilled exactly as their
    /// triggers fill them. Everything runs in one transaction and is checked
    /// before it commits: if the row counts, the full-text index or the
    /// foreign keys do not hold, it rolls back and throws.
    func rebuildIndexes() throws -> IndexRebuildReport {
        var report = try transaction { () throws -> IndexRebuildReport in
            var report = IndexRebuildReport()

            try conn.exec("UPDATE link_sources SET parser_version = 0")
            let derived = try LinkIndex.refreshStale(conn)
            report.failedNotes = derived.failedNotes

            // The triggers too: a damaged or altered one would leave the next
            // edit out of the index again.
            for name in Schema.ftsTriggerNames { try conn.exec("DROP TRIGGER IF EXISTS \(name)") }
            for trigger in Schema.ftsTriggers { try conn.exec(trigger.sql) }
            try conn.exec("DELETE FROM notes_fts")
            try conn.exec(Schema.ftsRefillNotes)
            try conn.exec("DELETE FROM patients_fts")
            try conn.exec(Schema.ftsRefillPatients)

            func count(_ table: String) throws -> Int {
                let s = try conn.prepare("SELECT COUNT(*) FROM \(table)")
                defer { s.finalize() }
                return try s.step() ? (s.columnInt(0) ?? 0) : 0
            }
            report.notes = try count("notes")
            report.patients = try count("patients")
            let ftsNotes = try count("notes_fts")
            let ftsPatients = try count("patients_fts")
            // After the rebuild exactly the notes that failed are still stale:
            // no row for them, or a row from an older derivation.
            let stale = try conn.prepare("""
                SELECT COUNT(*) FROM notes n LEFT JOIN link_sources s ON s.note_id = n.id
                WHERE s.note_id IS NULL OR s.parser_version < \(LinkIndex.derivationVersion)
                """)
            let staleNotes = try stale.step() ? (stale.columnInt(0) ?? 0) : 0
            stale.finalize()
            if ftsNotes != report.notes { report.problems.append("notes_fts \(ftsNotes) of \(report.notes)") }
            if ftsPatients != report.patients { report.problems.append("patients_fts \(ftsPatients) of \(report.patients)") }
            if staleNotes != report.failedNotes {
                report.problems.append("stale notes \(staleNotes), failed \(report.failedNotes)")
            }
            do {
                try conn.exec("INSERT INTO notes_fts(notes_fts) VALUES('integrity-check')")
            } catch {
                report.problems.append("notes_fts integrity-check")
            }
            let violations = try foreignKeyCheck()
            if violations > 0 { report.problems.append("foreign keys \(violations)") }

            report.links = try count("wikilinks")
            report.headings = try count("note_headings")
            report.tags = try count("note_tags")
            report.properties = try count("note_properties")
            let states = try conn.prepare("SELECT state, COUNT(*) FROM wikilinks GROUP BY state")
            while try states.step() {
                switch states.columnText(0) {
                case LinkIndex.unresolved: report.unresolvedLinks = states.columnInt(1) ?? 0
                case LinkIndex.ambiguous: report.ambiguousLinks = states.columnInt(1) ?? 0
                default: break
                }
            }
            states.finalize()

            // The full-text or key checks failed: undo all of it.
            let blocking = report.problems
            if !blocking.isEmpty { throw IndexRebuildError(problems: blocking) }
            return report
        }

        // After the commit: the file's own check, and folding the log back in.
        if try integrityCheck() != "ok" { report.problems.append("integrity_check") }
        try? conn.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        if report.passed {
            // The six triggers are the current ones again and the indexes are
            // filled: the refold that failed at open has nothing left to do.
            try? conn.exec("""
                INSERT OR IGNORE INTO migrations(version, description, execution_time)
                VALUES ('8.0-fts-folding', 'full-text indexes hold accent-, case- and final-sigma-folded text', 0.0)
                """)
            markSearchIndexRebuilt()
        }
        return report
    }
}
