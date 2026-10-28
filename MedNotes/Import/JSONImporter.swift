import Foundation

struct JSONImporter {
    let directoryURL: URL

    enum Subfolder: String, CaseIterable {
        case patients = "Patients"
        case notes = "Notes"
        case todos = "Todos"
        case calendarEvents = "CalendarEvents"
    }

    struct Batch {
        var patients: [Patient] = []
        var notes: [Note] = []
        var todos: [TodoItem] = []
        var events: [CalendarEvent] = []
        var report = ImportReport()
    }

    /// `fileStore`: where inline attachment bytes go. With it, every inline
    /// file is encrypted under a fresh storage ID before the batch commits,
    /// read back and checked, and removed again if the batch fails. Without
    /// one (the plaintext dry run and CLI) the bytes go to `filesRoot`, or
    /// are dropped when that is nil too.
    func importAll(
        into db: Database, filesRoot: URL? = nil, fileStore: AttachmentStore? = nil
    ) async throws -> ImportReport {
        var batch = try scanAndDecode()
        let existing = Set((try await db.loadAllPatients(includeArchived: true)).map(\.id))
        let known = existing.union(batch.patients.map(\.id))
        Self.unlinkMissingPatients(&batch, knownPatients: known)
        var createdFileDirs: [URL] = []
        var stagedFiles: [(URL, URL)] = []
        var promoted: FilePromote.Transaction?
        var createdStorageIDs: [String] = []
        var supersededStorageIDs = Set<String>()
        do {
            if let fileStore {
                let staged = try await Self.stageEncryptedFiles(
                    batch.patients, db: db, fileStore: fileStore, report: &batch.report)
                batch.patients = staged.patients
                createdStorageIDs = staged.created
                supersededStorageIDs = staged.superseded
            }
            if let filesRoot {
                let persisted = try Self.stagePatientFiles(batch.patients, to: filesRoot)
                batch.patients = persisted.patients
                createdFileDirs = persisted.createdDirs
                stagedFiles = persisted.staged
            }
            promoted = try FilePromote.apply(stagedFiles)
            try await db.importBatch(
                patients: batch.patients,
                notes: batch.notes,
                todos: batch.todos,
                events: batch.events)
            promoted?.commit()
            promoted = nil
            if let fileStore, !supersededStorageIDs.isEmpty,
               let referenced = try? await db.referencedStorageIDs() {
                for id in supersededStorageIDs where !referenced.contains(id.lowercased()) {
                    try? await fileStore.remove(storageID: id)
                }
            }
            if let filesRoot {
                for patient in batch.patients {
                    FilePromote.removeOrphans(
                        files: patient.files, patientId: patient.id, root: filesRoot)
                }
            }
        } catch {
            if let fileStore {
                for id in createdStorageIDs { try? await fileStore.remove(storageID: id) }
            }
            promoted?.rollback()
            for (tmp, _) in stagedFiles {
                try? FileManager.default.removeItem(at: tmp)
            }
            for dir in createdFileDirs {
                try? FileManager.default.removeItem(at: dir)
            }
            throw error
        }
        return batch.report
    }

