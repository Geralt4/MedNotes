import XCTest
@testable import MedNotes

/// The working folders of a restore or an upgrade hold a decrypted database and
/// its attachments while they exist. A crash skips the `defer` that removes them,
/// so they are removed when the app launches; nothing else is.
final class StagingLeftoversTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-leftovers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func make(_ name: String, folder: Bool = true) throws {
        let url = directory.appendingPathComponent(name, isDirectory: folder)
        if folder {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
            try Data("decrypted".utf8).write(to: url.appendingPathComponent("snapshot.db"))
        } else {
            try Data("decrypted".utf8).write(to: url)
        }
    }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    func testEveryWorkingFolderAnOperationLeavesIsRemoved() throws {
        for name in ["mednotes-restore-A", "mednotes-legacy-restore-B", "mednotes-recovery-C", "mednotes-upgrade-D"] {
            try make(name)
        }
        try make("mednotes-snapshot-E.db", folder: false)
        try make("mednotes-snapshot-E.db-wal", folder: false)

        XCTAssertEqual(StagingLeftovers.purge(in: directory), 6)
        XCTAssertTrue(try names().isEmpty)
    }

    func testOtherFilesAreLeftAlone() throws {
        try make("mednotes-restore-A")
        try make("mednotes-root-F")           // a test's data root
        try make("MedNotesExternal-abc")      // handled by its own purge
        try make("something-else")
        try make("not-mednotes-restore-G")    // the prefix must start the name

        XCTAssertEqual(StagingLeftovers.purge(in: directory), 1)
        XCTAssertEqual(try names(), ["mednotes-root-F", "MedNotesExternal-abc", "something-else", "not-mednotes-restore-G"])
    }

    func testOnlyTheDirectChildrenOfTheFolderAreConsidered() throws {
        try make("outer")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("outer/mednotes-restore-nested"), withIntermediateDirectories: true)
        XCTAssertEqual(StagingLeftovers.purge(in: directory), 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("outer/mednotes-restore-nested").path))
    }

    func testALinkIsRemovedAsALinkAndItsTargetSurvives() throws {
        try make("target")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("mednotes-restore-link"),
            withDestinationURL: directory.appendingPathComponent("target"))

        XCTAssertEqual(StagingLeftovers.purge(in: directory), 1)
        XCTAssertEqual(try names(), ["target"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("target/snapshot.db").path), "the target must not be followed")
    }

    func testAMissingFolderIsNotAnError() {
        let gone = directory.appendingPathComponent("does-not-exist")
        XCTAssertEqual(StagingLeftovers.purge(in: gone), 0)
    }

    /// The names the code gives its working folders are the ones purged: if an
    /// operation were renamed, this reminds whoever does it to rename the prefix.
    func testThePrefixesAreTheOnesTheOperationsUse() throws {
        let sources = ["Services/BackupService.swift", "Storage/StoreRecovery.swift"].map {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MedNotes/\($0)")
        }
        let text = try sources.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for prefix in StagingLeftovers.prefixes {
            XCTAssertTrue(text.contains("\"\(prefix)"), "no operation names a folder “\(prefix)…” any more")
        }
    }
}

/// Settings › Data tells the user when an earlier version's unencrypted backups
/// are still on disk, and which restore points are still in the old format.
@MainActor
final class OldBackupNoticeTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.OldBackupNotice"
    private var roots: [DataRoot] = []

    override func setUp() { TestDefaults.clear(Self.defaultsName) }

    override func tearDown() {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func readySession() async throws -> (AppSession, DataRoot) {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady)
        return (session, root)
    }

    func testAnEmptyBackupsFolderGivesNoNotice() async throws {
        let (session, root) = try await readySession()
        try Data().write(to: root.backupsURL.appendingPathComponent(".DS_Store"))
        let loaded = await session.storageSummary()
        let summary = try XCTUnwrap(loaded)
        XCTAssertEqual(summary.oldBackupCount, 0, "a hidden file is not a backup")
    }

    func testBackupsAnEarlierVersionLeftAreCounted() async throws {
        let (session, root) = try await readySession()
        for name in ["backup_2025-01-01", "backup_2025-02-01"] {
            let folder = root.backupsURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("SQLite format 3".utf8).write(to: folder.appendingPathComponent("mednotes.db"))
        }
        let loaded = await session.storageSummary()
        let summary = try XCTUnwrap(loaded)
        XCTAssertEqual(summary.oldBackupCount, 2)
        XCTAssertEqual(summary.oldBackupsURL, root.backupsURL)
    }

    func testARestorePointInTheOldFormatIsMarkedAndANewOneIsNot() async throws {
        let (session, root) = try await readySession()
        let store = try XCTUnwrap(session.store)
        try await store.patients.save(Patient.newRecord())
        let current = try await store.backups.createEncryptedRestorePoint(name: "Pre-restore snapshot")
        // An earlier build sealed restore points under a passphrase compiled into the app.
        let old = root.restorePointsURL.appendingPathComponent("restore_old.mnrp")
        _ = try await store.backups.createEncryptedBackup(
            name: "old", to: old, passphrase: BackupService.legacyRestorePointPassphrase)

        let points = await session.restorePoints()

        XCTAssertEqual(points.first { $0.url.lastPathComponent == "restore_old.mnrp" }?.needsUpgrade, true)
        XCTAssertEqual(points.first { $0.url.lastPathComponent == current }?.needsUpgrade, false)
    }
}
