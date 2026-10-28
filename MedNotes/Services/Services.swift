import Foundation

actor AuditService {
    private let db: Database
    init(db: Database) { self.db = db }

    func log(action: String, entityType: String, entityId: String, details: String = "") async throws {
        let entry = AuditLogEntry(action: action, entityType: entityType, entityId: entityId, details: details)
        try await db.logAudit(entry)
    }

    func recentLogs(limit: Int = 100) async throws -> [AuditLogEntry] {
        try await db.recentAuditLogs(limit: limit)
    }

    func latest(action: String) async throws -> AuditLogEntry? {
        try await db.latestAuditLog(action: action)
    }
}

actor PatientService {
    private let db: Database
    private let audit: AuditService
    private let filesRoot: URL?
    /// When present, attachment bytes go here and nowhere else. Legacy
    /// `filesRoot` is kept so a plaintext store (dry-run importer, tests) still
    /// works, but production always supplies both.
    private let fileStore: AttachmentStore?

    init(db: Database, audit: AuditService, filesRoot: URL? = nil, fileStore: AttachmentStore? = nil) {
        self.db = db
        self.audit = audit
        self.filesRoot = filesRoot
        self.fileStore = fileStore
    }

    /// `knownFileIDs`: the attachment ids the editor loaded this draft with,
    /// when the caller has them; see `Database.savePatient`.
    func save(_ patient: Patient, knownFileIDs: Set<UUID>? = nil) async throws {
        var stored = patient
        stored.lastModified = Date()
        // The archive flag changes only through `archive` and `unarchive`. An
        // editor autosaving a draft it loaded before the record was archived
        // must not quietly restore it — that is exactly what happens when a
        // patient with unsaved edits is archived from the toolbar.
        if let existing = try await db.loadPatient(id: patient.id) {
            stored.isArchived = existing.isArchived
        }
        var createdPatientDir = false
        var staged: [(URL, URL)] = []
        var promoted: FilePromote.Transaction?
        // Every encrypted object this save writes is new, and the objects it
        // replaces stay untouched until the database has committed.
        var newStorageIDs: [String] = []
        let previousStorageIDs = Set(
            try await db.loadPatientFiles(patientId: patient.id).compactMap(\.storageID))
        do {
            if let fileStore {
                let encrypted = try await stageEncryptedFileBytes(patient.files, fileStore: fileStore)
                stored.files = encrypted.files
                newStorageIDs = encrypted.created
            } else if let root = filesRoot {
                let patientDir = root.appendingPathComponent(patient.id.uuidString, isDirectory: true)
                createdPatientDir = !FileManager.default.fileExists(atPath: patientDir.path)
                let written = try await stageFileBytes(patient.files, patientId: patient.id, root: root)
                stored.files = written.files
                staged = written.staged
            }
            promoted = try FilePromote.apply(staged)
            try await db.savePatient(
                stored, attachmentReferences: patient.files.filter { $0.data == nil },
                knownFileIDs: knownFileIDs)
            promoted?.commit()
            promoted = nil
        } catch {
            if let fileStore {
                // The database kept its old rows, so the old objects are still
                // the live ones; only what this save wrote is discarded.
                for id in newStorageIDs { try? await fileStore.remove(storageID: id) }
            }
            promoted?.rollback()
            for (tmp, _) in staged {
                try? FileManager.default.removeItem(at: tmp)
            }
            if createdPatientDir, let root = filesRoot {
                let patientDir = root.appendingPathComponent(patient.id.uuidString, isDirectory: true)
                try? FileManager.default.removeItem(at: patientDir)
            }
            throw error
        }
        if let root = filesRoot, fileStore == nil {
            removeOrphanedFiles(patient.files, patientId: patient.id, root: root)
        }
        if let fileStore {
            await removeSupersededObjects(previousStorageIDs, fileStore: fileStore)
        }
        // A new or renamed patient can be what a note's [[link]] names.
        try? await db.resolveAllLinks()
        try await audit.log(
            action: "patient_save", entityType: "patient", entityId: patient.id.uuidString,
            details: "patient saved")
    }

    /// Encrypts any file that arrived with inline bytes, each under a fresh
    /// storage ID, and returns metadata carrying that ID, the length and the
    /// digest. No plaintext file is created at any point, and no existing
    /// object is overwritten: a rejected save must leave committed content as
    /// it was. On failure the objects written so far are removed here.
    private func stageEncryptedFileBytes(
        _ files: [PatientFile], fileStore: AttachmentStore
    ) async throws -> (files: [PatientFile], created: [String]) {
        var stored: [PatientFile] = []
        var created: [String] = []
        do {
            for file in files {
                guard let data = file.data else {
                    stored.append(file)
                    continue
                }
                let storageID = try await fileStore.store(data, storageID: nil)
                created.append(storageID)
                var meta = file
                meta.data = nil
                meta.fileSize = data.count
                meta.storageID = storageID
                meta.plaintextLength = data.count
                meta.contentDigest = fileStore.digest(of: data)
                stored.append(meta)
            }
        } catch {
            for id in created { try? await fileStore.remove(storageID: id) }
            throw error
        }
        return (stored, created)
    }

    /// After a commit: the objects the patient used to point at and no row
    /// points at any more (a replaced or removed attachment) are deleted.
    private func removeSupersededObjects(_ previous: Set<String>, fileStore: AttachmentStore) async {
        guard !previous.isEmpty, let referenced = try? await db.referencedStorageIDs() else { return }
        for id in previous where !referenced.contains(id.lowercased()) {
            try? await fileStore.remove(storageID: id)
        }
    }

    private func stageFileBytes(_ files: [PatientFile], patientId: UUID, root: URL) async throws -> (files: [PatientFile], staged: [(URL, URL)]) {
        let fm = FileManager.default
        let patientDir = root.appendingPathComponent(patientId.uuidString, isDirectory: true)
        var stored: [PatientFile] = []
        var staged: [(URL, URL)] = []
        do {
            for file in files {
                guard let data = file.data else {
                    stored.append(file)
                    continue
                }
                try fm.createDirectory(at: patientDir, withIntermediateDirectories: true)
                let dest = patientDir.appendingPathComponent(file.id.uuidString)
                let tmp = patientDir.appendingPathComponent(
                    "\(file.id.uuidString).staging-\(UUID().uuidString)")
                try data.write(to: tmp, options: [.atomic])
                staged.append((tmp, dest))
                var meta = file
                meta.data = nil
                meta.fileSize = data.count
                stored.append(meta)
            }
            return (stored, staged)
        } catch {
            for (tmp, _) in staged {
                try? fm.removeItem(at: tmp)
            }
            throw error
        }
    }

    private func removeOrphanedFiles(_ files: [PatientFile], patientId: UUID, root: URL) {
        FilePromote.removeOrphans(files: files, patientId: patientId, root: root)
    }

    func delete(id: UUID) async throws {
        try await remove(id: id, action: "patient_delete", details: "Deleted patient")
    }

    /// Housekeeping removal of a record the user created and then left exactly
    /// as created (`Patient.isUntouchedNewRecord`). The same deletion as
    /// `delete`, audited under its own action so the trail never shows a user
    /// deleting a patient they never named. A no-op for a row already gone.
    func discard(id: UUID) async throws {
        guard try await db.patientExists(id: id) else { return }
        try await remove(id: id, action: "patient_discard", details: "Discarded untouched new patient")
    }

    private func remove(id: UUID, action: String, details: String) async throws {
        let files = try await db.loadPatientFiles(patientId: id)
        try await db.deletePatient(id: id)
        if let fileStore {
            for file in files {
                guard let storageID = file.storageID else { continue }
                try? await fileStore.remove(storageID: storageID)
            }
        } else if let root = filesRoot {
            let patientDir = root.appendingPathComponent(id.uuidString, isDirectory: true)
            if FileManager.default.fileExists(atPath: patientDir.path) {
                // Row is already gone; leftover files must not fail the delete
                // or the UI will treat a successful delete as an error.
                try? FileManager.default.removeItem(at: patientDir)
            }
        }
        try await audit.log(
            action: action, entityType: "patient", entityId: id.uuidString,
            details: details)
    }

    /// Decrypts one attachment into memory. Plaintext never becomes a file on
    /// this path; see `EncryptedFileStore.openExternally` for the one
    /// controlled export.
    func loadFileData(patientId: UUID, fileId: UUID) async throws -> Data? {
        if let fileStore,
           let storageID = try await db.attachmentStorageID(patientId: patientId, fileId: fileId) {
            return try await fileStore.read(storageID: storageID)
        }
        guard let root = filesRoot,
              let rel = try await db.loadFileRelativePath(patientId: patientId, fileId: fileId)
        else { return nil }
        let url = root.appendingPathComponent(rel).resolvingSymlinksInPath()
        let rootURL = root.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        let filePath = url.path
        let isInside = filePath == rootPath
            || filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        guard isInside else { return nil }
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Writes a decrypted 0600 temporary copy for "Open Externally". The UI
    /// must show the disclosure before calling this, and the returned URL is
    /// tracked so locking removes it.
    func prepareExternalOpen(patientId: UUID, fileId: UUID) async throws -> URL? {
        guard let fileStore,
              let storageID = try await db.attachmentStorageID(patientId: patientId, fileId: fileId),
              let meta = try await db.loadPatientFiles(patientId: patientId)
                .first(where: { $0.id == fileId })
        else { return nil }
        return try await fileStore.openExternally(storageID: storageID, preferredName: meta.name)
    }

    func clearExternalTemporaries() async {
        await fileStore?.clearExternalTemporaries()
    }

    func load(id: UUID) async throws -> Patient? {
        try await db.loadPatient(id: id)
    }

    func loadAll(includeArchived: Bool = true) async throws -> [Patient] {
        try await db.loadAllPatients(includeArchived: includeArchived)
    }

    func search(_ query: String, limit: Int = 10_000, includeArchived: Bool = false) async throws -> [Patient] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await db.loadAllPatients(includeArchived: includeArchived)
        }
        return try await db.searchPatients(query, limit: limit, includeArchived: includeArchived)
    }

    /// Hides a patient from the active list and the pickers while keeping the
    /// row and every note, todo and event linked to it. This is what the UI's
    /// trash does for patients now; `unarchive` reverses it, and `delete` is
    /// reached only from the archived list.
    func archive(id: UUID) async throws {
        try await setArchived(true, id: id, action: "patient_archive", details: "Archived patient")
    }

    func unarchive(id: UUID) async throws {
        try await setArchived(false, id: id, action: "patient_unarchive", details: "Restored patient")
    }

    private func setArchived(_ archived: Bool, id: UUID, action: String, details: String) async throws {
        guard var patient = try await db.loadPatient(id: id), patient.isArchived != archived else { return }
        patient.isArchived = archived
        patient.lastModified = Date()
        try await db.savePatient(patient)
        try await audit.log(action: action, entityType: "patient", entityId: id.uuidString, details: details)
    }
}