    private func scanAndDecode() throws -> Batch {
        var batch = Batch()
        var patientIds = Set<UUID>()

        var noteIds = Set<UUID>()
        var todoIds = Set<UUID>()
        var eventIds = Set<UUID>()

        for url in try jsonFiles(in: .patients) {
            do {
                let patient = try decode(Patient.self, at: url)
                if patientIds.contains(patient.id) {
                    batch.report.filesSkipped += 1
                    batch.report.warnings.append(
                        String(localized: "\(url.lastPathComponent): duplicate patient \(patient.id.uuidString.prefix(8)), skipped"))
                    continue
                }
                batch.patients.append(patient)
                patientIds.insert(patient.id)
                batch.report.patientsImported += 1
            } catch {
                batch.report.filesSkipped += 1
                batch.report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        for url in try jsonFiles(in: .notes) {
            do {
                let note = try decode(Note.self, at: url)
                if noteIds.contains(note.id) {
                    batch.report.filesSkipped += 1
                    batch.report.warnings.append(
                        String(localized: "\(url.lastPathComponent): duplicate note \(note.id.uuidString.prefix(8)), skipped"))
                    continue
                }
                batch.notes.append(note)
                noteIds.insert(note.id)
                batch.report.notesImported += 1
            } catch {
                batch.report.filesSkipped += 1
                batch.report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        for url in try jsonFiles(in: .todos) {
            do {
                let todo = try decode(TodoItem.self, at: url)
                if todoIds.contains(todo.id) {
                    batch.report.filesSkipped += 1
                    batch.report.warnings.append(
                        String(localized: "\(url.lastPathComponent): duplicate todo \(todo.id.uuidString.prefix(8)), skipped"))
                    continue
                }
                batch.todos.append(todo)
                todoIds.insert(todo.id)
                batch.report.todosImported += 1
            } catch {
                batch.report.filesSkipped += 1
                batch.report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        for url in try jsonFiles(in: .calendarEvents) {
            do {
                let event = try decode(CalendarEvent.self, at: url)
                if eventIds.contains(event.id) {
                    batch.report.filesSkipped += 1
                    batch.report.warnings.append(
                        String(localized: "\(url.lastPathComponent): duplicate event \(event.id.uuidString.prefix(8)), skipped"))
                    continue
                }
                batch.events.append(event)
                eventIds.insert(event.id)
                batch.report.eventsImported += 1
            } catch {
                batch.report.filesSkipped += 1
                batch.report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return batch
    }

    /// Encrypts each inline file into `fileStore` and fills in its storage
    /// metadata. A file that arrives without bytes keeps the content the
    /// store already has for the same file (a re-import must not detach it);
    /// one with neither is reported. Everything written is read back and
    /// checked before the batch may commit; on any failure it is removed here.
    private static func stageEncryptedFiles(
        _ patients: [Patient], db: Database, fileStore: AttachmentStore, report: inout ImportReport
    ) async throws -> (patients: [Patient], created: [String], superseded: Set<String>) {
        var result: [Patient] = []
        var created: [String] = []
        var superseded = Set<String>()
        do {
            for var patient in patients {
                let existing = Dictionary(
                    try await db.loadPatientFiles(patientId: patient.id).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                var stored: [PatientFile] = []
                for var file in patient.files {
                    let previous = existing[file.id]
                    if let data = file.data {
                        let storageID = try await fileStore.store(data, storageID: nil)
                        created.append(storageID)
                        let digest = fileStore.digest(of: data)
                        guard try await fileStore.read(storageID: storageID) == data else {
                            throw ImportError.attachmentVerification(file.name)
                        }
                        file.data = nil
                        file.fileSize = data.count
                        file.storageID = storageID
                        file.plaintextLength = data.count
                        file.contentDigest = digest
                        if let old = previous?.storageID { superseded.insert(old) }
                    } else if file.storageID == nil {
                        if let previous, let old = previous.storageID {
                            file.storageID = old
                            file.plaintextLength = previous.plaintextLength
                            file.contentDigest = previous.contentDigest
                        } else {
                            report.warnings.append(
                                String(localized: "\(file.name): the file has no content to import"))
                        }
                    }
                    stored.append(file)
                }
                patient.files = stored
                result.append(patient)
            }
            return (result, created, superseded)
        } catch {
            for id in created { try? await fileStore.remove(storageID: id) }
            throw error
        }
    }

    private static func stagePatientFiles(_ patients: [Patient], to root: URL) throws -> (patients: [Patient], createdDirs: [URL], staged: [(URL, URL)]) {
        let fm = FileManager.default
        var result: [Patient] = []
        var createdDirs: [URL] = []
        var staged: [(URL, URL)] = []
        result.reserveCapacity(patients.count)
        do {
            for var patient in patients {
                let dir = root.appendingPathComponent(patient.id.uuidString, isDirectory: true)
                let dirExisted = fm.fileExists(atPath: dir.path)
                var stored: [PatientFile] = []
                stored.reserveCapacity(patient.files.count)
                for file in patient.files {
                    guard let data = file.data else {
                        stored.append(file)
                        continue
                    }
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if !dirExisted, createdDirs.last != dir {
                        createdDirs.append(dir)
                    }
                    let dest = dir.appendingPathComponent(file.id.uuidString)
                    let tmp = dir.appendingPathComponent(
                        "\(file.id.uuidString).staging-\(UUID().uuidString)")
                    try data.write(to: tmp, options: [.atomic])
                    staged.append((tmp, dest))
                    var meta = file
                    meta.data = nil
                    meta.fileSize = data.count
                    stored.append(meta)
                }
                patient.files = stored
                result.append(patient)
            }
            return (result, createdDirs, staged)
        } catch {
            for (tmp, _) in staged {
                try? fm.removeItem(at: tmp)
            }
            for dir in createdDirs {
                try? fm.removeItem(at: dir)
            }
            throw error
        }
    }

    private static func unlinkMissingPatients(_ batch: inout Batch, knownPatients: Set<UUID>) {
        for i in batch.notes.indices {
            let missing = batch.notes[i].mentionedPatients.filter { !knownPatients.contains($0) }
            if !missing.isEmpty {
                batch.notes[i].mentionedPatients.removeAll { !knownPatients.contains($0) }
                for pid in missing {
                    batch.report.warnings.append(
                        String(localized: "note \(batch.notes[i].id.uuidString.prefix(8)) references missing patient \(pid.uuidString.prefix(8)), unlinked"))
                }
            }
        }
        for i in batch.todos.indices {
            if let pid = batch.todos[i].patientId, !knownPatients.contains(pid) {
                batch.todos[i].patientId = nil
                batch.todos[i].patientName = nil
                batch.report.warnings.append(
                    String(localized: "todo \(batch.todos[i].id.uuidString.prefix(8)) references missing patient \(pid.uuidString.prefix(8)), unlinked"))
            }
        }
        for i in batch.events.indices {
            if let pid = batch.events[i].patientId, !knownPatients.contains(pid) {
                batch.events[i].patientId = nil
                batch.report.warnings.append(
                    String(localized: "event \(batch.events[i].id.uuidString.prefix(8)) references missing patient \(pid.uuidString.prefix(8)), unlinked"))
            }
        }
    }

    private func jsonFiles(in subfolder: Subfolder) throws -> [URL] {
        let dir = directoryURL.appendingPathComponent(subfolder.rawValue, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { url in
                url.pathExtension.lowercased() == "json"
                    && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        do {
            return try decodeJSONData(type, from: data)
        } catch {
            throw ImportError.decoding(url.lastPathComponent, error)
        }
    }
}

enum ImportError: Error, CustomStringConvertible, LocalizedError {
    case decoding(String, Error)
    case attachmentVerification(String)

    var description: String {
        switch self {
        case let .decoding(file, err):
            return "failed to decode \(file): \(err)"
        case let .attachmentVerification(name):
            return "attachment \(name) did not read back after it was stored"
        }
    }

    /// What the import report shows. The catch sites already put the file
    /// name in front, and Foundation words the decoding failure in the
    /// user's language; `description` keeps the full dump for the CLI.
    var errorDescription: String? {
        switch self {
        case let .decoding(_, err):
            return err.localizedDescription
        case let .attachmentVerification(name):
            return String(localized: "The attachment “\(name)” could not be stored safely, so nothing was imported.")
        }
    }
}
