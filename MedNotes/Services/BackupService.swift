import Foundation

/// Schema and digest validation that depends on the archive format, kept out
/// of `Database.swift` so the CLI's system-only typecheck never sees it.
extension Database {
    /// Checks an untrusted snapshot's triggers and views on a bare connection
    /// **before** anything opens it as a `Database` (which migrates it: a trigger
    /// planted on a table the migration writes to would run then). `key` nil
    /// reads a plaintext snapshot. Any view is rejected, and so is any trigger
    /// that is not one of the six full-text names on `notes` or `patients`; the
    /// migration writes nothing to those two tables and replaces all six
    /// triggers, and the exact-text check after it (`validateExpectedSchema`)
    /// still rejects anything else. Nothing is written to the file.
    static func validateSnapshotFile(path: String, key: Data?) throws {
        #if DEBUG
        eventsForTesting.append("validate")
        #endif
        let connection = try key.map { try SQLConnection(path: path, key: $0) } ?? SQLConnection(path: path)
        defer { connection.close() }
        try connection.exec("PRAGMA query_only = ON")
        try connection.exec("PRAGMA trusted_schema = OFF")
        let owner: [String: String] = [
            "patients_fts_insert": "patients", "patients_fts_delete": "patients", "patients_fts_update": "patients",
            "notes_fts_insert": "notes", "notes_fts_delete": "notes", "notes_fts_update": "notes"
        ]
        let objects = try connection.prepare(
            "SELECT type, name, tbl_name FROM sqlite_master WHERE type IN ('view', 'trigger')")
        defer { objects.finalize() }
        var unexpected: [String] = []
        while try objects.step() {
            guard let type = objects.columnText(0), let name = objects.columnText(1) else { continue }
            if type != "trigger" || owner[name] != objects.columnText(2) { unexpected.append("\(type) \(name)") }
        }
        guard unexpected.isEmpty else {
            throw BackupError.unexpectedSchema(unexpected.joined(separator: ", "))
        }
    }

    /// Confirms the expected tables and columns exist and that no unexpected
    /// trigger or view was planted in a restored snapshot.
    func validateExpectedSchema() throws {
        for (table, columns) in BackupArchiveV2.expectedTables {
            let info = try conn.prepare("PRAGMA table_info(\(table))")
            var present = Set<String>()
            while try info.step() {
                if let name = info.columnText(1) { present.insert(name) }
            }
            info.finalize()
            guard !present.isEmpty else {
                throw BackupError.unexpectedSchema(String(localized: "missing table \(table)"))
            }
            for column in columns where !present.contains(column) {
                throw BackupError.unexpectedSchema(String(localized: "\(table) is missing \(column)"))
            }
        }
        // SQLite removes IF NOT EXISTS when it stores CREATE statements.
        // Compare the entire definition, not just the name: a trigger with an
        // otherwise familiar name can contain arbitrary destructive SQL.
        // Every trigger the app creates is a full-text one. The restored
        // snapshot was opened through `Database(path:key:)`, which already
        // replaced any of those six whose text was not exactly the current one;
        // anything else is rejected, compared byte for byte.
        let trusted = Dictionary(uniqueKeysWithValues: Schema.ftsTriggers.map { ($0.name, $0.sql) })
        let objects = try conn.prepare(
            "SELECT type, name, sql FROM sqlite_master WHERE type IN ('view', 'trigger')")
        var unexpected: [String] = []
        while try objects.step() {
            guard let type = objects.columnText(0), let name = objects.columnText(1) else { continue }
            let sql = objects.columnText(2) ?? ""
            if type != "trigger" || trusted[name].map({ !Schema.triggerIsExactly(sql, $0) }) ?? true {
                unexpected.append("\(type) \(name)")
            }
        }
        objects.finalize()
        guard unexpected.isEmpty else {
            throw BackupError.unexpectedSchema(unexpected.joined(separator: ", "))
        }
    }

    /// Decrypts every attachment and checks it against the recorded digest.
    /// Called after a restore, before the store serves data.
    func verifyAttachmentDigests(fileStore: AttachmentStore?) async throws {
        guard let fileStore else { return }
        for row in try allAttachmentEncryptionRows() {
            let plaintext = try await fileStore.read(storageID: row.storageID)
            guard plaintext.count == row.plaintextLength,
                  fileStore.digest(of: plaintext) == row.digest else {
                throw BackupError.integrityCheckFailed(String(localized: "attachment \(String(row.storageID.prefix(8)))"))
            }
        }
    }

    /// Every destination goes stale after a restore; no bridge may write until
    /// the user reconfirms.
    func suspendSyncDestinations() throws {
        try conn.exec("""
            UPDATE sync_destinations
            SET needs_reconnection = 1, confirmed_at = NULL
            """)
    }
}

/// The manifest as the session and Settings pane render it.
struct BackupManifest: Codable, Sendable {
    var name: String
    var createdAt: Date
    var schemaVersion: Int
    var counts: [String: Int]
}

