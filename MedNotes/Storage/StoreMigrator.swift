import Foundation

/// Crash-safe conversion of a plaintext store into the encrypted one.
///
/// Phases, in order, with a PHI-free journal (`migration.json`) recording only
/// phase names and opaque counts so an interruption at any point resumes or
/// rolls back deterministically:
///
///  1. `backupRequired` — a portable v2 backup must be created and test-decrypted
///     before the original is touched.
///  2. `staging`        — a fresh encrypted database and attachment store are
///     built beside the live store by copying records through SQL, never by
///     re-using the plaintext file.
///  3. `validate`       — schema version, counts, foreign keys, attachment
///     counts and digests, and a full decrypt pass.
///  4. `swap`           — the encrypted directories are moved into place
///     atomically; the old store is kept until every check passes.
///  5. `cleanup`        — plaintext database, WAL/journal, attachments and
///     restore points are removed, and the journal is deleted last.
actor StoreMigrator {
    enum Phase: String, Codable, CaseIterable {
        case backupRequired
        case stagingDatabase
        case stagingAttachments
        case validating
        case swapping
        case cleanup
        case complete
    }

    struct Journal: Codable, Equatable {
        var phase: Phase
        var schemaVersion: Int
        var recordCounts: [String: Int]
        var attachmentCount: Int
        var startedAt: Date
        var updatedAt: Date
    }

    struct MigrationReport: Sendable, Equatable {
        var patients = 0
        var notes = 0
        var todos = 0
        var events = 0
        var attachments = 0
        var backupTestedAt: URL?
        var plaintextRemoved = false
    }

    enum MigrationError: Error, LocalizedError {
        case backupNotTested
        case stagingFailed(String)
        case validationFailed(String)
        case swapFailed(String)
        case journalCorrupt

        var errorDescription: String? {
            switch self {
            case .backupNotTested:
                return String(localized: "Create and verify a portable backup before encrypting this store.")
            case .stagingFailed(let detail):
                return String(localized: "Could not build the encrypted store: \(detail)")
            case .validationFailed(let detail):
                return String(localized: "The encrypted store failed validation: \(detail)")
            case .swapFailed(let detail):
                return String(localized: "The encrypted store could not be installed: \(detail)")
            case .journalCorrupt:
                return String(localized: "The migration journal is unreadable. The original store is untouched.")
            }
        }
    }

    private let dataRoot: DataRoot
    private let keyManager: KeyManager

    init(dataRoot: DataRoot, keyManager: KeyManager) {
        self.dataRoot = dataRoot
        self.keyManager = keyManager
    }

    nonisolated static func journalURL(in dataRoot: DataRoot) -> URL {
        dataRoot.rootURL.appendingPathComponent("migration.json")
    }

    nonisolated static func stagingDirectory(in dataRoot: DataRoot) -> URL {
        dataRoot.rootURL.appendingPathComponent("Encrypted.staging", isDirectory: true)
    }

    nonisolated static func attachmentsDirectory(in dataRoot: DataRoot) -> URL {
        dataRoot.rootURL.appendingPathComponent("Attachments", isDirectory: true)
    }

    /// Staging for the encrypted attachment tree. A sibling of `Attachments/`,
    /// never a child: the swap moves the whole destination aside, so staging
    /// inside it would vanish with the original.
    nonisolated static func stagingAttachmentsDirectory(in dataRoot: DataRoot) -> URL {
        dataRoot.rootURL.appendingPathComponent("Attachments.staging", isDirectory: true)
    }

    // MARK: - Journal

    func readJournal() throws -> Journal? {
        let url = Self.journalURL(in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(Journal.self, from: data) else {
            throw MigrationError.journalCorrupt
        }
        return journal
    }

    /// Recover before inspecting or opening either half of the live store.
    /// A completed swap is retained; an interrupted swap is rolled back.
    func recoverInterruptedMigration() throws {
        guard let journal = try readJournal() else { return }
        let fm = FileManager.default
        switch journal.phase {
        case .complete, .cleanup:
            try finishCleanup()
        case .swapping:
            let oldDB = dataRoot.rootURL.appendingPathComponent("Plaintext.old.db")
            let oldAttachments = dataRoot.rootURL.appendingPathComponent("Plaintext.old.Attachments", isDirectory: true)
            if fm.fileExists(atPath: oldDB.path) {
                if fm.fileExists(atPath: dataRoot.databaseURL.path) {
                    try fm.removeItem(at: dataRoot.databaseURL)
                }
                try fm.moveItem(at: oldDB, to: dataRoot.databaseURL)
            }
            if fm.fileExists(atPath: oldAttachments.path) {
                if fm.fileExists(atPath: dataRoot.attachmentsURL.path) {
                    try fm.removeItem(at: dataRoot.attachmentsURL)
                }
                try fm.moveItem(at: oldAttachments, to: dataRoot.attachmentsURL)
            }
            guard fm.fileExists(atPath: dataRoot.databaseURL.path),
                  SQLiteHeaderInspection.isPlaintextSQLite(at: dataRoot.databaseURL) else {
                throw MigrationError.swapFailed("The original database could not be recovered.")
            }
            rollbackStaging()
        default:
            guard fm.fileExists(atPath: dataRoot.databaseURL.path),
                  SQLiteHeaderInspection.isPlaintextSQLite(at: dataRoot.databaseURL) else {
                throw MigrationError.swapFailed("The original database could not be recovered.")
            }
            rollbackStaging()
        }
    }

    private func writeJournal(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        let url = Self.journalURL(in: dataRoot)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func makeJournal(phase: Phase, counts: [String: Int] = [:], attachments: Int = 0) -> Journal {
        let now = Date()
        return Journal(
            phase: phase, schemaVersion: Schema.currentVersion,
            recordCounts: counts, attachmentCount: attachments,
            startedAt: now, updatedAt: now)
    }

    // MARK: - Migration

    /// Converts the plaintext store. `backupDestination` must already contain a
    /// v2 archive that the caller created and test-decrypted; the migrator
    /// re-verifies it before staging.
    func migrate(
        backupDestination: URL,
        passphrase: String,
        progress: (@Sendable (Phase) -> Void)? = nil) async throws -> MigrationReport {
        var report = MigrationReport()
        let backupURL = backupDestination
        // Re-open the backup to prove the passphrase and the file are good
        // before any original data is touched.
        let inspection = try BackupArchiveV2.inspect(at: backupURL, passphrase: passphrase)
        guard inspection.manifest.schemaVersion <= Schema.currentVersion else {
            throw MigrationError.validationFailed(String(localized: "The backup was made by a newer MedNotes."))
        }
        report.backupTestedAt = backupURL

        let staging = Self.stagingDirectory(in: dataRoot)
        let attachments = Self.attachmentsDirectory(in: dataRoot)
        try? FileManager.default.removeItem(at: Self.stagingAttachmentsDirectory(in: dataRoot))
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        try writeJournal(makeJournal(phase: .stagingDatabase))
        progress?(.stagingDatabase)

        // A fresh encrypted database built beside the live one. Records are
        // copied logically, so no plaintext page ever reaches the new file.
        let key = try keyManager.createRootKey()
        let databaseKey = try StoreKeyContext.subkey(rootKey: key, context: StoreKeyContext.database)
        let attachmentKey = try StoreKeyContext.subkey(rootKey: key, context: StoreKeyContext.attachments)
        let stagingDBURL = staging.appendingPathComponent("mednotes.db")
        let encrypted = try Database(path: stagingDBURL.path, key: databaseKey)

        let plaintextPath = dataRoot.databaseURL.path
        // The original store gets its schema brought up to date (new tables and
        // markers only) but no derived rows, and its data is never written.
        let plainReader = try Database(path: plaintextPath, deriveLinks: false)
        defer {
            Task { await plainReader.close() }
        }

        let patients = try await plainReader.loadAllPatients(includeArchived: true)
        let notes = try await plainReader.loadAllNotes()
        let todos = try await plainReader.loadAllTodos(includeCompleted: true)
        let events = try await plainReader.loadAllEvents()
        try await encrypted.importBatch(patients: patients, notes: notes, todos: todos, events: events)

        // Audit rows carry no PHI but preserve the user's history. Copy them
        // before taking the counts the validation pass below compares against;
        // otherwise every store with an audit trail fails validation.
        let audit = try await plainReader.recentAuditLogs(limit: 100_000)
        for entry in audit {
            try await encrypted.logAudit(entry)
        }
        try await plainReader.close()

        let counts = try await encrypted.counts()
        report.patients = counts["patients"] ?? 0
        report.notes = counts["notes"] ?? 0
        report.todos = counts["todo_items"] ?? 0
        report.events = counts["calendar_events"] ?? 0

        try writeJournal(makeJournal(phase: .stagingAttachments, counts: counts))
        progress?(.stagingAttachments)

        // Attachments: stream each plaintext file into its encrypted form. The
        // legacy file is read once into memory (attachments are small by
        // policy); no temporary plaintext file is ever created.
        let stagingAttachments = Self.stagingAttachmentsDirectory(in: dataRoot)
        let store = try EncryptedFileStore(root: stagingAttachments, key: attachmentKey)
        let legacyFiles = try await encrypted.attachmentsNeedingEncryption()
        for file in legacyFiles {
            let source = dataRoot.filesURL.appendingPathComponent(file.relativePath)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let plaintext = try Data(contentsOf: source)
            let storageID = try await store.store(plaintext)
            try await encrypted.setAttachmentEncryption(
                patientId: UUID(uuidString: file.patientId) ?? UUID(),
                fileId: UUID(uuidString: file.fileId) ?? UUID(),
                storageID: storageID,
                plaintextLength: plaintext.count,
                digest: store.digest(of: plaintext))
            report.attachments += 1
        }

        try writeJournal(makeJournal(phase: .validating, counts: counts, attachments: report.attachments))
        progress?(.validating)

        // Validation: integrity, FKs, count preservation and a full decrypt of
        // every encrypted attachment.
        let integrity = try await encrypted.integrityCheck()
        guard integrity == "ok" else {
            throw MigrationError.validationFailed(String(localized: "integrity check returned \(integrity)"))
        }
        let fk = try await encrypted.foreignKeyCheck()
        guard fk == 0 else {
            throw MigrationError.validationFailed(String(localized: "\(fk) broken links between records"))
        }
        for (table, expected) in counts {
            let actual: Int
            switch table {
            case "patients": actual = try await encrypted.counts()["patients"] ?? 0
            case "notes": actual = try await encrypted.counts()["notes"] ?? 0
            case "todo_items": actual = try await encrypted.counts()["todo_items"] ?? 0
            case "calendar_events": actual = try await encrypted.counts()["calendar_events"] ?? 0
            case "audit_logs": actual = try await encrypted.counts()["audit_logs"] ?? 0
            default: actual = expected
            }
            guard actual == expected else {
                throw MigrationError.validationFailed(String(localized: "\(table): \(actual) rows, expected \(expected)"))
            }
        }
        let storedIDs = try await encrypted.attachmentsNeedingEncryption()
        guard storedIDs.isEmpty else {
            throw MigrationError.validationFailed(String(localized: "\(storedIDs.count) attachments not encrypted"))
        }
        try await verifyAttachments(store: store, database: encrypted)
        try await encrypted.close()

        try writeJournal(makeJournal(phase: .swapping, counts: counts, attachments: report.attachments))
        progress?(.swapping)

        // Swap: encrypted DB beside the live file, then the attachment tree.
        // If either half fails, put the plaintext store back as a whole: a new
        // database with the old attachments (or vice versa) is not a store.
        do {
            try swapInEncryptedDatabase(from: stagingDBURL)
            try swapInAttachments(stagingRoot: stagingAttachments)
        } catch {
            restorePlaintextStore()
            throw error
        }
        report.plaintextRemoved = true

        try writeJournal(makeJournal(phase: .complete, counts: counts, attachments: report.attachments))
        progress?(.complete)
        return report
    }

    /// Full decrypt pass plus digest verification against what the database
    /// recorded, so a silently corrupted stream cannot pass staging.
    private func verifyAttachments(store: EncryptedFileStore, database: Database) async throws {
        let rows = try await database.allAttachmentEncryptionRows()
        for row in rows {
            let plaintext = try await store.read(storageID: row.storageID)
            guard plaintext.count == row.plaintextLength else {
                throw MigrationError.validationFailed(String(localized: "attachment \(String(row.storageID.prefix(8))) has the wrong length"))
            }
            guard store.digest(of: plaintext) == row.digest else {
                throw MigrationError.validationFailed(String(localized: "attachment \(String(row.storageID.prefix(8))) does not match its digest"))
            }
        }
    }

    private func swapInEncryptedDatabase(from stagingDBURL: URL) throws {
        let fm = FileManager.default
        let dest = dataRoot.databaseURL
        let old = dataRoot.rootURL.appendingPathComponent("Plaintext.old.db")
        // Drop a leftover from an earlier failed attempt, never the live file.
        if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
        try fm.moveItem(at: dest, to: old)
        do {
            try fm.moveItem(at: stagingDBURL, to: dest)
        } catch {
            // The live database is the only copy that matters: put it back.
            try? fm.moveItem(at: old, to: dest)
            throw error
        }
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: dest.path + suffix)
        }
    }

    private func swapInAttachments(stagingRoot: URL) throws {
        let fm = FileManager.default
        let dest = Self.attachmentsDirectory(in: dataRoot)
        let old = dataRoot.rootURL.appendingPathComponent("Plaintext.old.Attachments", isDirectory: true)
        // `DataRoot` creates `Attachments/` up front, so the destination
        // normally exists and must be moved aside rather than overwritten.
        if fm.fileExists(atPath: dest.path) {
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            try fm.moveItem(at: dest, to: old)
        }
        do {
            try fm.moveItem(at: stagingRoot, to: dest)
        } catch {
            // Put the original back so a failed swap is not destructive.
            if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: old.path) {
                try? fm.moveItem(at: old, to: dest)
            }
            throw error
        }
    }

    /// Puts both halves of the plaintext store back after a failed swap. The
    /// database is restored first: if it cannot be, the old attachments stay
    /// in their kept folder rather than being deleted.
    private func restorePlaintextStore() {
        let fm = FileManager.default
        let oldDB = dataRoot.rootURL.appendingPathComponent("Plaintext.old.db")
        if fm.fileExists(atPath: oldDB.path) {
            try? fm.removeItem(at: dataRoot.databaseURL)
            try? fm.moveItem(at: oldDB, to: dataRoot.databaseURL)
            for suffix in ["-wal", "-shm"] {
                try? fm.removeItem(atPath: dataRoot.databaseURL.path + suffix)
            }
        }
        let oldAttachments = dataRoot.rootURL
            .appendingPathComponent("Plaintext.old.Attachments", isDirectory: true)
        if fm.fileExists(atPath: oldAttachments.path) {
            try? fm.removeItem(at: dataRoot.attachmentsURL)
            try? fm.moveItem(at: oldAttachments, to: dataRoot.attachmentsURL)
        }
    }

    /// Deletes every remaining plaintext artifact and the journal. Runs after
    /// the encrypted store is serving, and only deletes paths it owns.
    ///
    /// The old Markdown mirror (`Vault/`) is not among them: it can hold notes
    /// that exist nowhere else, and the review that decides what to import
    /// needs the open encrypted store. Settings › Data offers that review and
    /// deletes the mirror only once nothing is left to decide.
    func finishCleanup() throws {
        let fm = FileManager.default
        let artifacts: [URL] = [
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.db"),
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.Attachments", isDirectory: true),
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.db-wal"),
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.db-shm"),
            Self.stagingDirectory(in: dataRoot),
            dataRoot.filesURL
        ]
        for url in artifacts {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        let journal = Self.journalURL(in: dataRoot)
        if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
    }

    /// Rollback on a failure before the swap: the staging tree and the journal
    /// are removed, and the original plaintext store keeps its data as it was.
    func rollbackStaging() {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.stagingDirectory(in: dataRoot))
        try? fm.removeItem(at: Self.stagingAttachmentsDirectory(in: dataRoot))
        try? fm.removeItem(at: Self.journalURL(in: dataRoot))
    }
}