actor NoteService {
    private let db: Database
    private let audit: AuditService
    private let linking: LinkingService?

    init(db: Database, audit: AuditService, linking: LinkingService? = nil) {
        self.db = db
        self.audit = audit
        self.linking = linking
    }

    func save(_ note: Note) async throws {
        var updated = note
        updated.updatedAt = Date()
        try await db.saveNote(updated)
        // Post-commit side effect. The database write above is authoritative;
        // the link graph must never turn a saved note into an error surfaced
        // to the user.
        if let linking {
            do {
                try await linking.relink(note: updated)
            } catch {
                try? await audit.log(
                    action: "link_relink_failed", entityType: "note",
                    entityId: note.id.uuidString,
                    details: error.localizedDescription)
            }
        }
        try await audit.log(
            action: "note_save", entityType: "note", entityId: note.id.uuidString,
            details: "note saved")
    }

    func load(id: UUID) async throws -> Note? { try await db.loadNote(id: id) }

    func loadAll() async throws -> [Note] { try await db.loadAllNotes() }

    func delete(id: UUID) async throws {
        try await remove(id: id, action: "note_delete")
    }

    /// Housekeeping removal of a note created and then left exactly as created
    /// (`Note.isUntouchedNewRecord`); audited separately from a user deletion.
    /// A no-op for a row already gone.
    func discard(id: UUID) async throws {
        guard try await db.loadNote(id: id) != nil else { return }
        try await remove(id: id, action: "note_discard")
    }

    private func remove(id: UUID, action: String) async throws {
        try await db.deleteNote(id: id)
        // The note's own link rows cascade via FK, and links in other notes
        // that named it are resolved again inside `deleteNote`.
        try await audit.log(action: action, entityType: "note", entityId: id.uuidString)
    }

    func search(_ query: String, limit: Int = 10_000) async throws -> [Note] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await db.loadAllNotes()
        }
        return try await db.searchNotes(query, limit: limit)
    }

    /// The notes for a search text and a tag filter (a tag key), read together.
    func list(search query: String, tagKey: String?) async throws -> [Note] {
        try await db.notesFiltered(query: query, tagKey: tagKey)
    }

    /// The ids of the notes a search text matches (empty for blank or
    /// unsearchable text), without loading them.
    func matchingIDs(_ text: String) async throws -> Set<String> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await db.noteIDs(matching: SearchQuery.parse(trimmed))
    }

    func tagCounts() async throws -> [TagCount] { try await db.tagCounts() }

    func propertyKeys() async throws -> [PropertyKeyUsage] { try await db.propertyKeys() }

    func aliasMatches(_ text: String, limit: Int = 3) async throws -> [AliasMatch] {
        try await db.aliasMatches(key: WikiLinkParser.normalizedKey(text), limit: limit)
    }

    func headings(noteId: UUID) async throws -> [HeadingRow] { try await db.headings(noteId: noteId) }

    func togglePin(id: UUID) async throws {
        try await db.toggleNotePinned(id: id)
        try await audit.log(action: "note_pin", entityType: "note", entityId: id.uuidString)
    }
}

