import XCTest
@testable import MedNotes

/// Backup and restore over the v2 archive, plus the encrypted restore points.
///
/// The old v1 tests exercised a plaintext directory backup tree; v2 is a
/// bounded record stream and the store never writes a plaintext copy, so these
/// assert the encrypted path end to end.
final class BackupRestoreTests: XCTestCase {
    private var tempDir: URL!
    private var root: DataRoot!
    private var store: AppStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-backup-\(UUID().uuidString)", isDirectory: true)
        root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        store = try AppStore.testStore(dataRoot: root)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func samplePatient(name: String = "Test", amka: String = "12345678901") -> Patient {
        var profile = PatientProfile(
            firstName: name,
            lastName: "Patient",
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -40, to: Date())!,
            gender: .male,
            amka: amka,
            phone: "6900000000",
            email: "\(name.lowercased())@example.com")
        profile.address = Address(street: "Main 1", city: "Athens", postalCode: "12345",
                                  region: "Attica", country: "Greece")
        return Patient(profile: profile)
    }

    func testDataRootCreatesLayout() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.backupsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.attachmentsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.restorePointsURL.path))
    }

    func testEncryptedBackupRoundTripsThroughAFreshStore() async throws {
        try await store.patients.save(samplePatient(name: "Before", amka: "11111111111"))
        try await store.notes.save(Note(title: "note", content: "content"))
        // A confirmed destination in the source, so that the suspension below
        // has something to suspend.
        _ = try await store.destinations.confirm(bridge: .calendar, candidate: SyncDestinationCandidate(
            calendarIdentifier: "cal-restore", calendarTitle: "MedNotes", sourceIdentifier: "src",
            sourceTitle: "iCloud", sourceType: "calDAV", isAppCreated: true, recordCount: 1,
            transmittedFields: ["title"], requiresCloudAcknowledgment: true))
        let confirmed = try await store.destinations.destination(for: .calendar)
        XCTAssertTrue(confirmed?.mayReceiveWrites ?? false, "precondition: the source may sync")
        let file = tempDir.appendingPathComponent("roundtrip.mednotesbackup")
        let manifest = try await store.backups.createEncryptedBackup(
            name: "test", to: file, passphrase: "a long enough passphrase")
        XCTAssertEqual(manifest.counts["patients"], 1)
        XCTAssertEqual(manifest.counts["notes"], 1)

        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(bytes.contains(Data("Patient".utf8)),
                       "no patient text may be readable in the archive")
        XCTAssertFalse(bytes.contains(Data("SQLite format".utf8)),
                       "the database header must not be readable")

        // Restore into a second, independent store.
        let second = try DataRoot(rootURL: tempDir.appendingPathComponent("second", isDirectory: true))
        let target = try AppStore.testStore(dataRoot: second)
        let restored = try await target.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: second),
            attachmentKey: TestKeys.attachment(for: second),
            createRestorePoint: false)
        XCTAssertEqual(restored.counts["patients"], 1)
        let loaded = try await target.patients.loadAll()
        XCTAssertEqual(loaded.first?.profile.firstName, "Before")

        // The restored store's destinations are suspended: sync must not run
        // until the user reconfirms.
        let restoredDestination = try await target.destinations.destination(for: .calendar)
        XCTAssertNotNil(restoredDestination, "the destination came across with the backup")
        XCTAssertFalse(restoredDestination?.mayReceiveWrites ?? true)
    }

    func testWrongPassphraseIsRejectedBeforeTheStoreChanges() async throws {
        try await store.patients.save(samplePatient(name: "Keep", amka: "33333333333"))
        let file = tempDir.appendingPathComponent("locked.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "x", to: file, passphrase: "correct passphrase here")
        do {
            _ = try await store.backups.restore(
                fromEncryptedBackupAt: file, passphrase: "wrong passphrase here",
                databaseKey: TestKeys.database(for: root),
                attachmentKey: TestKeys.attachment(for: root),
                createRestorePoint: false)
            XCTFail("restore must fail on the wrong passphrase")
        } catch {
            XCTAssertEqual(error as? BackupArchiveV2.ArchiveError, .wrongPassphraseOrCorrupt)
        }
        let patients = try await store.patients.loadAll()
        XCTAssertEqual(patients.first?.profile.firstName, "Keep")
    }

    func testTamperedArchiveIsRejected() async throws {
        try await store.patients.save(samplePatient())
        let file = tempDir.appendingPathComponent("tampered.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "x", to: file, passphrase: "correct passphrase here")
        var bytes = try Data(contentsOf: file)
        // Flip a byte inside the database snapshot's chunk data, past the
        // manifest record, so the full read must fail on the HMAC.
        let target = BackupArchiveV2.headerLength + 200
        bytes[target] ^= 0x01
        try bytes.write(to: file)
        await assertReadFails(at: file, passphrase: "correct passphrase here")
    }

    func testTruncatedArchiveLosesItsFinalTag() async throws {
        try await store.patients.save(samplePatient())
        let file = tempDir.appendingPathComponent("truncated.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "x", to: file, passphrase: "correct passphrase here")
        var bytes = try Data(contentsOf: file)
        bytes.removeLast(40)
        try bytes.write(to: file)
        // `inspect` stops at the manifest and still succeeds; a full read must
        // reach the end marker and fail on the missing final tag.
        await assertReadFails(at: file, passphrase: "correct passphrase here")
    }

    func testUnknownKDFProfileIsRejectedBeforeTheKDF() async throws {
        try await store.patients.save(samplePatient())
        let file = tempDir.appendingPathComponent("profile.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "x", to: file, passphrase: "correct passphrase here")
        var bytes = try Data(contentsOf: file)
        // Byte 4 is the version; byte 5 is the KDF profile.
        bytes[5] = 99
        try bytes.write(to: file)
        do {
            _ = try BackupArchiveV2.inspect(at: file, passphrase: "anything at all here")
            XCTFail("unknown profile must be rejected")
        } catch {
            XCTAssertEqual(error as? BackupArchiveV2.ArchiveError, .unknownKDFProfile(99))
        }
    }

    func testEncryptedRestorePointsAreListedSizedAndPruned() async throws {
        try await store.patients.save(samplePatient())
        for index in 0..<7 {
            _ = try await store.backups.createEncryptedRestorePoint(
                name: "point \(index)")
            // Distinct creation timestamps so ordering is deterministic.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let points = try await store.backups.listRestorePoints()
        XCTAssertEqual(points.count, 7)
        XCTAssertGreaterThan(BackupService.sizeOnDisk(at: points[0].url), 0)

        let pruned = try await store.backups.pruneRestorePoints()
        XCTAssertEqual(pruned.count, 2)
        let remaining = try await store.backups.listRestorePoints()
        XCTAssertEqual(remaining.count, 5)
    }

    func testMissingManifestInLegacyDirectoryIsIgnored() async throws {
        let backupsDir = root.restorePointsURL
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let orphan = backupsDir.appendingPathComponent("backup_orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphan.appendingPathComponent("mednotes.db"))
        // The v2 listing only sees `.mnrp` points in the restore-points folder,
        // so a stray folder never appears.
        let points = try await store.backups.listRestorePoints()
        XCTAssertTrue(points.isEmpty)
    }

    func testBackupRefusesShortPassphrase() async throws {
        try await store.patients.save(samplePatient())
        let file = tempDir.appendingPathComponent("short.mednotesbackup")
        do {
            _ = try await store.backups.createEncryptedBackup(name: "x", to: file, passphrase: "short")
            XCTFail("a short passphrase must be refused below the UI")
        } catch {
            guard case BackupArchiveV2.ArchiveError.passphrasePolicy = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// Async throwing assertions cannot use `XCTAssertThrowsError`, whose
    /// autoclosure is synchronous.
    private func assertReadFails(at url: URL, passphrase: String,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await BackupArchiveV2.read(at: url, passphrase: passphrase, sink: { _ in })
            XCTFail("expected a read failure", file: file, line: line)
        } catch {
            // expected
        }
    }

    func testGeneratedPassphraseIsCrockfordAndAccepted() {
        let generated = BackupPassphrasePolicy.generate()
        let stripped = generated.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(stripped.count, 24)
        XCTAssertEqual(generated.split(separator: "-").map(\.count), [5, 5, 5, 5, 4],
                       "the groups are five characters except the last")
        XCTAssertTrue(stripped.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertTrue(BackupPassphrasePolicy.isAcceptable(stripped))
        XCTAssertFalse(BackupPassphrasePolicy.isAcceptable("too short"))
        // NFC normalization: a decomposed é must be accepted and normalized.
        let decomposed = "e\u{301}" + String(repeating: "x", count: 15)
        XCTAssertTrue(BackupPassphrasePolicy.isAcceptable(decomposed))
        XCTAssertEqual(BackupPassphrasePolicy.normalized(decomposed).unicodeScalars.count, 16)
    }
}
