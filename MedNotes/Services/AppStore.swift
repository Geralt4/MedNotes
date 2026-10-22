import Foundation

/// The unlocked application store. Construction requires a database key, so
/// there is no way to build one from a locked coordinator.
actor AppStore {
    let dataRoot: DataRoot
    let db: Database
    let audit: AuditService
    let patients: PatientService
    let notes: NoteService
    let todos: TodoService
    let events: CalendarEventService
    let backups: BackupService
    let linking: LinkingService
    let templates: TemplateService
    let fileStore: EncryptedFileStore
    let destinations: SyncDestinationStore

    /// Production path: encrypted database, encrypted attachments, and the new
    /// backup service. The keys must come from `SecureStoreCoordinator`.
    init(dataRoot: DataRoot, databaseKey: Data, attachmentKey: Data, restorePointKey: Data) throws {
        self.dataRoot = dataRoot
        self.db = try Database(path: dataRoot.databaseURL.path, key: databaseKey)
        self.audit = AuditService(db: db)
        self.fileStore = try EncryptedFileStore(
            root: dataRoot.attachmentsURL, key: attachmentKey,
            externalCopiesURL: dataRoot.externalCopiesURL)
        self.patients = PatientService(
            db: db, audit: audit, filesRoot: nil, fileStore: fileStore)
        self.linking = LinkingService(db: db)
        self.templates = TemplateService(db: db, audit: audit)
        self.todos = TodoService(db: db, audit: audit)
        self.events = CalendarEventService(db: db, audit: audit)
        self.backups = BackupService(
            db: db, fileStore: fileStore, restorePointsRoot: dataRoot.restorePointsURL,
            restorePointKey: restorePointKey)
        self.destinations = SyncDestinationStore(db: db)
        self.notes = NoteService(db: db, audit: audit, linking: linking)
    }

    /// Plaintext construction for tests, the dry-run importer and the CLI.
    /// Never called from the app target: the production initializer above is
    /// the only one the UI can reach.
    init(plaintextDataRoot dataRoot: DataRoot) throws {
        self.dataRoot = dataRoot
        self.db = try Database(path: dataRoot.databaseURL.path)
        self.audit = AuditService(db: db)
        self.fileStore = try EncryptedFileStore(
            root: dataRoot.attachmentsURL,
            key: StoreKeyContext.subkey(
                rootKey: Data(repeating: 0x42, count: 32),
                context: StoreKeyContext.attachments),
            externalCopiesURL: dataRoot.externalCopiesURL)
        self.patients = PatientService(db: db, audit: audit, filesRoot: dataRoot.filesURL)
        self.linking = LinkingService(db: db)
        self.templates = TemplateService(db: db, audit: audit)
        self.todos = TodoService(db: db, audit: audit)
        self.events = CalendarEventService(db: db, audit: audit)
        self.backups = BackupService(
            db: db, fileStore: nil, restorePointsRoot: dataRoot.restorePointsURL)
        self.destinations = SyncDestinationStore(db: db)
        self.notes = NoteService(db: db, audit: audit, linking: linking)
    }

    func counts() async throws -> [String: Int] {
        try await db.counts()
    }

    func integrity() async throws -> String {
        try await db.integrityCheck()
    }

    func foreignKeyViolations() async throws -> Int {
        try await db.foreignKeyCheck()
    }

    /// Deletes attachment objects no row refers to. Skipped, never guessed,
    /// when the references cannot be read.
    @discardableResult
    func sweepOrphanedAttachments(minimumAge: TimeInterval = 3600) async -> Int {
        guard let referenced = try? await db.referencedStorageIDs() else { return 0 }
        return await fileStore.sweepOrphans(referenced: referenced, minimumAge: minimumAge)
    }

    func close() async {
        await patients.clearExternalTemporaries()
        await db.close()
    }
}
