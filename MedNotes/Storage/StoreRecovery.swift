import Foundation

/// Recovery for the one case that cannot use `BackupService`: encrypted data
/// exists but its Keychain key is gone.
///
/// The live store cannot be opened to be replaced, so this path never opens
/// it. It restores the portable archive's snapshot and attachments under a
/// brand-new device key, swaps them into place, and stores that key last.
///
/// Nothing changes until the backup has been read with its passphrase and
/// the restored database opens under the new key: a wrong passphrase or a
/// damaged archive leaves the store and the Keychain exactly as they were.
/// Recovery refuses outright while the Keychain still holds a usable key,
/// because restoring would replace a healthy store with the backup's older
/// contents.
actor StoreRecovery {
    enum RecoveryError: Error, LocalizedError {
        case noPortableBackup
        case archiveInvalid(String)
        case installFailed(String)
        /// The Keychain still holds a usable key, so the store is not lost.
        case deviceKeyPresent

        var errorDescription: String? {
            switch self {
            case .noPortableBackup:
                return String(localized: "Choose a portable backup to recover this store.")
            case .archiveInvalid(let detail):
                return String(localized: "The backup could not be read: \(detail)")
            case .installFailed(let detail):
                return String(localized: "Recovery failed: \(detail)")
            case .deviceKeyPresent:
                return String(localized: "This store's device key is still in the Keychain, so nothing was restored. Quit and reopen MedNotes to unlock it.")
            }
        }
    }

    private let dataRoot: DataRoot
    private let keyManager: KeyManager

    init(dataRoot: DataRoot, keyManager: KeyManager) {
        self.dataRoot = dataRoot
        self.keyManager = keyManager
    }

    struct Report: Sendable {
        var restoredAt: Date
        var attachmentCount: Int
        /// The new device key, already in the Keychain. Handed back so the
        /// session opens the store without another Touch ID prompt.
        var rootKey: Data
    }

    /// Restores `backupURL` over the unreadable store with a brand-new device
    /// key. See the type's documentation for what a failure leaves behind.
    func recover(from backupURL: URL, passphrase: String) async throws -> Report {
        // Only a key that is provably gone (or damaged) may be replaced. A
        // read that fails, such as a cancelled Touch ID prompt, throws
        // `keyUnavailable` here: it proves nothing about the key.
        let existing = try keyManager.lookUpRootKey()
        if case .present = existing { throw RecoveryError.deviceKeyPresent }

        // The new key lives only in memory until the restored store validates.
        let rootKey = StoreKeyContext.newRootKey()
        let databaseKey = try StoreKeyContext.subkey(
            rootKey: rootKey, context: StoreKeyContext.database)
        let attachmentKey = try StoreKeyContext.subkey(
            rootKey: rootKey, context: StoreKeyContext.attachments)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let snapshotURL = staging.appendingPathComponent("snapshot.db")
        let stagingAttachments = staging.appendingPathComponent("Attachments", isDirectory: true)
        let store = try EncryptedFileStore(root: stagingAttachments, key: attachmentKey)
        // One passphrase derivation serves the extraction and the snapshot key.
        let opened: BackupArchiveV2.OpenedArchive
        let manifest: BackupArchiveV2.Manifest
        do {
            opened = try BackupArchiveV2.openReader(at: backupURL, passphrase: passphrase)
        } catch {
            throw RecoveryError.archiveInvalid(error.localizedDescription)
        }
        defer { try? opened.reader.handle.close() }
        do {
            manifest = try await ArchiveExtraction.extract(
                opened: opened, snapshotURL: snapshotURL, store: store).manifest
        } catch {
            throw RecoveryError.archiveInvalid(error.localizedDescription)
        }

        do {
            try await ArchiveExtraction.ensureEncryptedSnapshot(at: snapshotURL, key: opened.archiveKey)
        } catch {
            throw RecoveryError.archiveInvalid(error.localizedDescription)
        }

        // Validate the snapshot under the archive key before anything moves.
        var validation: Database?
        do {
            // Before it is opened, and so migrated: its triggers and views first.
            try Database.validateSnapshotFile(path: snapshotURL.path, key: opened.archiveKey)
            let candidate = try Database(path: snapshotURL.path, key: opened.archiveKey)
            validation = candidate
            let validation = candidate
            let integrity = try await validation.integrityCheck()
            guard integrity == "ok" else {
                throw BackupError.integrityCheckFailed(integrity)
            }
            let fk = try await validation.foreignKeyCheck()
            guard fk == 0 else { throw BackupError.foreignKeyViolations(fk) }
            try await validation.validateExpectedSchema()
            // A recovered store is a restored backup: no bridge may write to a
            // destination until the user confirms it again, exactly as after a
            // normal restore. Suspend them in the snapshot before it is swapped
            // in, so the live store never carries a confirmed destination.
            try await validation.suspendSyncDestinations()
            // Every row's file must exist and match its recorded length and
            // digest before the unreadable store is moved aside.
            try await validation.verifyAttachmentDigests(fileStore: store)
            try await validation.checkpoint()
            await validation.close()
        } catch {
            await validation?.close()
            throw RecoveryError.archiveInvalid(error.localizedDescription)
        }
        Self.removeSidecars(at: snapshotURL)

        // Rekey before the swap, so the incoming pages never touch the live
        // path under the archive key, and prove the result opens under the
        // new device key.
        do {
            try Self.rekey(path: snapshotURL.path, from: opened.archiveKey, to: databaseKey)
            let check = try SQLConnection(path: snapshotURL.path, key: databaseKey)
            defer { check.close() }
            try check.exec("SELECT count(*) FROM sqlite_master")
        } catch {
            throw RecoveryError.installFailed(error.localizedDescription)
        }
        Self.removeSidecars(at: snapshotURL)

        try install(snapshotURL: snapshotURL, stagingAttachments: stagingAttachments,
                    rootKey: rootKey, replacingDamagedKey: existing == .damaged)
        return Report(restoredAt: Date(), attachmentCount: manifest.attachmentCount, rootKey: rootKey)
    }

    /// Swaps the restored files in and stores the new key as one step. The
    /// old database, its WAL and the old attachments are moved aside first
    /// and put back if anything fails; they are removed only once the key is
    /// in the Keychain.
    ///
    /// The key goes last on purpose. A crash before it leaves no key, which
    /// reopens on the recovery screen; a key stored before the files would
    /// be a key that opens nothing, and recovery would refuse to replace it.
    private func install(
        snapshotURL: URL, stagingAttachments: URL, rootKey: Data, replacingDamagedKey: Bool
    ) throws {
        let fm = FileManager.default
        let databaseURL = dataRoot.databaseURL
        let root = dataRoot.rootURL
        let moves: [(live: URL, aside: URL)] = [
            (databaseURL, root.appendingPathComponent("Unreadable.db")),
            (URL(fileURLWithPath: databaseURL.path + "-wal"), root.appendingPathComponent("Unreadable.db-wal")),
            (URL(fileURLWithPath: databaseURL.path + "-shm"), root.appendingPathComponent("Unreadable.db-shm")),
            (dataRoot.attachmentsURL, root.appendingPathComponent("Unreadable.Attachments", isDirectory: true)),
        ]
        // Leftovers of an interrupted earlier recovery are as unreadable as
        // the store they came from.
        for move in moves { try? fm.removeItem(at: move.aside) }

        var movedAside: [(live: URL, aside: URL)] = []
        var installed: [URL] = []
        do {
            for move in moves where fm.fileExists(atPath: move.live.path) {
                try fm.moveItem(at: move.live, to: move.aside)
                movedAside.append(move)
            }
            try fm.moveItem(at: snapshotURL, to: databaseURL)
            installed.append(databaseURL)
            try fm.moveItem(at: stagingAttachments, to: dataRoot.attachmentsURL)
            installed.append(dataRoot.attachmentsURL)
            if replacingDamagedKey { try keyManager.deleteRootKey() }
            try keyManager.storeRootKey(rootKey)
        } catch {
            for url in installed { try? fm.removeItem(at: url) }
            for move in movedAside.reversed() { try? fm.moveItem(at: move.aside, to: move.live) }
            throw RecoveryError.installFailed(error.localizedDescription)
        }

        // Only now are the unreadable bytes removed.
        for move in movedAside { try? fm.removeItem(at: move.aside) }
    }

    private static func removeSidecars(at url: URL) {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// The same page-read-then-rekey sequence `Database` uses. Duplicated here
    /// because the recovering store has no `Database` to ask.
    private static func rekey(path: String, from oldKey: Data, to newKey: Data) throws {
        let conn = try SQLConnection(path: path, key: oldKey)
        try conn.exec("SELECT count(*) FROM sqlite_master")
        try conn.exec("PRAGMA journal_mode = DELETE")
        let hex = newKey.map { String(format: "%02x", $0) }.joined()
        try conn.exec("PRAGMA rekey = \"x'\(hex)'\"")
        conn.close()
    }
}
