import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Backups, restore, the one-time Markdown export, file panels, and the legacy import.
extension AppSession {
    // MARK: - Backups

    enum BackupFlow: Identifiable {
        case backUp
        case restore(fileURL: URL)

        var id: String {
            switch self {
            case .backUp: return "backUp"
            case .restore(let url): return "restore:\(url.path)"
            }
        }
    }

    /// Whether the store is open for the menu commands: ready, unlocked, with
    /// a store behind the curtain. A sheet opened while locked would sit above
    /// the curtain, and a session that lost its key has nothing to act on.
    var canUseStore: Bool {
        isReady && !isLocked && !needsRecovery && store != nil
    }

    func presentBackup() {
        guard canUseStore else { return }
        backupFlow = .backUp
    }

    /// Picks the archive first; the passphrase is asked for in the sheet.
    func presentRestore() async {
        guard canUseStore else { return }
        let chosen = await choose(FilePanelRequest(
            kind: .file(types: [.data]),
            message: String(localized: "Choose a MedNotes backup (.\(EncryptedBackupFormat.fileExtension)).")))
        // A lock closes the panel, and a choice that lands after one is dropped.
        guard let url = chosen, canUseStore else { return }
        backupFlow = .restore(fileURL: url)
    }

    func dismissBackupFlow() {
        backupFlow = nil
    }

    // MARK: File panels and what leaves the container