actor TodoService {
    private let db: Database
    private let audit: AuditService

    init(db: Database, audit: AuditService) {
        self.db = db
        self.audit = audit
    }

    /// Returns the row as persisted (stamped `updatedAt`, completion stamp
    /// reconciled, dangling patient link dropped) so callers that push to
    /// Apple Reminders compare against what the database actually holds.
    @discardableResult
    func save(_ todo: TodoItem) async throws -> TodoItem {
        var t = todo
        t.updatedAt = Date()
        if t.isCompleted && t.completedAt == nil {
            t.completedAt = Date()
        }
        if !t.isCompleted {
            t.completedAt = nil
        }
        if let pid = t.patientId {
            if try await !db.patientExists(id: pid) {
                t.patientId = nil
                t.patientName = nil
            } else if let patient = try await db.loadPatient(id: pid) {
                let name = patient.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                t.patientName = name.isEmpty ? nil : name
            }
        }
        try await db.saveTodo(t)
        try await audit.log(
            action: "todo_save", entityType: "todo", entityId: t.id.uuidString,
            details: "todo saved")
        return t
    }

    /// Persists sync-driven changes without stamping `updatedAt`, so the last
    /// local-edit time stays truthful for last-writer-wins comparisons.
    func saveSyncResult(_ todo: TodoItem) async throws {
        var t = todo
        if t.isCompleted && t.completedAt == nil {
            t.completedAt = Date()
        }
        if !t.isCompleted {
            t.completedAt = nil
        }
        if let pid = t.patientId, try await !db.patientExists(id: pid) {
            t.patientId = nil
            t.patientName = nil
        }
        try await db.saveTodo(t)
    }

    func load(id: UUID) async throws -> TodoItem? { try await db.loadTodo(id: id) }

    func loadAll(includeCompleted: Bool = true) async throws -> [TodoItem] {
        try await db.loadAllTodos(includeCompleted: includeCompleted)
    }

    func toggle(id: UUID) async throws {
        try await db.toggleTodoCompleted(id: id)
        try await audit.log(action: "todo_toggle", entityType: "todo", entityId: id.uuidString)
    }

    func delete(id: UUID) async throws {
        try await remove(id: id, action: "todo_delete")
    }

    /// Housekeeping removal of a todo created and then left exactly as created
    /// (`TodoItem.isUntouchedNewRecord`); audited separately from a user
    /// deletion. A no-op for a row already gone.
    func discard(id: UUID) async throws {
        guard try await db.loadTodo(id: id) != nil else { return }
        try await remove(id: id, action: "todo_discard")
    }

    private func remove(id: UUID, action: String) async throws {
        try await db.deleteTodo(id: id)
        try await audit.log(action: action, entityType: "todo", entityId: id.uuidString)
    }
}

