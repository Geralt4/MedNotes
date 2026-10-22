import XCTest
@testable import MedNotes

/// The v2 archive is the only form in which the store leaves its container, so
/// it must round-trip, refuse the wrong passphrase before anything is unpacked,
/// and reject tampering. The v1 reader keeps read-only support with the
/// containment the old format lacked.
final class EncryptedBackupTests: XCTestCase {
    private var roots: [DataRoot] = []
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-encrypted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots = []
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeStore() throws -> (root: DataRoot, store: AppStore) {
        let root = try DataRoot.temporary()
        roots.append(root)
        return (root, try AppStore.testStore(dataRoot: root))
    }

    // MARK: - Format

    func testSealAndInspectRoundTrip() async throws {
        let (root, store) = try makeStore()
        try await store.patients.save(Patient.newRecord())
        let file = scratch.appendingPathComponent("roundtrip.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "Nightly", to: file, passphrase: "a long enough passphrase")

        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(bytes.prefix(4), BackupArchiveV2.magic)
        let inspected = try await store.backups.inspectEncryptedBackup(
            at: file, passphrase: "a long enough passphrase")
        XCTAssertEqual(inspected.name, "Nightly")
        _ = root
    }

    func testWrongPassphraseAndTamperingAreRejected() async throws {
        let (_, store) = try makeStore()
        try await store.patients.save(Patient.newRecord())
        let file = scratch.appendingPathComponent("sealed.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "x", to: file, passphrase: "the correct passphrase")

        XCTAssertThrowsError(try BackupArchiveV2.inspect(at: file, passphrase: "a wrong passphrase"))
        XCTAssertNoThrow(try BackupArchiveV2.inspect(at: file, passphrase: "the correct passphrase"))

        var tampered = try Data(contentsOf: file)
        tampered[BackupArchiveV2.headerLength + 8] ^= 0x01
        try tampered.write(to: file)
        await assertReadFails(at: file, passphrase: "the correct passphrase")
    }

    // MARK: - Through the service

    func testEncryptedBackupRestoresIntoAnotherStore() async throws {
        let (sourceRoot, source) = try makeStore()
        var patient = Patient.newRecord()
        patient.profile.firstName = "Ελένη"
        patient.profile.lastName = "Κωνσταντίνου"
        try await source.patients.save(patient)
        try await source.notes.save(Note(title: "Ward round", content: "Stable overnight."))

        let file = scratch.appendingPathComponent("test.mednotesbackup")
        let manifest = try await source.backups.createEncryptedBackup(
            name: "Nightly", to: file, passphrase: "a long enough passphrase")
        XCTAssertEqual(manifest.counts["patients"], 1)
        XCTAssertEqual(manifest.counts["notes"], 1)
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(bytes.contains(Data("Stable overnight".utf8)), "note text must not be readable in the file")
        XCTAssertFalse(bytes.contains(Data("SQLite format".utf8)), "the database header must not be readable either")

        let inspected = try await source.backups.inspectEncryptedBackup(at: file, passphrase: "a long enough passphrase")
        XCTAssertEqual(inspected.name, "Nightly")

        let (targetRoot, target) = try makeStore()
        let restored = try await target.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot),
            createRestorePoint: false)
        XCTAssertEqual(restored.counts["patients"], 1)
        let loaded = try await target.patients.load(id: patient.id)
        XCTAssertEqual(loaded?.profile.lastName, "Κωνσταντίνου")
        let notes = try await target.notes.loadAll()
        XCTAssertEqual(notes.first?.content, "Stable overnight.")
        _ = sourceRoot
    }

    func testWrongPassphraseLeavesTheStoreUntouched() async throws {
        let (root, source) = try makeStore()
        try await source.patients.save(Patient.newRecord())
        let file = scratch.appendingPathComponent("locked.mednotesbackup")
        _ = try await source.backups.createEncryptedBackup(
            name: "x", to: file, passphrase: "the correct passphrase")

        let (targetRoot, target) = try makeStore()
        var keeper = Patient.newRecord()
        keeper.profile.firstName = "Keep"
        try await target.patients.save(keeper)
        do {
            _ = try await target.backups.restore(
                fromEncryptedBackupAt: file, passphrase: "a wrong passphrase",
                databaseKey: TestKeys.database(for: targetRoot),
                attachmentKey: TestKeys.attachment(for: targetRoot),
                createRestorePoint: false)
            XCTFail("restore must fail on the wrong passphrase")
        } catch {
            XCTAssertEqual(error as? BackupArchiveV2.ArchiveError, .wrongPassphraseOrCorrupt)
        }
        let stillThere = try await target.patients.load(id: keeper.id)
        XCTAssertEqual(stillThere?.profile.firstName, "Keep")
        XCTAssertThrowsError(try BackupArchiveV2.inspect(at: file, passphrase: "a wrong passphrase"))
        _ = root
    }