    /// Shows a file panel where a lock can still reach the session, and
    /// returns what the user chose: nil when they cancelled, a lock closed
    /// the panel, or the session locked before it could open.
    ///
    /// `runModal()` spins a nested run loop until the panel closes. Inside a
    /// main-actor job, as every `Task` and `async` method here runs, that
    /// loop cannot drain the main queue, which the job itself holds: every
    /// other main-actor task waits for the panel, the lock's among them, since
    /// the system lock events and the idle check each lock through a `Task`.
    /// Back Up and the Markdown export ran their panels that way, so a screen
    /// lock or sleep with the panel open left the store open and its keys in
    /// memory until the panel closed, and the lock then landed under the
    /// backup or export the panel had just started. From a run-loop block, as
    /// AppKit runs a menu command, the job has already suspended: the panel's
    /// loop drains the queue as `NSApp.run` does, and a lock goes ahead and
    /// closes the panel (`closeStore`). Default mode only, so a panel never
    /// opens inside a menu being tracked or another modal session.
    private func choose(_ request: FilePanelRequest) async -> URL? {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                let url = MainActor.assumeIsolated {
                    // A lock that ran first leaves nothing to choose for.
                    self.canUseStore ? self.panels.run(request) : nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    /// Runs `work`, a backup or export writing outside the container, as a
    /// task of its own that a lock cancels. It is registered before `work`
    /// starts, so a lock at any point from here on reaches it.
    private func runOutgoing<T: Sendable>(
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let task = Task { @MainActor in try await work() }
        let token = UUID()
        outgoing[token] = task.cancel
        defer { outgoing[token] = nil }
        return try await task.value
    }

    /// Runs the deliberate one-time export to a user-chosen folder. The number
    /// and kinds of records are returned so the confirmation can name them, and
    /// the caller labels the result plaintext. Nil when no folder was chosen
    /// or a lock stopped the export.
    ///
    /// The store is read after the panel, never before: a lock while it was
    /// up closed it. The export is on the audit trail before any plaintext
    /// leaves the app, and one the trail cannot record does not run. A lock
    /// while the files are written stops the export before its next note, and
    /// Settings › Data says how many went (`markdownExportInterruption`).
    func exportMarkdownVault() async throws -> MarkdownExportService.ExportReport? {
        guard canUseStore else { throw StoreNotOpenError() }
        markdownExportInterruption = nil
        let chosen = await choose(FilePanelRequest(
            kind: .folder(canCreate: true),
            message: String(localized: "Choose a folder for the plaintext Markdown export.")))
        guard let url = chosen, canUseStore, let store else { return nil }
        let locksAtStart = lockRequests
        let service = MarkdownExportService(db: store.db)
        let noteCount: Int
        let report: MarkdownExportService.ExportReport
        do {
            // One task from the folder on: a lock while the notes are read or
            // audited cancels it as surely as one while they are written.
            let outcome = try await runOutgoing {
                let prepared = try await service.prepare()
                try await store.audit.log(
                    action: "markdown_export", entityType: "export", entityId: url.lastPathComponent,
                    details: "notes=\(prepared.noteCount) bytes=\(prepared.byteCount)")
                await self.outgoingWillBegin()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return (prepared.noteCount, try await service.write(prepared, to: url))
            }
            noteCount = outcome.0
            report = outcome.1
        } catch where lockRequests != locksAtStart {
            // Nothing was written: the lock closed the store under the read or
            // the audit.
            return nil
        }
        if report.wasCancelled {
            // Said where the export was asked for. The Settings pane that asked
            // is rebuilt by the lock, and the main window may be closed.
            markdownExportInterruption = String(localized: "MedNotes locked during the Markdown export: \(report.notesWritten) of \(noteCount) notes were written to “\(url.lastPathComponent)” as plaintext before it stopped. Export again to write them all.")
            return nil
        }
        if !report.failures.isEmpty {
            // A partial export must not read as a complete one. The report
            // names the notes that were written; this says the rest were not.
            markdownExportInterruption = String(localized: "The Markdown export wrote \(report.notesWritten) of \(noteCount) notes to “\(url.lastPathComponent)”; \(report.failures.count) could not be written. Export again to write them all.")
            return nil
        }
        notice = String(localized: "Exported \(report.notesWritten) notes as plaintext Markdown.")
        return report
    }

    /// What Settings › Data shows after the mirror is retired: every note the
    /// vault knew about, classified against the database. Nil before upgrade
    /// scanning or when there is no vault folder.
    func legacyVaultReport() async -> VaultReconciliation.Report? {
        guard let store, let dataRoot else { return nil }
        let root = dataRoot.vaultURL
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let scan = VaultReconciliation.scan(root: root)
        let notes = (try? await store.db.loadAllNotes()) ?? []
        var report = VaultReconciliation.reconcile(vaultNotes: scan.notes, databaseNotes: notes)
        report.parseFailures = scan.failures
        return report
    }

    /// Takes the vault's copy of a divergent note. The mirror is deleted only
    /// after every divergent item has been resolved.
    func resolveVaultItem(_ item: VaultReconciliation.Item, takeVaultCopy: Bool) async throws {
        guard takeVaultCopy, let dataRoot else { return }
        let store = try openStore()
        let scan = VaultReconciliation.scan(root: dataRoot.vaultURL)
        guard let entry = scan.notes.first(where: { $0.note.id == item.noteID }) else { return }
        try await store.notes.save(entry.note)
        noteEpoch += 1
        await reload()
    }

    /// Deletes the retired plaintext mirror. Only reached after the user has
    /// seen the reconciliation report and confirmed.
    func deleteLegacyVault() async throws {
        guard let store, let dataRoot else { return }
        let url = dataRoot.vaultURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try? await store.audit.log(
            action: "legacy_vault_delete", entityType: "vault", entityId: "vault",
            details: "Deleted the retired plaintext Markdown mirror")
        notice = String(localized: "The plaintext Markdown mirror was deleted.")
    }

    /// Asks where the archive goes, then writes it there.
    ///
    /// The store and its keys are read after the panel, never before: a lock
    /// while it was up closed them. A lock while the archive is written
    /// cancels it (`closeStore`): it stops before its next record, leaves
    /// nothing where the user chose, and the alert after the unlock says so.
    func performBackup(name: String, passphrase: String) async throws {
        guard canUseStore else { return }
        let chosen = await choose(FilePanelRequest(
            kind: .save(suggestedName: "\(name).\(BackupArchiveV2.fileExtension)"),
            message: String(localized: "The backup is encrypted with the passphrase you entered.")))
        guard let url = chosen, canUseStore, let store, let coordinator else { return }
        _ = try coordinator.requireAttachmentKey()
        let locksAtStart = lockRequests
        let manifest: BackupManifest
        do {
            let progress = backupProgress
            manifest = try await runOutgoing {
                await self.outgoingWillBegin()
                return try await store.backups.createEncryptedBackup(
                    name: name, to: url, passphrase: passphrase, progress: progress)
            }
        } catch where lockRequests != locksAtStart {
            // The lock took BackupFlowSheet, and the error it would show, with
            // it; ContentView holds this alert until the unlock.
            errorMessage = String(localized: "MedNotes locked before the backup was finished, so nothing was saved to “\(url.lastPathComponent)”. Choose File › Back Up… to make one.")
            return
        }
        try? await store.audit.log(
            action: "backup_create", entityType: "backup", entityId: url.lastPathComponent,
            details: BackupFlowSheet.summary(of: manifest))
        backupFlow = nil
        notice = String(localized: "Backed up to \(url.lastPathComponent): \(BackupFlowSheet.summary(of: manifest)).")
    }

    func inspectBackup(at fileURL: URL, passphrase: String) async throws -> BackupManifest {
        guard let store else { throw BackupError.invalidArchive }
        // v1 archives are accepted read-only; v2 is the write format. Only a
        // file that is not v2 at all is tried as v1: a wrong passphrase or a
        // damaged v2 archive must report that, not "not a MedNotes backup".
        do {
            return try store.backups.inspectEncryptedBackup(at: fileURL, passphrase: passphrase)
        } catch BackupArchiveV2.ArchiveError.notAnArchive {
            return try store.backups.inspectLegacyBackup(at: fileURL, passphrase: passphrase)
        }
    }

    func performRestore(from fileURL: URL, passphrase: String) async throws {
        guard let store, let coordinator else { return }
        let databaseKey = try coordinator.requireDatabaseKey()
        let attachmentKey = try coordinator.requireAttachmentKey()
        let manifest: BackupManifest
        do {
            do {
                manifest = try await store.backups.restore(
                    fromEncryptedBackupAt: fileURL, passphrase: passphrase,
                    databaseKey: databaseKey, attachmentKey: attachmentKey)
            } catch BackupArchiveV2.ArchiveError.notAnArchive {
                // Only a container that is not v2 at all is tried as v1. Any
                // other failure is about a v2 archive and must not be retried
                // against a store that a failed install may have touched.
                manifest = try await store.backups.restore(
                    fromLegacyBackupAt: fileURL, passphrase: passphrase,
                    databaseKey: databaseKey, attachmentKey: attachmentKey)
            }
        } catch let error as BackupError {
            if case .rollbackFailed = error {
                // The live files may be half replaced: nothing may use this
                // session. The folder named in the message holds the originals.
                errorMessage = error.localizedDescription
                await lockNow(reason: "restore-rollback-failed")
            }
            throw error
        }
        try? await store.audit.log(
            action: "backup_restore", entityType: "backup", entityId: fileURL.lastPathComponent,
            details: BackupFlowSheet.summary(of: manifest))
        await pruneRestorePoints()
        // Every record may have changed identity; start the UI over. Sync is
        // suspended until the user reconfirms each destination.
        selectedNoteId = nil
        selectedPatientId = nil
        selectedTodoId = nil
        selectedEventId = nil
        noteEpoch += 1
        patientEpoch += 1
        todoEpoch += 1
        eventEpoch += 1
        await reload()
        await reloadPatients()
        await reloadPatientDirectory()
        await reloadTodos()
        await reloadEvents()
        // The restore marked every destination stale in the database; make
        // Settings › Sync show that instead of the pre-restore confirmation.
        await refreshSyncDestinations()
        // Health and pass summaries belonged to the store just replaced.
        integrityWarning = nil
        lastCalendarSyncSummary = nil
        lastRemindersSyncSummary = nil
        backupFlow = nil
        notice = String(localized: "Restored \(DisplayCopy.backupName(manifest.name)): \(BackupFlowSheet.summary(of: manifest)). Reconnect Calendar and Reminders before syncing again.")
    }

    // MARK: - Legacy import

    struct ImportFlow: Identifiable {
        let folderURL: URL
        var id: String { folderURL.path }
    }

    /// Picks the legacy folder; the sheet dry-runs it before anything is written.
    func presentImport() async {
        guard canUseStore else { return }
        var lastFolder: URL?
        if let data = defaults.data(forKey: Self.legacyImportBookmarkKey) {
            var stale = false
            lastFolder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let chosen = await choose(FilePanelRequest(
            kind: .folder(canCreate: false),
            message: String(localized: "Choose the legacy MedNotes folder — the one containing Patients, Notes, Todos and CalendarEvents."),
            directoryURL: lastFolder))
        // A lock closes the panel, and a choice that lands after one is dropped.
        guard let url = chosen, canUseStore else { return }
        // Keep the grant so a later run starts where this one did.
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.legacyImportBookmarkKey)
        }
        importFlow = ImportFlow(folderURL: url)
    }

    func dismissImportFlow() {
        importFlow = nil
    }

    /// The folder read into a throwaway store: the report is exactly what the
    /// real import would do, and the real store is not touched.
    func dryRunImport(from folderURL: URL) async throws -> ImportReport {
        let scratch = try DataRoot.temporary()
        defer { try? FileManager.default.removeItem(at: scratch.rootURL) }
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        let db = try Database(path: scratch.databaseURL.path)
        // The same attachment path as the real import, into a store of its own
        // that is removed with the scratch root, so both report the same things.
        let report = try await JSONImporter(directoryURL: folderURL)
            .importAll(
                into: db,
                fileStore: EncryptedFileStore(
                    root: scratch.attachmentsURL, key: StoreKeyContext.newRootKey()))
        await db.close()
        return report
    }

    /// Restore point first: the importer is idempotent, but a folder full of
    /// surprises must never be a one-way door.
    func performImport(from folderURL: URL) async throws {
        guard let store else { return }
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        _ = try await store.backups.createEncryptedRestorePoint(name: "Pre-import snapshot")
        // Legacy JSON import stages through the encrypted attachment store:
        // an inline file is encrypted on save, never written beside the store.
        let report = try await JSONImporter(directoryURL: folderURL)
            .importAll(into: store.db, filesRoot: nil, fileStore: store.fileStore)
        try? await store.audit.log(
            action: "import_legacy", entityType: "import", entityId: folderURL.lastPathComponent,
            details: ImportFlowSheet.summary(of: report))
        await pruneRestorePoints()
        noteEpoch += 1
        patientEpoch += 1
        todoEpoch += 1
        eventEpoch += 1
        await reload()
        await reloadPatients()
        await reloadPatientDirectory()
        await reloadTodos()
        await reloadEvents()
        importFlow = nil
        notice = String(localized: "Imported \(ImportFlowSheet.summary(of: report)).")
    }
}