actor CalendarEventService {
    private let db: Database
    private let audit: AuditService

    init(db: Database, audit: AuditService) {
        self.db = db
        self.audit = audit
    }

    /// Returns the row as persisted (stamped `updatedAt`, clamped end date,
    /// dropped dangling patient link) so callers that push to Apple Calendar
    /// compare against what the database actually holds.
    @discardableResult
    func save(_ event: CalendarEvent) async throws -> CalendarEvent {
        var stored = event
        stored.updatedAt = Date()
        stored.ensureEndNotBeforeStart()
        if let pid = stored.patientId, try await !db.patientExists(id: pid) {
            stored.patientId = nil
        }
        try await db.saveEvent(stored)
        try await audit.log(
            action: "event_save", entityType: "calendar_event", entityId: event.id.uuidString,
            details: "event saved")
        return stored
    }

    /// Persists sync-driven changes without stamping `updatedAt`, so the last
    /// local-edit time stays truthful for last-writer-wins comparisons.
    func saveSyncResult(_ event: CalendarEvent) async throws {
        var stored = event
        stored.ensureEndNotBeforeStart()
        if let pid = stored.patientId, try await !db.patientExists(id: pid) {
            stored.patientId = nil
        }
        try await db.saveEvent(stored)
    }

    func load(id: UUID) async throws -> CalendarEvent? { try await db.loadEvent(id: id) }

    func loadAll() async throws -> [CalendarEvent] { try await db.loadAllEvents() }

    func delete(id: UUID) async throws {
        try await remove(id: id, action: "event_delete")
    }

    /// Housekeeping removal of an event created and then left exactly as
    /// created (`CalendarEvent.isUntouchedNewRecord`); audited separately from
    /// a user deletion. A no-op for a row already gone.
    func discard(id: UUID) async throws {
        guard try await db.loadEvent(id: id) != nil else { return }
        try await remove(id: id, action: "event_discard")
    }

    private func remove(id: UUID, action: String) async throws {
        try await db.deleteEvent(id: id)
        try await audit.log(action: action, entityType: "calendar_event", entityId: id.uuidString)
    }
}