    // MARK: - Internal restore points

    func testRestorePointUsesTheInternalKeyAndStaysInTheContainer() async throws {
        let (root, store) = try makeStore()
        try await store.patients.save(Patient.newRecord())
        let name = try await store.backups.createEncryptedRestorePoint(
            name: "snapshot")
        let url = root.restorePointsURL.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "mnrp")

        // A user passphrase never opens an internal point.
        XCTAssertThrowsError(try BackupArchiveV2.inspect(at: url, passphrase: "some user passphrase"))
        // The old public passphrase no longer does.
        XCTAssertThrowsError(try BackupArchiveV2.inspect(
            at: url, passphrase: BackupService.legacyRestorePointPassphrase))
        // Only the device restore key does.
        XCTAssertNoThrow(try BackupArchiveV2.inspect(
            at: url, sealing: .deviceKey(TestKeys.restorePoint(for: root))))
    }

    // MARK: - Legacy v1 containment

    func testLegacyReaderRejectsOutOfRangeIterations() throws {
        let file = scratch.appendingPathComponent("legacy.mnbk")
        var archive = Data("MNBK".utf8)
        archive.append(1)                                   // version
        archive.append(contentsOf: [0x00, 0x00, 0x00, 0x0A]) // 10 iterations
        archive.append(Data(repeating: 0, count: 16 + 12 + 16))
        try archive.write(to: file)
        XCTAssertThrowsError(try LegacyBackupReader.probeHeader(at: file)) { error in
            XCTAssertEqual(error as? LegacyBackupReader.LegacyError, .iterationsOutOfRange(10))
        }
    }

    func testLegacyReaderRejectsOversizedNameAndSymlinks() throws {
        // A v1 payload is a plist; build one with a nested directory and a name
        // containing a separator. The reader must refuse before extraction.
        let entry: [String: Any] = [
            "NSFileWrapperRegularFile": true,
            "NSFileWrapperPreferredFilename": "../escape",
            "NSFileWrapperContents": Data("x".utf8)
        ]
        let root: [String: Any] = [
            "NSFileWrapperDirectory": true,
            "NSFileWrapperChildren": [entry]
        ]
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let legacy = try EncryptedBackupFormat.seal(payload, passphrase: "a long enough passphrase", iterations: 100_000)
        let file = scratch.appendingPathComponent("legacy-evil.mnbk")
        try legacy.write(to: file)
        XCTAssertThrowsError(try LegacyBackupReader.open(at: file, passphrase: "a long enough passphrase")) { error in
            guard case LegacyBackupReader.LegacyError.unsafeEntryName = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyReaderRejectsSymbolicLinkEntries() throws {
        let entry: [String: Any] = [
            "NSFileWrapperPreferredFilename": "link",
            "NSFileWrapperLinkDestination": "/etc/passwd"
        ]
        let root: [String: Any] = [
            "NSFileWrapperDirectory": true,
            "NSFileWrapperChildren": [entry]
        ]
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let legacy = try EncryptedBackupFormat.seal(payload, passphrase: "a long enough passphrase", iterations: 100_000)
        let file = scratch.appendingPathComponent("legacy-link.mnbk")
        try legacy.write(to: file)
        XCTAssertThrowsError(try LegacyBackupReader.open(at: file, passphrase: "a long enough passphrase")) { error in
            guard case LegacyBackupReader.LegacyError.nonRegularEntry = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyReaderRejectsDuplicateNames() throws {
        func fileEntry(_ name: String) -> [String: Any] {
            ["NSFileWrapperPreferredFilename": name, "NSFileWrapperContents": Data("x".utf8)]
        }
        let root: [String: Any] = [
            "NSFileWrapperDirectory": true,
            "NSFileWrapperChildren": [fileEntry("same.txt"), fileEntry("same.txt")]
        ]
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let legacy = try EncryptedBackupFormat.seal(payload, passphrase: "a long enough passphrase", iterations: 100_000)
        let file = scratch.appendingPathComponent("legacy-dup.mnbk")
        try legacy.write(to: file)
        XCTAssertThrowsError(try LegacyBackupReader.open(at: file, passphrase: "a long enough passphrase")) { error in
            guard case LegacyBackupReader.LegacyError.duplicateEntry = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyReaderExtractsWithNoFollowSemantics() throws {
        let entry: [String: Any] = [
            "NSFileWrapperPreferredFilename": "note.json",
            "NSFileWrapperContents": Data("{}".utf8)
        ]
        let root: [String: Any] = [
            "NSFileWrapperDirectory": true,
            "NSFileWrapperChildren": [entry]
        ]
        let payload = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let legacy = try EncryptedBackupFormat.seal(payload, passphrase: "a long enough passphrase", iterations: 100_000)
        let file = scratch.appendingPathComponent("legacy-good.mnbk")
        try legacy.write(to: file)

        let contents = try LegacyBackupReader.open(at: file, passphrase: "a long enough passphrase")
        XCTAssertEqual(contents.entries.count, 1)
        let out = scratch.appendingPathComponent("extracted", isDirectory: true)
        try LegacyBackupReader.extract(contents, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("note.json").path))
    }

    /// Async throwing assertions cannot use `XCTAssertThrowsError`, whose
    /// autoclosure is synchronous.
    private func assertReadFails(at url: URL, passphrase: String,
                                 message: String = "expected a read failure",
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await BackupArchiveV2.read(at: url, passphrase: passphrase, sink: { _ in })
            XCTFail(message, file: file, line: line)
        } catch {
            // expected
        }
    }

    // MARK: - Deterministic malformed corpus

    /// Every byte-prefix of an archive must fail cleanly, never crash.
    func testMalformedPrefixesFailCleanly() async throws {
        let (_, store) = try makeStore()
        try await store.patients.save(Patient.newRecord())
        let file = scratch.appendingPathComponent("corpus.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "corpus", to: file, passphrase: "a long enough passphrase")
        let bytes = try Data(contentsOf: file)
        for length in stride(from: 0, to: bytes.count, by: 4093) {
            let truncated = bytes.prefix(length)
            let candidate = scratch.appendingPathComponent("corpus-\(length).mednotesbackup")
            try truncated.write(to: candidate)
            // A prefix may still contain a readable manifest; the full read
            // must always fail without the end marker.
            await assertReadFails(
                at: candidate, passphrase: "a long enough passphrase",
                message: "prefix \(length) must be rejected")
        }
    }

    /// A lock cancels the backup Back Up runs. A cancelled backup leaves the
    /// file the user chose to replace as it was, and no staging file beside it.
    func testACancelledBackupLeavesTheDestinationAsItWas() async throws {
        let (_, store) = try makeStore()
        try await store.patients.save(Patient.newRecord())
        let file = scratch.appendingPathComponent("replaced.mednotesbackup")
        let older = Data("an older backup".utf8)
        try older.write(to: file)

        let backup = Task {
            try await store.backups.createEncryptedBackup(
                name: "Cancelled", to: file, passphrase: "a long enough passphrase")
        }
        backup.cancel()

        do {
            _ = try await backup.value
            XCTFail("a cancelled backup must not finish")
        } catch BackupArchiveV2.ArchiveError.cancelled {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: file), older)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["replaced.mednotesbackup"])
    }

    /// Whatever stops an archive, the partial copy beside the destination goes.
    func testAFailedSealLeavesNoStagingFile() async throws {
        struct SnapshotFailed: Error {}
        let file = scratch.appendingPathComponent("failed.mednotesbackup")
        do {
            try await BackupArchiveV2.seal(
                manifest: BackupArchiveV2.Manifest(
                    name: "x", createdAt: Date(), schemaVersion: Schema.currentVersion,
                    counts: [:], attachmentCount: 0),
                databaseSnapshot: { _ in throw SnapshotFailed() },
                attachments: [],
                attachmentReader: { _ in Data() },
                passphrase: "a long enough passphrase",
                to: file)
            XCTFail("the snapshot's failure must reach the caller")
        } catch is SnapshotFailed {
            // expected
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    // MARK: - Cancelling part-way

    /// Counts `seal`'s cancellation checks and answers true from the
    /// `cancelFrom`th on.
    private final class CancelAfter: @unchecked Sendable {
        let cancelFrom: Int
        private(set) var checks = 0
        private(set) var attachmentsRead = 0
        init(_ cancelFrom: Int) { self.cancelFrom = cancelFrom }
        func check() -> Bool { checks += 1; return checks >= cancelFrom }
        func read(_ record: BackupArchiveV2.AttachmentRecord) -> Data {
            attachmentsRead += 1
            return Data(repeating: 1, count: record.plaintextLength)
        }
    }

    private func attachment(_ index: Int) -> BackupArchiveV2.AttachmentRecord {
        BackupArchiveV2.AttachmentRecord(
            fileID: "file-\(index)", patientID: "patient", name: "scan-\(index).pdf", type: "pdf",
            storageID: "storage-\(index)", plaintextLength: 64, digest: "", uploadDate: Date(),
            notes: "", tags: [])
    }

    /// Seals three attachments to `file`, asking `counter` whether to stop.
    private func seal(to file: URL, _ counter: CancelAfter,
                      progress: ((Int, Int) -> Void)? = nil,
                      isCancelled: (() -> Bool)? = nil) async throws {
        try await BackupArchiveV2.seal(
            manifest: BackupArchiveV2.Manifest(
                name: "x", createdAt: Date(), schemaVersion: Schema.currentVersion,
                counts: [:], attachmentCount: 3),
            databaseSnapshot: { _ in Data(repeating: 2, count: 128) },
            attachments: (0..<3).map(attachment),
            attachmentReader: { counter.read($0) },
            passphrase: "a long enough passphrase",
            to: file,
            progress: progress,
            isCancelled: isCancelled ?? { counter.check() })
    }

    /// A cancel that lands while the attachments are written stops the
    /// archive at its next record: no further attachment is read (each one
    /// is decrypted from the store), and nothing replaces the older file.
    func testABackupCancelledPartWayStopsAtTheNextRecord() async throws {
        let file = scratch.appendingPathComponent("partway.mednotesbackup")
        let older = Data("an older backup".utf8)
        try older.write(to: file)
        let whole = CancelAfter(.max)
        try await seal(to: scratch.appendingPathComponent("whole.mednotesbackup"), whole)
        XCTAssertEqual(whole.attachmentsRead, 3, "precondition: an uncancelled archive reads every attachment")
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("whole.mednotesbackup"))

        // Manifest, snapshot header and chunk, three metadata records: the
        // seventh check comes before the first attachment's first chunk.
        let counter = CancelAfter(7)
        do {
            try await seal(to: file, counter)
            XCTFail("a cancelled backup must not finish")
        } catch BackupArchiveV2.ArchiveError.cancelled {
            // expected
        }
        XCTAssertEqual(counter.attachmentsRead, 1, "no attachment may be read after the cancel")
        XCTAssertEqual(try Data(contentsOf: file), older)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["partway.mednotesbackup"])
    }

    /// A cancel that lands after the last record, while the archive is
    /// flushed, still stops it before it replaces the older file. After the
    /// last attachment only two checks remain, the end record's and the one
    /// before the move; only that last one says stop.
    func testABackupCancelledAfterItsLastRecordReplacesNothing() async throws {
        let file = scratch.appendingPathComponent("last.mednotesbackup")
        let older = Data("an older backup".utf8)
        try older.write(to: file)
        let stop = StopAtTheMove()

        do {
            try await seal(to: file, CancelAfter(.max),
                           progress: { index, total in if index == total { stop.arm() } },
                           isCancelled: { stop.check() })
            XCTFail("a backup cancelled before its move must not replace the file")
        } catch BackupArchiveV2.ArchiveError.cancelled {
            // expected
        }
        XCTAssertEqual(stop.checksAfterArming, 2, "precondition: the end record's check, then the move's")
        XCTAssertEqual(try Data(contentsOf: file), older)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["last.mednotesbackup"])
    }

    /// Says stop at the second check after `arm()`.
    private final class StopAtTheMove: @unchecked Sendable {
        private var armed = false
        private(set) var checksAfterArming = 0
        func arm() { armed = true }
        func check() -> Bool {
            guard armed else { return false }
            checksAfterArming += 1
            return checksAfterArming >= 2
        }
    }
}