/// One restore point or portable archive, as listed by the UI.
struct BackupInfo: Sendable {
    let url: URL
    let manifest: BackupManifest
}

enum BackupError: Error, CustomStringConvertible, LocalizedError {
    case missingManifest(URL)
    case missingDatabase(URL)
    case invalidManifest(URL)
    case integrityCheckFailed(String)
    case foreignKeyViolations(Int)
    case countMismatch(String, expected: Int, actual: Int)
    case restoreFailed(String)
    case snapshotUnreadable
    case invalidArchive
    case unexpectedSchema(String)
    case destinationNotConfirmed
    /// A restore failed and the original data could not be put back; the
    /// folder still holds it.
    case rollbackFailed(String, String)
    /// No restore key is available to seal a restore point.
    case restorePointKeyUnavailable
    /// The restore point of the current data could not be made (an attachment
    /// that cannot be read, say), so nothing was replaced. The user may choose
    /// to restore without it.
    case safetyCopyIncomplete(String)
    /// A restore point still sealed under the old public passphrase; the
    /// upgrade pass reseals it under the device key first.
    case restorePointNotUpgraded

    var description: String {
        switch self {
        case let .missingManifest(url): return "backup has no manifest: \(url.path)"
        case let .missingDatabase(url): return "backup has no database: \(url.path)"
        case .invalidArchive: return "the backup archive is not in a form MedNotes can read"
        case let .invalidManifest(url): return "manifest is invalid: \(url.path)"
        case let .integrityCheckFailed(msg): return "integrity check failed: \(msg)"
        case let .foreignKeyViolations(n): return "\(n) foreign key violations"
        case let .countMismatch(entity, expected, actual):
            return "\(entity) count mismatch: expected \(expected), got \(actual)"
        case let .restoreFailed(msg): return "restore failed: \(msg)"
        case .snapshotUnreadable: return "snapshot could not be read"
        case let .unexpectedSchema(detail): return "the backup's schema is not one MedNotes can restore: \(detail)"
        case .destinationNotConfirmed:
            return "the sync destination has not been reconfirmed since the last restore"
        case .restorePointKeyUnavailable: return "no restore key is available for a restore point"
        case let .safetyCopyIncomplete(detail): return "the restore point of the current data could not be made: \(detail)"
        case .restorePointNotUpgraded: return "the restore point is still sealed under the old passphrase"
        case let .rollbackFailed(folder, detail):
            return "restore failed and the original data could not be put back (kept in \(folder)): \(detail)"
        }
    }

    /// What the sheets show. `description` stays English for logs, and the
    /// file path is left out: the sheet already names the file.
    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return String(localized: "This backup has no manifest.")
        case .missingDatabase:
            return String(localized: "This backup contains no database.")
        case .invalidArchive:
            return String(localized: "The backup archive is not in a form MedNotes can read.")
        case .invalidManifest:
            return String(localized: "This backup's manifest is invalid.")
        case let .integrityCheckFailed(detail):
            return String(localized: "Integrity check failed: \(detail)")
        case let .foreignKeyViolations(n):
            return String(localized: "The backup has \(n) broken links between records.")
        case let .countMismatch(entity, expected, actual):
            return String(localized: "The backup's \(entity) count does not match: expected \(expected), found \(actual).")
        case let .restoreFailed(detail):
            return String(localized: "Restore failed: \(detail)")
        case .snapshotUnreadable:
            return String(localized: "The database snapshot could not be read.")
        case let .unexpectedSchema(detail):
            return String(localized: "The backup's schema is not one MedNotes can restore: \(detail)")
        case .destinationNotConfirmed:
            return String(localized: "The sync destination has not been reconfirmed since the last restore.")
        case .restorePointKeyUnavailable:
            return String(localized: "A restore point could not be made because this store has no restore key.")
        case let .safetyCopyIncomplete(detail):
            return String(localized: "A copy of your current data could not be made first, so nothing was changed: \(detail)")
        case .restorePointNotUpgraded:
            return String(localized: "This restore point was made by an older version and has not been converted yet. Lock and unlock MedNotes, then try again.")
        case let .rollbackFailed(folder, detail):
            return String(localized: "The restore failed, and your original data could not be put back. It was kept in “\(folder)”. \(detail)")
        }
    }
}

