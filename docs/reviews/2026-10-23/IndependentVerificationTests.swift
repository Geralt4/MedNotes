import XCTest
@testable import MedNotes

final class IndependentVerificationTests: XCTestCase {
    private var roots: [DataRoot] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeRoot() throws -> DataRoot {
        let root = try DataRoot.temporary()
        roots.append(root)
        return root
    }

    func testSavingOlderMetadataDraftDoesNotLoseReplacedAttachment() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "scan.txt", type: .other, data: Data("ORIGINAL".utf8))]
        try await store.patients.save(patient)

        let firstLoad = try await store.patients.load(id: patient.id)
        let snapshot = try XCTUnwrap(firstLoad)
        var olderDraft = snapshot
        var replacement = snapshot
        replacement.files[0].data = Data("REPLACED".utf8)
        try await store.patients.save(replacement)
        let committedBytes = try await store.patients.loadFileData(
            patientId: patient.id, fileId: patient.files[0].id)
        XCTAssertEqual(committedBytes, Data("REPLACED".utf8))

        // A second editor/save still has the old file metadata, but edits
        // only a demographic field. A rejected stale save is acceptable;
        // a successful save must never commit a reference to a deleted file.
        olderDraft.profile.firstName = "Updated demographic field"
        do {
            try await store.patients.save(olderDraft)
        } catch {
            let unchangedBytes = try await store.patients.loadFileData(
                patientId: patient.id, fileId: patient.files[0].id)
            XCTAssertEqual(unchangedBytes, Data("REPLACED".utf8))
            await store.close()
            return
        }

        let liveMetadata = try await store.patients.load(id: patient.id)
        let storageID = try XCTUnwrap(liveMetadata?.files.first?.storageID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.attachmentsURL.appendingPathComponent(storageID).path),
            "Successful demographic save committed a reference to deleted ciphertext")
        let remainingObjects = try FileManager.default.contentsOfDirectory(atPath: root.attachmentsURL.path)
        XCTAssertFalse(remainingObjects.isEmpty,
                       "Saving the older draft deleted both the original and replacement attachment objects")
        do {
            let bytes = try await store.patients.loadFileData(
                patientId: patient.id, fileId: patient.files[0].id)
            XCTAssertEqual(bytes, Data("REPLACED".utf8))
        } catch {
            XCTFail("Successful stale-draft save lost the committed attachment: \(error.localizedDescription)")
        }
        await store.close()
    }

    func testMixedEmptyAndMultiChunkAttachmentsRestoreAndRecover() async throws {
        let sourceRoot = try makeRoot()
        let source = try AppStore.testStore(dataRoot: sourceRoot)
        var patient = Patient.newRecord()
        let payloads = [Data(), Data(repeating: 0x41, count: (1 << 20) + 123),
                        Data(), Data("tail".utf8), Data()]
        patient.files = payloads.enumerated().map { index, bytes in
            PatientFile(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                        name: "file-\(index)", type: .other, data: bytes)
        }
        try await source.patients.save(patient)
        let archive = sourceRoot.rootURL.appendingPathComponent("mixed.mednotesbackup")
        let passphrase = "independent verification passphrase"
        _ = try await source.backups.createEncryptedBackup(to: archive, passphrase: passphrase)

        let targetRoot = try makeRoot()
        let target = try AppStore.testStore(dataRoot: targetRoot)
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: archive, passphrase: passphrase,
            databaseKey: TestKeys.database(for: targetRoot),
            attachmentKey: TestKeys.attachment(for: targetRoot), createRestorePoint: false)
        for file in patient.files {
            let bytes = try await target.patients.loadFileData(patientId: patient.id, fileId: file.id)
            XCTAssertEqual(bytes, file.data)
        }

        let recoveryRoot = try makeRoot()
        let report = try await StoreRecovery(dataRoot: recoveryRoot, keyManager: InMemoryKeyManager())
            .recover(from: archive, passphrase: passphrase)
        let recovered = try AppStore(
            dataRoot: recoveryRoot,
            databaseKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.database),
            attachmentKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.attachments),
            restorePointKey: StoreKeyContext.subkey(rootKey: report.rootKey, context: StoreKeyContext.restorePoints))
        for file in patient.files {
            let bytes = try await recovered.patients.loadFileData(patientId: patient.id, fileId: file.id)
            XCTAssertEqual(bytes, file.data)
        }
        await source.close()
        await target.close()
        await recovered.close()
    }
}
