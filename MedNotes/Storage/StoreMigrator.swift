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
        /// Files the plaintext store listed but no longer had on disk. Their
        /// records are not carried over (there is nothing to encrypt); the
        /// backup made before the conversion still has them.
        var missingAttachments: [String] = []
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
    ///
    /// Returns what a finished migration left behind and could not be
    /// deleted (see `finishCleanup`); empty when there is nothing, or when the
    /// migration did not finish.
    @discardableResult
    func recoverInterruptedMigration() throws -> [String] {
        guard let journal = try readJournal() else {
            return removeFinishedMigrationLeftovers()
        }
        let fm = FileManager.default
        switch journal.phase {
        case .complete, .cleanup:
            return finishCleanup()
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
        return []
    }

    private func writeJournal(_ journal: Journal) throws {
        #if DEBUG
        if Self.failJournalWriteForTesting?(journal.phase) == true {
            throw MigrationError.stagingFailed("journal write fault")
        }
        #endif
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

    #if DEBUG
    /// Makes the journal write for a phase fail, so a test can prove what the
    /// migrator does when the last write after both swaps cannot be made.
    nonisolated(unsafe) static var failJournalWriteForTesting: ((Phase) -> Bool)?
    #endif

    /// Converts the plaintext store. `backupDestination` must already contain a
    /// v2 archive that the caller created and test-decrypted; the migrator
    /// re-verifies it before staging.
    ///
    /// `rootKey` is the key the caller already created (and stored) for the
    /// new store. Without it the migrator asks the key manager, which for the
    /// Keychain is a second read and a second user-presence prompt.
    func migrate(
        backupDestination: URL,
        passphrase: String,
        rootKey existingKey: Data? = nil,
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

        // `Database(path:)` creates a missing file, so without this a store
        // that is gone, or already encrypted, would "migrate" as an empty one
        // and the swap would then discard the only original.
        guard FileManager.default.fileExists(atPath: dataRoot.databaseURL.path),
              SQLiteHeaderInspection.isPlaintextSQLite(at: dataRoot.databaseURL) else {
            throw MigrationError.stagingFailed(String(localized: "There is no unencrypted store to convert."))
        }

        let staging = Self.stagingDirectory(in: dataRoot)
        let attachments = Self.attachmentsDirectory(in: dataRoot)
        try? FileManager.default.removeItem(at: Self.stagingAttachmentsDirectory(in: dataRoot))
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        try writeJournal(makeJournal(phase: .stagingDatabase))
        progress?(.stagingDatabase)

        // A fresh encrypted database built beside the live one. Records are
        // copied logically, so no plaintext page ever reaches the new file.
        let key = try existingKey ?? keyManager.createRootKey()
        let databaseKey = try StoreKeyContext.subkey(rootKey: key, context: StoreKeyContext.database)
        let attachmentKey = try StoreKeyContext.subkey(rootKey: key, context: StoreKeyContext.attachments)
        let stagingDBURL = staging.appendingPathComponent("mednotes.db")
        let encrypted = try Database(path: stagingDBURL.path, key: databaseKey)

        let plaintextPath = dataRoot.databaseURL.path
        // Opening the original brings its schema up to date, which also
        // rewrites rows the app derives (link rows, the built-in templates,
        // missing update times); none of the user's records are written.
        let plainReader = try Database(path: plaintextPath, deriveLinks: false)
        defer {
            Task { await plainReader.close() }
        }

        let patients = try await plainReader.loadAllPatients(includeArchived: true)
        let notes = try await plainReader.loadAllNotes()
        let todos = try await plainReader.loadAllTodos(includeCompleted: true)
        let events = try await plainReader.loadAllEvents()
        try await encrypted.importBatch(patients: patients, notes: notes, todos: todos, events: events)

        // Custom templates, and the user's edits to the shipped ones, live in
        // their own table, which `importBatch` does not carry.
        for template in try await plainReader.customTemplates() {
            try await encrypted.saveTemplate(template)
        }

        // What the source holds, taken before anything is copied from it: the
        // number the copy is held to below. Counting the copy against itself
        // could never fail.
        let sourceCounts = try await plainReader.counts()

        // Audit rows carry no PHI but preserve the user's history. Copy every
        // one (no cap), before the counts the validation pass compares.
        let audit = try await plainReader.recentAuditLogs(limit: -1)
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
            guard FileManager.default.fileExists(atPath: source.path) else {
                // The plaintext store lists a file that is not on disk. It
                // cannot be encrypted and would fail validation for ever, so
                // the dangling record stays out of the new store (the
                // backup made first still has it) and the user is told.
                let patientId = UUID(uuidString: file.patientId) ?? UUID()
                let fileId = UUID(uuidString: file.fileId) ?? UUID()
                let name = try await encrypted.loadPatientFiles(patientId: patientId)
                    .first { $0.id == fileId }?.name
                try await encrypted.dropAttachmentRecord(patientId: patientId, fileId: fileId)
                report.missingAttachments.append(name ?? file.fileId)
                continue
            }
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
        // Every record the source held must be in the copy. A row the source
        // could not decode and so did not copy shows up here as a shortfall
        // instead of vanishing.
        let copiedCounts = try await encrypted.counts()
        for table in ["patients", "notes", "todo_items", "calendar_events", "audit_logs"] {
            let expected = sourceCounts[table] ?? 0
            let actual = copiedCounts[table] ?? 0
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

        // Both swaps are done. If this last write cannot be made, the journal
        // still says `.swapping`, and launch-time recovery would roll the
        // finished migration back over the new store. No journal is the
        // honest state: the caller runs the cleanup straight away.
        do {
            try writeJournal(makeJournal(phase: .complete, counts: counts, attachments: report.attachments))
        } catch {
            try? FileManager.default.removeItem(at: Self.journalURL(in: dataRoot))
        }
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

    /// With no journal, a plaintext copy beside an encrypted database is what a
    /// finished migration left behind: its final journal write failed and the
    /// journal was dropped (see `migrate`), or the process ended before the
    /// cleanup ran. The swaps are done, so the copy is removed. A database that
    /// is still plaintext, or missing, means no migration finished, and nothing
    /// is touched.
    private func removeFinishedMigrationLeftovers() -> [String] {
        let fm = FileManager.default
        let leftover = dataRoot.rootURL.appendingPathComponent("Plaintext.old.db")
        guard fm.fileExists(atPath: leftover.path),
              fm.fileExists(atPath: dataRoot.databaseURL.path),
              !SQLiteHeaderInspection.isPlaintextSQLite(at: dataRoot.databaseURL) else { return [] }
        return finishCleanup()
    }

    /// Deletes every remaining plaintext artifact and the journal. Runs after
    /// the encrypted store is serving, and only deletes paths it owns.
    ///
    /// The old Markdown mirror (`Vault/`) is not among them: it can hold notes
    /// that exist nowhere else, and the review that decides what to import
    /// needs the open encrypted store. Settings › Data offers that review and
    /// deletes the mirror only once nothing is left to decide.
    ///
    /// Every artifact is tried, and the names of those that could not be
    /// removed (an immutable flag, a read-only folder, a file held open) are
    /// returned instead of thrown: this runs at every launch, and one stuck
    /// item must not keep the encrypted store from opening. The journal goes
    /// only when nothing is left, so the next launch tries again; a pass that
    /// finds no journal writes one for that.
    @discardableResult
    func finishCleanup() -> [String] {
        let fm = FileManager.default
        let artifacts: [URL] = [
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.db"),
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.Attachments", isDirectory: true),
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.db-wal"),
            dataRoot.rootURL.appendingPathComponent("Plaintext.old.db-shm"),
            Self.stagingDirectory(in: dataRoot),
            dataRoot.filesURL
        ]
        var leftovers: [String] = []
        for url in artifacts where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                leftovers.append(url.lastPathComponent)
            }
        }
        let journal = Self.journalURL(in: dataRoot)
        if leftovers.isEmpty {
            try? fm.removeItem(at: journal)
        } else if !fm.fileExists(atPath: journal.path) {
            try? writeJournal(makeJournal(phase: .cleanup))
        }
        return leftovers
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