enum FilePromote {
    struct Transaction {
        let backups: [(old: URL, dest: URL)]
        let created: [URL]

        func commit() {
            for (old, _) in backups {
                try? FileManager.default.removeItem(at: old)
            }
        }

        func rollback() {
            let fm = FileManager.default
            for dest in created.reversed() {
                try? fm.removeItem(at: dest)
            }
            for (old, dest) in backups.reversed() {
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: old, to: dest)
            }
        }
    }

    /// Move staged files into place. On a mid-batch failure, earlier dests are
    /// restored and the error is thrown. On success the caller must `commit()`
    /// (drop backups) or `rollback()` (restore them) after the DB write.
    @discardableResult
    static func apply(_ staged: [(URL, URL)]) throws -> Transaction {
        let fm = FileManager.default
        var backups: [(old: URL, dest: URL)] = []
        var created: [URL] = []
        do {
            for (tmp, dest) in staged {
                if fm.fileExists(atPath: dest.path) {
                    let old = dest.deletingLastPathComponent()
                        .appendingPathComponent("\(dest.lastPathComponent).old-\(UUID().uuidString)")
                    try fm.moveItem(at: dest, to: old)
                    backups.append((old, dest))
                    do {
                        try fm.moveItem(at: tmp, to: dest)
                    } catch {
                        try? fm.removeItem(at: dest)
                        try? fm.moveItem(at: old, to: dest)
                        try? fm.removeItem(at: tmp)
                        backups.removeLast()
                        throw error
                    }
                } else {
                    try fm.moveItem(at: tmp, to: dest)
                    created.append(dest)
                }
            }
            return Transaction(backups: backups, created: created)
        } catch {
            for dest in created.reversed() {
                try? fm.removeItem(at: dest)
            }
            for (old, dest) in backups.reversed() {
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: old, to: dest)
            }
            throw error
        }
    }

    static func removeOrphans(files: [PatientFile], patientId: UUID, root: URL) {
        let fm = FileManager.default
        let patientDir = root.appendingPathComponent(patientId.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: patientDir.path) else { return }
        let keptIDs = Set(files.map(\.id.uuidString))
        let existing = (try? fm.contentsOfDirectory(atPath: patientDir.path)) ?? []
        for name in existing where !keptIDs.contains(name) {
            try? fm.removeItem(atPath: patientDir.appendingPathComponent(name).path)
        }
    }
}
