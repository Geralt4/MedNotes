import XCTest
@testable import MedNotes

/// The safety copy a restore keeps first, and reading version-1 backups.
final class RestoreFixTests: XCTestCase {
    private var roots: [DataRoot] = []
    private var scratch: URL!
    private let passphrase = "a long enough passphrase"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-restorefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    // MARK: - The safety copy

    /// One attachment the store can no longer read used to make every restore
    /// fail at the safety copy, so a damaged store could not be replaced from
    /// a good backup. The failure is now its own error, nothing is changed,
    /// and going on without the copy is a choice.
    func testARestoreWhoseSafetyCopyFailsChangesNothingUntilTheUserChoosesToGoOn() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        try await source.notes.save(Note(title: "From the backup", content: "FROM-BACKUP"))
        let archive = scratch.appendingPathComponent("good.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(name: "Good", to: archive, passphrase: passphrase)
        await source.close()

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Damaged"
        patient.profile.lastName = "Store"
        patient.files = [PatientFile(name: "a.txt", type: .other, data: Data("ATTACHMENT".utf8))]
        try await target.patients.save(patient)
        // The stored object disappears from disk.
        let enumerator = FileManager.default.enumerator(
            at: targetRoot.attachmentsURL, includingPropertiesForKeys: [.isRegularFileKey])
        var removed = 0
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        XCTAssertGreaterThan(removed, 0, "precondition: the attachment was on disk")

        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: archive, passphrase: passphrase,
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot))
            XCTFail("the safety copy cannot be made, so the restore must stop")
        } catch let error as BackupError {
            guard case .safetyCopyIncomplete = error else {
                return XCTFail("expected safetyCopyIncomplete, got \(error)")
            }
        }
        let untouched = try await target.db.loadAllNotes()
        XCTAssertTrue(untouched.isEmpty, "nothing was replaced")

        // By choice, without the copy, the good backup goes in.
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
        let restored = try await target.db.loadAllNotes()
        XCTAssertEqual(restored.map(\.content), ["FROM-BACKUP"])
        await target.close()
    }

    // MARK: - Version-1 backups

    private func v1Archive(sealing payload: Data, passphrase: String, name: String) throws -> URL {
        let sealed = try EncryptedBackupFormat.seal(payload, passphrase: passphrase, iterations: 100_000)
        let url = scratch.appendingPathComponent(name)
        try sealed.write(to: url)
        return url
    }

    /// A payload the way the old build wrote it: a real, serialized
    /// `FileWrapper` directory.
    private func wrapperPayload(extra: [String: FileWrapper] = [:]) throws -> Data {
        var children: [String: FileWrapper] = [
            "mednotes.db": FileWrapper(regularFileWithContents: Data("DATABASE-BYTES".utf8)),
            "manifest.json": FileWrapper(regularFileWithContents: Data("{\"name\":\"old\"}".utf8)),
            "Files": FileWrapper(directoryWithFileWrappers: [
                "patient": FileWrapper(directoryWithFileWrappers: [
                    "file": FileWrapper(regularFileWithContents: Data("FILE-BYTES".utf8))
                ])
            ])
        ]
        for (name, wrapper) in extra { children[name] = wrapper }
        for (name, wrapper) in children { wrapper.preferredFilename = name }
        let root = FileWrapper(directoryWithFileWrappers: children)
        return try XCTUnwrap(root.serializedRepresentation)
    }

    func testARealSerializedFileWrapperIsReadWithoutWritingAnythingToDisk() throws {
        let payload = try wrapperPayload()
        let asPlist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
        XCTAssertNil(asPlist, "premise: the real serialization is the flat RTFD form, not a property list")

        let url = try v1Archive(sealing: payload, passphrase: passphrase, name: "wrapper.mnbk")
        let contents = try LegacyBackupReader.open(at: url, passphrase: passphrase)
        XCTAssertEqual(Set(contents.entries.map(\.relativePath)),
                       ["mednotes.db", "manifest.json", "Files/patient/file"])
        XCTAssertEqual(contents.entries.first { $0.relativePath == "Files/patient/file" }?.data,
                       Data("FILE-BYTES".utf8))
        XCTAssertEqual(contents.manifestData, Data("{\"name\":\"old\"}".utf8))
    }

    func testARealSerializedFileWrapperWithALinkIsRefused() throws {
        let link = FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let url = try v1Archive(
            sealing: try wrapperPayload(extra: ["evil": link]), passphrase: passphrase, name: "link.mnbk")
        XCTAssertThrowsError(try LegacyBackupReader.open(at: url, passphrase: passphrase)) { error in
            guard case LegacyBackupReader.LegacyError.nonRegularEntry = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAPassphraseOpensTheArchiveInEitherUnicodeForm() throws {
        let precomposed = "caf\u{e9} passphrase long enough"
        let decomposed = "cafe\u{301} passphrase long enough"
        XCTAssertNotEqual(Array(precomposed.utf8), Array(decomposed.utf8), "premise: different bytes")
        let payload = try wrapperPayload()

        for sealedWith in [precomposed, decomposed] {
            let url = try v1Archive(sealing: payload, passphrase: sealedWith, name: "u-\(sealedWith.utf8.count).mnbk")
            for typed in [precomposed, decomposed] {
                let contents = try LegacyBackupReader.open(at: url, passphrase: typed)
                XCTAssertEqual(contents.entries.count, 3,
                               "sealed with \(sealedWith.utf8.count) bytes, typed as \(typed.utf8.count) bytes")
            }
        }
    }

    func testAWrongPassphraseIsStillRefused() throws {
        let url = try v1Archive(sealing: try wrapperPayload(), passphrase: passphrase, name: "wrong.mnbk")
        XCTAssertThrowsError(try LegacyBackupReader.open(at: url, passphrase: "another long enough passphrase")) { error in
            XCTAssertEqual(error as? LegacyBackupReader.LegacyError, .wrongPassphraseOrCorrupt)
        }
    }

    func testPassphraseFormsAreDistinctByBytes() {
        XCTAssertEqual(LegacyBackupReader.passphraseForms("plain ascii passphrase").count, 1)
        XCTAssertEqual(LegacyBackupReader.passphraseForms("caf\u{e9} passphrase").count, 2,
                       "as given plus the decomposed form")
        XCTAssertEqual(LegacyBackupReader.passphraseForms("cafe\u{301} passphrase").count, 2,
                       "as given plus the precomposed form")
    }

    // MARK: - A version 1 restore and a file the backup lost

    /// A v1 backup holding a patient with two files, of which `Files/` has one.
    private func legacyBackup(missingFile: Bool) async throws -> (archive: URL, patient: Patient, present: PatientFile, missing: PatientFile) {
        let legacyRoot = try makeRoot()
        let plain = try Database(path: legacyRoot.databaseURL.path)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Has"
        patient.profile.lastName = "Files"
        let present = PatientFile(name: "present.txt", type: .other, data: nil)
        let missing = PatientFile(name: "missing.txt", type: .other, data: nil)
        patient.files = [present, missing]
        try await plain.savePatient(patient)
        await plain.close()
        for suffix in ["-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.databaseURL.path + suffix),
                           "premise: the snapshot is one file")
        }
        var files: [String: FileWrapper] = [
            patient.id.uuidString: FileWrapper(directoryWithFileWrappers: [
                present.id.uuidString: FileWrapper(regularFileWithContents: Data("PRESENT-BYTES".utf8))
            ])
        ]
        if !missingFile {
            files[patient.id.uuidString]?.addRegularFile(
                withContents: Data("MISSING-BYTES".utf8), preferredFilename: missing.id.uuidString)
        }
        for (name, wrapper) in files { wrapper.preferredFilename = name }
        let manifest = #"{"name":"old","createdAt":0,"schemaVersion":1,"counts":{}}"#
        var children: [String: FileWrapper] = [
            "mednotes.db": FileWrapper(regularFileWithContents: try Data(contentsOf: legacyRoot.databaseURL)),
            "manifest.json": FileWrapper(regularFileWithContents: Data(manifest.utf8)),
            "Files": FileWrapper(directoryWithFileWrappers: files)
        ]
        for (name, wrapper) in children { wrapper.preferredFilename = name }
        let payload = try XCTUnwrap(FileWrapper(directoryWithFileWrappers: children).serializedRepresentation)
        children.removeAll()
        return (try v1Archive(sealing: payload, passphrase: passphrase, name: "lost-file.mnbk"), patient, present, missing)
    }

    /// The migration drops a patient-file record whose file is gone; a version 1
    /// restore used to keep it, listing a file that opens to nothing. It now
    /// drops it too, and logs how many, not which.
    func testAV1RestoreDropsAPatientFileRowWhoseFileIsMissingFromTheBackup() async throws {
        let backup = try await legacyBackup(missingFile: true)
        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        var logged: [(SecurityLog.Event, Int?)] = []
        SecurityLog.observer = { event, count, _ in logged.append((event, count)) }
        defer { SecurityLog.observer = nil }

        _ = try await target.backups.restore(
            fromLegacyBackupAt: backup.archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)

        let loaded = try await target.patients.load(id: backup.patient.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.files.map(\.id), [backup.present.id], "the record without a file is gone")
        let rows = try await target.db.loadPatientFiles(patientId: backup.patient.id)
        XCTAssertEqual(rows.map(\.id), [backup.present.id])
        XCTAssertEqual(logged.filter { $0.0 == .restoreDroppedAttachments }.map(\.1), [1],
                       "the count is logged: \(logged)")
        await target.close()
    }

    /// Nothing is dropped, and nothing logged, when the backup holds every file.
    func testAV1RestoreKeepsEveryRowWhoseFileIsInTheBackup() async throws {
        let backup = try await legacyBackup(missingFile: false)
        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        var dropped = 0
        SecurityLog.observer = { event, _, _ in if event == .restoreDroppedAttachments { dropped += 1 } }
        defer { SecurityLog.observer = nil }

        _ = try await target.backups.restore(
            fromLegacyBackupAt: backup.archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)

        let rows = try await target.db.loadPatientFiles(patientId: backup.patient.id)
        XCTAssertEqual(Set(rows.map(\.id)), [backup.present.id, backup.missing.id])
        XCTAssertEqual(dropped, 0)
        await target.close()
    }

    /// A patient whose only file is gone: the record also leaves the patient's
    /// own file list (`files_json`), which is where a patient with no file rows
    /// is read from.
    func testAV1RestoreRemovesTheOnlyFileOfAPatientWhoseFileIsMissingFromThePatientToo() async throws {
        let legacyRoot = try makeRoot()
        let plain = try Database(path: legacyRoot.databaseURL.path)
        var patient = Patient.newRecord()
        patient.profile.firstName = "Only"
        patient.profile.lastName = "File"
        patient.files = [PatientFile(name: "gone.txt", type: .other, data: nil)]
        try await plain.savePatient(patient)
        await plain.close()
        let children: [String: FileWrapper] = [
            "mednotes.db": FileWrapper(regularFileWithContents: try Data(contentsOf: legacyRoot.databaseURL)),
            "manifest.json": FileWrapper(regularFileWithContents:
                Data(#"{"name":"old","createdAt":0,"schemaVersion":1,"counts":{}}"#.utf8)),
            "Files": FileWrapper(directoryWithFileWrappers: [:])
        ]
        for (name, wrapper) in children { wrapper.preferredFilename = name }
        let payload = try XCTUnwrap(FileWrapper(directoryWithFileWrappers: children).serializedRepresentation)
        let archive = try v1Archive(sealing: payload, passphrase: passphrase, name: "only-file.mnbk")
        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)

        _ = try await target.backups.restore(
            fromLegacyBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)

        let loaded = try await target.patients.load(id: patient.id)
        XCTAssertEqual(try XCTUnwrap(loaded).files, [], "the dropped file must not come back from the patient's own list")
        await target.close()
    }
}