/// Portable archives and internal restore points.
///
/// Portable archives are always `BackupArchiveV2`, sealed by the user's
/// passphrase. Internal restore points use the same record stream, sealed by a
/// key derived from the device restore key: without that key the file cannot
/// be opened, and no plaintext copy of the store exists at any point.
actor BackupService {
    private let db: Database
    private let fileStore: AttachmentStore?
    private let restorePointsRoot: URL
    /// The device-derived restore key that seals internal restore points.
    /// Nil for a store that has none (the plaintext test and CLI stores), which
    /// cannot make restore points.
    private let restorePointKey: Data?
    /// The plaintext `Files/` tree of a store that is not encrypted yet (the
    /// pre-migration backup), whose attachments have no storage IDs.
    private let legacyFilesRoot: URL?

    init(
        db: Database, fileStore: AttachmentStore?, restorePointsRoot: URL,
        restorePointKey: Data? = nil, legacyFilesRoot: URL? = nil
    ) {
        self.db = db
        self.fileStore = fileStore
        self.restorePointsRoot = restorePointsRoot
        self.restorePointKey = restorePointKey
        self.legacyFilesRoot = legacyFilesRoot
    }

    // MARK: - Portable v2 backup

    /// The canonical export path. The database snapshot is a temporary
    /// SQLCipher database keyed from the archive key, so no plaintext database
    /// is written during backup creation.
    ///
    /// Cancelling the task stops the backup before its next record, and
    /// nothing is left at `fileURL`: a lock cancels the one Back Up runs.
    func createEncryptedBackup(
        name: String = "Backup", to fileURL: URL, passphrase: String,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> BackupManifest {
        if let policyError = BackupPassphrasePolicy.validate(passphrase) {
            throw BackupArchiveV2.ArchiveError.passphrasePolicy(policyError)
        }
        let counts = try await db.counts()
        let legacy = try await legacyAttachments()
        let records = try await attachmentRecords() + legacy.map(\.record)
        let manifest = BackupArchiveV2.Manifest(
            name: name, createdAt: Date(), schemaVersion: Schema.currentVersion,
            counts: counts, attachmentCount: records.count)
        let store = fileStore
        let legacySources = Dictionary(uniqueKeysWithValues: legacy.map { ($0.record.storageID, $0.source) })

        try await BackupArchiveV2.seal(
            manifest: manifest,
            databaseSnapshot: { archiveKey in
                try await self.databaseSnapshotData(archiveKey: archiveKey, legacy: legacy.map(\.record))
            },
            attachments: records,
            attachmentReader: { record in
                if let source = legacySources[record.storageID] { return try Data(contentsOf: source) }
                guard let store else { throw BackupError.invalidArchive }
                return try await store.read(storageID: record.storageID)
            },
            passphrase: passphrase,
            to: fileURL,
            progress: { index, total in progress?(index, total) },
            isCancelled: { Task.isCancelled })

        return BackupManifest(
            name: name, createdAt: manifest.createdAt,
            schemaVersion: manifest.schemaVersion, counts: counts)
    }

    private func databaseSnapshotData(
        archiveKey: Data, legacy: [BackupArchiveV2.AttachmentRecord] = []
    ) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-snapshot-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        try await db.vacuumInto(path: url.path, key: archiveKey)
        if !legacy.isEmpty {
            // The exported copy, not the live plaintext store, learns where
            // each file now lives inside the archive.
            let snapshot = try Database(path: url.path, key: archiveKey)
            do {
                for record in legacy {
                    try await snapshot.setAttachmentEncryption(
                        patientId: UUID(uuidString: record.patientID) ?? UUID(),
                        fileId: UUID(uuidString: record.fileID) ?? UUID(),
                        storageID: record.storageID, plaintextLength: record.plaintextLength,
                        digest: record.digest)
                }
                try await snapshot.checkpoint()
                await snapshot.close()
            } catch {
                await snapshot.close()
                throw error
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            throw BackupError.snapshotUnreadable
        }
        return data
    }

    /// The plaintext store's attachment files, each given the storage ID it
    /// will have inside the archive. A row whose file is missing, or lies
    /// outside `Files/`, is left out exactly as the migration leaves it.
    private func legacyAttachments() async throws
        -> [(record: BackupArchiveV2.AttachmentRecord, source: URL)] {
        guard fileStore == nil, let root = legacyFilesRoot else { return [] }
        let rootPath = root.resolvingSymlinksInPath().path
        var out: [(BackupArchiveV2.AttachmentRecord, URL)] = []
        for (row, relativePath) in try await db.legacyAttachmentRecords() {
            let source = root.appendingPathComponent(relativePath).resolvingSymlinksInPath()
            guard source.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"),
                  let data = try? Data(contentsOf: source) else { continue }
            out.append((BackupArchiveV2.AttachmentRecord(
                fileID: row.fileID, patientID: row.patientID, name: row.name, type: row.type,
                storageID: EncryptedFileStore.newStorageID(),
                plaintextLength: data.count, digest: EncryptedFileStore.digest(of: data),
                uploadDate: row.uploadDate, notes: row.notes, tags: row.tags), source))
        }
        return out
    }

    private func attachmentRecords() async throws -> [BackupArchiveV2.AttachmentRecord] {
        try await db.allAttachmentRecords().map { row in
            BackupArchiveV2.AttachmentRecord(
                fileID: row.fileID, patientID: row.patientID, name: row.name,
                type: row.type, storageID: row.storageID,
                plaintextLength: row.plaintextLength, digest: row.digest,
                uploadDate: row.uploadDate, notes: row.notes, tags: row.tags)
        }
    }

    /// Opens an archive far enough to read its manifest, without touching the
    /// store.
    nonisolated func inspectEncryptedBackup(at fileURL: URL, passphrase: String) throws -> BackupManifest {
        let inspection = try BackupArchiveV2.inspect(at: fileURL, passphrase: passphrase)
        return Self.uiManifest(from: inspection.manifest)
    }

    nonisolated static func uiManifest(from manifest: BackupArchiveV2.Manifest) -> BackupManifest {
        BackupManifest(
            name: manifest.name, createdAt: manifest.createdAt,
            schemaVersion: manifest.schemaVersion, counts: manifest.counts)
    }

    /// Read-only acceptance of a v1 archive. Only the fixed header and the
    /// manifest are read; nothing is extracted.
    nonisolated func inspectLegacyBackup(at fileURL: URL, passphrase: String) throws -> BackupManifest {
        let contents = try LegacyBackupReader.open(at: fileURL, passphrase: passphrase)
        guard let manifestData = contents.manifestData else {
            throw BackupError.missingManifest(fileURL)
        }
        return try Self.decodeJSONData(BackupManifest.self, from: manifestData)
    }

    // MARK: - Restore

    /// Restores a v2 archive into a fresh encrypted store, validates it and
    /// every attachment, creates an encrypted rollback point, and only then
    /// swaps. Nothing live is deleted until the whole install has held.
    func restore(
        fromEncryptedBackupAt fileURL: URL,
        passphrase: String,
        databaseKey: Data,
        attachmentKey: Data,
        createRestorePoint: Bool = true
    ) async throws -> BackupManifest {
        try await restore(
            archiveAt: fileURL, sealing: .passphrase(passphrase),
            databaseKey: databaseKey, attachmentKey: attachmentKey,
            createRestorePoint: createRestorePoint)
    }

    /// Restores one of this store's own restore points, the "Pre-restore" and
    /// "Pre-import" snapshots a restore or an import keeps first. They are
    /// sealed by the device restore key, so only this device's store opens
    /// them. A point from before restore points had a device key is still under
    /// the public passphrase until the upgrade pass has resealed it; restoring
    /// it is refused until then rather than reading it with that passphrase.
    func restore(
        fromRestorePointAt url: URL,
        databaseKey: Data,
        attachmentKey: Data,
        createRestorePoint: Bool = true
    ) async throws -> BackupManifest {
        guard let restorePointKey else { throw BackupError.restorePointKeyUnavailable }
        // Only a file in this store's restore point folder, never a path from elsewhere.
        guard url.pathExtension == "mnrp",
              url.deletingLastPathComponent().standardizedFileURL
                == restorePointsRoot.standardizedFileURL,
              let profile = BackupArchiveV2.profile(at: url) else {
            throw BackupError.invalidArchive
        }
        guard profile == BackupArchiveV2.deviceKeyProfile else {
            throw BackupError.restorePointNotUpgraded
        }
        return try await restore(
            archiveAt: url, sealing: .deviceKey(restorePointKey),
            databaseKey: databaseKey, attachmentKey: attachmentKey,
            createRestorePoint: createRestorePoint)
    }

    private func restore(
        archiveAt fileURL: URL,
        sealing: BackupArchiveV2.Sealing,
        databaseKey: Data,
        attachmentKey: Data,
        createRestorePoint: Bool
    ) async throws -> BackupManifest {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archiveSize = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        try Self.requireFreeSpace(bytes: archiveSize * 2, at: staging)

        let snapshotURL = staging.appendingPathComponent("snapshot.db")
        let stagingAttachments = staging.appendingPathComponent("Attachments", isDirectory: true)
        let stagingStore = try EncryptedFileStore(root: stagingAttachments, key: attachmentKey)
        // One passphrase derivation serves the extraction and the snapshot key.
        let opened = try BackupArchiveV2.openReader(at: fileURL, sealing: sealing)
        defer { try? opened.reader.handle.close() }
        let manifest = try await ArchiveExtraction.extract(
            opened: opened, snapshotURL: snapshotURL, store: stagingStore).manifest
        // A newer build may have written a schema this one does not know.
        guard manifest.schemaVersion <= Schema.currentVersion else {
            throw BackupError.unexpectedSchema(String(localized: "The backup was made by a newer MedNotes."))
        }

        try await ArchiveExtraction.ensureEncryptedSnapshot(at: snapshotURL, key: opened.archiveKey)

        // The staged database and the staged attachments are checked together,
        // before anything live changes.
        try await validateStagedDatabase(
            at: snapshotURL, key: opened.archiveKey, attachments: stagingStore)

        // A lock cancels the restore; it stops here, before a live file moves.
        try Task.checkCancellation()
        if createRestorePoint {
            try await takePreRestorePoint()
        }
        try await readyToInstall()
        try await installStaged(
            databaseAt: snapshotURL, sourceKey: opened.archiveKey,
            attachmentsAt: stagingAttachments)
        return Self.uiManifest(from: manifest)
    }

    /// Proves a backup can be restored, by restoring it completely into a
    /// throwaway store with random keys and checking what came out: the
    /// database passes its integrity and key checks, every attachment decrypts
    /// to its recorded digest, and the record and attachment counts match the
    /// manifest. The live store is never touched.
    @discardableResult
    nonisolated static func verifyFullRestore(of archive: URL, passphrase: String) async throws -> BackupManifest {
        let scratch = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: scratch.rootURL) }
        let rootKey = StoreKeyContext.newRootKey()
        let databaseKey = try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.database)
        let attachmentKey = try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.attachments)
        let throwaway = try AppStore(
            dataRoot: scratch, databaseKey: databaseKey, attachmentKey: attachmentKey,
            restorePointKey: try StoreKeyContext.subkey(rootKey: rootKey, context: StoreKeyContext.restorePoints))
        do {
            let manifest = try await throwaway.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: databaseKey, attachmentKey: attachmentKey, createRestorePoint: false)
            guard try await throwaway.integrity() == "ok",
                  try await throwaway.foreignKeyViolations() == 0 else {
                throw BackupError.integrityCheckFailed(String(localized: "the restored copy"))
            }
            let restored = try await throwaway.counts()
            for (table, expected) in manifest.counts where table != "audit_logs" {
                let actual = restored[table] ?? 0
                guard actual == expected else {
                    throw BackupError.countMismatch(table, expected: expected, actual: actual)
                }
            }
            let attachments = try await throwaway.db.allAttachmentRecords().count
            let recorded = try BackupArchiveV2.inspect(at: archive, passphrase: passphrase)
                .manifest.attachmentCount
            guard attachments == recorded else {
                throw BackupError.countMismatch("attachments", expected: recorded, actual: attachments)
            }
            await throwaway.close()
            return manifest
        } catch {
            await throwaway.close()
            throw error
        }
    }

    /// Reads a v1 archive, extracts entry by entry with the containment checks
    /// in `LegacyBackupReader`, imports logically into a fresh encrypted
    /// database, then swaps.
    func restore(
        fromLegacyBackupAt fileURL: URL,
        passphrase: String,
        databaseKey: Data,
        attachmentKey: Data,
        createRestorePoint: Bool = true
    ) async throws -> BackupManifest {
        let contents = try LegacyBackupReader.open(at: fileURL, passphrase: passphrase)
        guard let manifestData = contents.manifestData else {
            throw BackupError.missingManifest(fileURL)
        }
        let manifest = try Self.decodeJSONData(BackupManifest.self, from: manifestData)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-legacy-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try LegacyBackupReader.extract(contents, to: staging)

        let snapshotURL = staging.appendingPathComponent("mednotes.db")
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw BackupError.missingDatabase(fileURL)
        }
        try Task.checkCancellation()
        if createRestorePoint {
            try await takePreRestorePoint()
        }
        let built = staging.appendingPathComponent("encrypted", isDirectory: true)
        let stagingStore = try await buildEncryptedStaging(
            from: snapshotURL,
            legacyFilesRoot: staging.appendingPathComponent("Files", isDirectory: true),
            into: built, destinationKey: databaseKey, attachmentKey: attachmentKey)
        let stagedDatabase = built.appendingPathComponent("mednotes.db")
        try await validateStagedDatabase(
            at: stagedDatabase, key: databaseKey, attachments: stagingStore)
        try await readyToInstall()
        try await installStaged(
            databaseAt: stagedDatabase, sourceKey: nil,
            attachmentsAt: built.appendingPathComponent("Attachments", isDirectory: true))
        return manifest
    }

    // MARK: - Encrypted restore points

    /// The copy of the current data a restore keeps first. One attachment that
    /// cannot be read must not make a damaged store impossible to replace from
    /// a good backup, so that failure is its own error and the caller may
    /// restore without the copy, by choice. A lock (cancellation) and the
    /// restore-key error pass through unchanged.
    private func takePreRestorePoint() async throws {
        do {
            _ = try await createEncryptedRestorePoint(name: "Pre-restore snapshot")
        } catch let error as BackupError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackupError.safetyCopyIncomplete(error.localizedDescription)
        }
    }

    /// Internal restore points are v2 archives sealed by the device restore
    /// key. They are listed and deleted by name and never leave the container.
    func createEncryptedRestorePoint(name: String) async throws -> String {
        guard let restorePointKey else { throw BackupError.restorePointKeyUnavailable }
        try FileManager.default.createDirectory(at: restorePointsRoot, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())
        let unique = UUID().uuidString.prefix(8)
        let fileName = "restore_\(stamp)_\(unique).mnrp"
        let url = restorePointsRoot.appendingPathComponent(fileName)

        let counts = try await db.counts()
        let records = try await attachmentRecords()
        let store = fileStore
        let manifest = BackupArchiveV2.Manifest(
            name: name, createdAt: Date(), schemaVersion: Schema.currentVersion,
            counts: counts, attachmentCount: records.count)

        try await BackupArchiveV2.seal(
            manifest: manifest,
            databaseSnapshot: { archiveKey in
                try await self.databaseSnapshotData(archiveKey: archiveKey)
            },
            attachments: records,
            attachmentReader: { record in
                guard let store else { throw BackupError.invalidArchive }
                return try await store.read(storageID: record.storageID)
            },
            sealing: .deviceKey(restorePointKey),
            to: url)
        // A small sidecar so listing does not run Argon2 per point. It holds
        // only the generic point label and counts, never patient data.
        try Self.writeRestorePointSidecar(manifest, for: url)
        return fileName
    }

    /// The fixed passphrase the first restore points were sealed under. It is
    /// public, so it is used only to read those points once and reseal them
    /// under the device key (`upgradeLegacyRestorePoints`); nothing new is
    /// ever sealed with it.
    static let legacyRestorePointPassphrase = String(repeating: "MedNotesRestorePoint", count: 2)

    /// Reseals restore points written before restore points had a device key
    /// (profile 1, readable with the public passphrase) under the device key,
    /// replacing each file in place with its name, date and sidecar intact.
    /// A point that cannot be converted is left as it is, never deleted.
    /// Stops between points, and between records, when the task is cancelled
    /// (a lock). Returns how many points were converted.
    @discardableResult
    func upgradeLegacyRestorePoints() async -> Int {
        guard let restorePointKey,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: restorePointsRoot, includingPropertiesForKeys: nil) else { return 0 }
        var converted = 0
        for url in entries where url.pathExtension == "mnrp" {
            if Task.isCancelled { break }
            guard BackupArchiveV2.profile(at: url) == BackupArchiveV2.KDFProfile.argon2id64MiB3Ops.rawValue
            else { continue }
            do {
                try await upgrade(pointAt: url, restorePointKey: restorePointKey)
                converted += 1
            } catch {
                SecurityLog.record(.restorePointUpgradeFailed)
            }
        }
        return converted
    }

    private func upgrade(pointAt url: URL, restorePointKey: Data) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("mednotes-upgrade-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let snapshotURL = staging.appendingPathComponent("snapshot.db")
        // The attachments only pass through here: this store's key is random
        // and never leaves memory.
        let store = try EncryptedFileStore(
            root: staging.appendingPathComponent("Attachments", isDirectory: true),
            key: StoreKeyContext.newRootKey())
        let opened = try BackupArchiveV2.openReader(
            at: url, passphrase: Self.legacyRestorePointPassphrase)
        defer { try? opened.reader.handle.close() }
        let extracted = try await ArchiveExtraction.extract(
            opened: opened, snapshotURL: snapshotURL, store: store)
        let oldKey = opened.archiveKey

        let upgraded = staging.appendingPathComponent("upgraded.mnrp")
        try await BackupArchiveV2.seal(
            manifest: extracted.manifest,
            databaseSnapshot: { newKey in
                let copy = staging.appendingPathComponent("rekeyed.db")
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: snapshotURL, to: copy)
                try Database.rekey(path: copy.path, from: oldKey, to: newKey)
                return try Data(contentsOf: copy)
            },
            attachments: extracted.attachments,
            attachmentReader: { record in try await store.read(storageID: record.storageID) },
            sealing: .deviceKey(restorePointKey),
            to: upgraded,
            isCancelled: { Task.isCancelled })
        // Deleted while converting: do not bring it back.
        guard fm.fileExists(atPath: url.path) else { return }
        _ = try fm.replaceItemAt(url, withItemAt: upgraded)
    }

    /// A PHI-free metadata sidecar beside each restore point.
    struct RestorePointSidecar: Codable {
        var name: String
        var createdAt: Date
        var counts: [String: Int]
    }

    private nonisolated static func sidecarURL(for url: URL) -> URL {
        url.appendingPathExtension("json")
    }

    nonisolated static func writeRestorePointSidecar(
        _ manifest: BackupArchiveV2.Manifest, for url: URL) throws {
        let sidecar = RestorePointSidecar(
            name: manifest.name, createdAt: manifest.createdAt, counts: manifest.counts)
        try Self.sidecarEncoder.encode(sidecar).write(to: sidecarURL(for: url), options: [.atomic])
    }

    nonisolated func listRestorePoints() throws -> [BackupInfo] {
        guard FileManager.default.fileExists(atPath: restorePointsRoot.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: restorePointsRoot, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
        var infos: [BackupInfo] = []
        for entry in entries where entry.pathExtension == "mnrp" {
            let fallbackDate = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let sidecar = (try? Data(contentsOf: Self.sidecarURL(for: entry)))
                .flatMap { try? Self.sidecarDecoder.decode(RestorePointSidecar.self, from: $0) }
            infos.append(BackupInfo(
                url: entry,
                manifest: BackupManifest(
                    name: sidecar?.name ?? Self.restorePointName(from: entry),
                    createdAt: sidecar?.createdAt ?? fallbackDate,
                    schemaVersion: Schema.currentVersion,
                    counts: sidecar?.counts ?? [:])))
        }
        return infos.sorted { lhs, rhs in
            if lhs.manifest.createdAt != rhs.manifest.createdAt {
                return lhs.manifest.createdAt > rhs.manifest.createdAt
            }
            // Two points made within one run of the clock fall back to the
            // file's own creation time, which is finer.
            return Self.creationDate(of: lhs.url) > Self.creationDate(of: rhs.url)
        }
    }

    /// Fractional seconds are required: seven points made in a tight loop share
    /// a whole second, and ordering by whole seconds would be a coin toss.
    private nonisolated static let sidecarEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        return encoder
    }()

    private nonisolated static let sidecarDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            guard let date = try? LenientDate.decode(string) else {
                throw LenientDateError.unsupported
            }
            return date
        }
        return decoder
    }()

    private nonisolated static func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private nonisolated static func restorePointName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    nonisolated func removeRestorePoint(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: url))
    }

    nonisolated static func sizeOnDisk(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            let size = (try? url.resourceValues(forKeys: keys).fileSize) ?? 0
            return Int64(size)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static let restorePointsToKeep = 5

    nonisolated func pruneRestorePoints(keeping: Int = BackupService.restorePointsToKeep) throws -> [BackupInfo] {
        let stale = Array(try listRestorePoints().dropFirst(max(keeping, 1)))
        for info in stale {
            try FileManager.default.removeItem(at: info.url)
            try? FileManager.default.removeItem(at: Self.sidecarURL(for: info.url))
        }
        return stale
    }

    // MARK: - Validation and staging

    /// Opens the staged snapshot under `key` and checks it, together with the
    /// staged attachment store: every row's file must exist, decrypt, and match
    /// its recorded length and digest.
    private func validateStagedDatabase(
        at url: URL, key: Data, attachments: AttachmentStore
    ) async throws {
        try Database.validateSnapshotFile(path: url.path, key: key)
        let staging = try Database(path: url.path, key: key)
        do {
            let integrity = try await staging.integrityCheck()
            guard integrity == "ok" else { throw BackupError.integrityCheckFailed(integrity) }
            let fk = try await staging.foreignKeyCheck()
            guard fk == 0 else { throw BackupError.foreignKeyViolations(fk) }
            try await staging.validateExpectedSchema()
            try await staging.verifyAttachmentDigests(fileStore: attachments)
            // Checkpoint and close so the staged file is self-contained: a
            // `-wal` left behind would still be keyed with the archive key and
            // would corrupt the rekeyed main file.
            try await staging.checkpoint()
            try await staging.close()
        } catch {
            try? await staging.close()
            throw error
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Test seam: runs once everything is staged and checked, just before the
    /// install, so a test can land a lock at the last point a restore can stop.
    var beforeInstallForTesting: (@Sendable () async -> Void)?

    func setBeforeInstallForTesting(_ hook: (@Sendable () async -> Void)?) {
        beforeInstallForTesting = hook
    }

    /// The last point a restore can be cancelled. Past it the swap runs to its
    /// end, or is rolled back, and is never abandoned half way.
    private func readyToInstall() async throws {
        await beforeInstallForTesting?()
        try Task.checkCancellation()
    }

    /// Test seam: runs after the database swap and the attachment swap, before
    /// the live store is verified, so a test can fail the install late.
    var installFaultForTesting: (() throws -> Void)?

    func setInstallFaultForTesting(_ fault: (() throws -> Void)?) {
        installFaultForTesting = fault
    }

    /// Installs a validated database and attachment tree. The live database
    /// and attachment directory are moved aside, not deleted, and are put back
    /// byte for byte if any step fails; they are removed only once the
    /// installed store has been verified. If putting them back fails too, the
    /// folder holding them is kept and named in the error.
    private func installStaged(
        databaseAt snapshotURL: URL, sourceKey: Data?, attachmentsAt stagedAttachments: URL
    ) async throws {
        let fm = FileManager.default
        let root = restorePointsRoot.deletingLastPathComponent()
        let liveAttachments = root.appendingPathComponent("Attachments", isDirectory: true)
        let kept = root.appendingPathComponent(
            "\(RestoreRecovery.rollbackPrefix)\(UUID().uuidString)", isDirectory: true)
        let keptAttachments = kept.appendingPathComponent("Attachments", isDirectory: true)

        // The journal is what lets a launch undo an install that a crash cut
        // off (`RestoreRecovery`): it exists before anything live moves.
        do {
            try fm.createDirectory(at: kept, withIntermediateDirectories: true)
            try RestoreRecovery.writeJournal(.started, in: kept)
        } catch {
            try? fm.removeItem(at: kept)
            throw BackupError.restoreFailed("install: \(error.localizedDescription)")
        }

        do {
            try await db.replaceDatabaseFile(
                with: snapshotURL.path, sourceKey: sourceKey, preservingOriginalIn: kept)
        } catch let error as RestoreRollbackError {
            throw BackupError.rollbackFailed(kept.path, error.localizedDescription)
        } catch {
            try? fm.removeItem(at: kept)
            throw BackupError.restoreFailed("install: \(error.localizedDescription)")
        }

        var attachmentsMoved = false
        do {
            try RestoreRecovery.writeJournal(.databaseReplaced, in: kept)
            if fm.fileExists(atPath: liveAttachments.path) {
                try fm.moveItem(at: liveAttachments, to: keptAttachments)
                attachmentsMoved = true
                try RestoreRecovery.writeJournal(.attachmentsAside, in: kept)
            }
            try fm.moveItem(at: stagedAttachments, to: liveAttachments)
            try RestoreRecovery.writeJournal(.attachmentsIn, in: kept)
            try installFaultForTesting?()
            try await db.suspendSyncDestinations()
            if let fileStore {
                try await db.verifyAttachmentDigests(fileStore: fileStore)
            }
            try RestoreRecovery.writeJournal(.verified, in: kept)
        } catch {
            do {
                try await db.reinstateDatabaseFile(from: kept)
                if attachmentsMoved {
                    try? fm.removeItem(at: liveAttachments)
                    try fm.moveItem(at: keptAttachments, to: liveAttachments)
                }
            } catch let rollbackError {
                throw BackupError.rollbackFailed(kept.path, rollbackError.localizedDescription)
            }
            try? fm.removeItem(at: kept)
            throw BackupError.restoreFailed("install: \(error.localizedDescription)")
        }
        // Renamed first, so the delete cannot be half applied to a folder that
        // still looks like a rollback: a crash during it leaves a discard folder
        // that the next launch simply deletes.
        let discard = root.appendingPathComponent(
            "\(RestoreRecovery.discardPrefix)\(UUID().uuidString)", isDirectory: true)
        if (try? fm.moveItem(at: kept, to: discard)) != nil {
            try? fm.removeItem(at: discard)
        } else {
            try? fm.removeItem(at: kept)
        }
    }

    /// Builds, beside nothing live, an encrypted database and attachment store
    /// from a legacy plaintext snapshot: records are copied logically, and each
    /// legacy file is encrypted into the returned staging store.
    private func buildEncryptedStaging(
        from snapshotURL: URL, legacyFilesRoot: URL, into stagingRoot: URL,
        destinationKey: Data, attachmentKey: Data
    ) async throws -> EncryptedFileStore {
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let encryptedURL = stagingRoot.appendingPathComponent("mednotes.db")
        let stagingAttachments = stagingRoot.appendingPathComponent("Attachments", isDirectory: true)
        let store = try EncryptedFileStore(root: stagingAttachments, key: attachmentKey)
        let plainReader = try Database(path: snapshotURL.path)
        let encrypted = try Database(path: encryptedURL.path, key: destinationKey)
        do {
            let patients = try await plainReader.loadAllPatients(includeArchived: true)
            let notes = try await plainReader.loadAllNotes()
            let todos = try await plainReader.loadAllTodos(includeCompleted: true)
            let events = try await plainReader.loadAllEvents()
            try await encrypted.importBatch(patients: patients, notes: notes, todos: todos, events: events)
            // Custom templates, and edits to the shipped ones, are not part of
            // `importBatch`.
            for template in try await plainReader.customTemplates() {
                try await encrypted.saveTemplate(template)
            }
            for entry in try await plainReader.recentAuditLogs(limit: -1) {
                try await encrypted.logAudit(entry)
            }
            for file in try await encrypted.attachmentsNeedingEncryption() {
                let source = legacyFilesRoot.appendingPathComponent(file.relativePath)
                guard let plaintext = try? Data(contentsOf: source) else { continue }
                let storageID = try await store.store(plaintext)
                try await encrypted.setAttachmentEncryption(
                    patientId: UUID(uuidString: file.patientId) ?? UUID(),
                    fileId: UUID(uuidString: file.fileId) ?? UUID(),
                    storageID: storageID,
                    plaintextLength: plaintext.count,
                    digest: store.digest(of: plaintext))
            }
            try await encrypted.checkpoint()
            try await plainReader.close()
            try await encrypted.close()
        } catch {
            try? await plainReader.close()
            try? await encrypted.close()
            throw error
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: encryptedURL.path + suffix)
        }
        return store
    }

    // MARK: - Helpers

    nonisolated static func requireFreeSpace(bytes: Int64, at url: URL) throws {
        guard bytes > 0 else { return }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw BackupArchiveV2.ArchiveError.insufficientSpace
        }
    }

    nonisolated static func decodeJSONData<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            if let string = try? container.decode(String.self), let date = try? LenientDate.decode(string) {
                return date
            }
            if let double = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: double)
            }
            throw LenientDateError.unsupported
        }
        return try decoder.decode(type, from: data)
    }
}

