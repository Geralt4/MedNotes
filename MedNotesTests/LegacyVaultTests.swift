import XCTest
@testable import MedNotes

/// The old plaintext Markdown mirror (`Vault/`): what migration leaves of it,
/// what the review reports, and what the user may decide before it is deleted.
@MainActor
final class LegacyVaultTests: XCTestCase {
    private var tempDir: URL!
    private static let defaultsName = "MedNotesTests.LegacyVault"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDownWithError() throws {
        TestDefaults.clear(Self.defaultsName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private struct Fixture {
        var session: AppSession
        var root: DataRoot
        /// In the mirror only.
        var mirrorOnly: Note
        /// In both, with different content.
        var divergent: Note
        /// The database's version of `divergent`.
        var databaseVersion: Note
        /// In both, the same.
        var identical: Note
    }

    private func openSession(root: DataRoot) async throws -> AppSession {
        let session = AppSession(
            dataRoot: root, defaults: defaults,
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "precondition: the session must open its store")
        return session
    }

    private func write(_ note: Note, as name: String, in vault: URL) throws {
        try MarkdownExportService.encode(note: note)
            .write(to: vault.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// A store with two notes and a mirror holding: one note the store lacks,
    /// one that differs, one that matches, one file that is not a note at all,
    /// and entries the scan must not read as notes.
    private func fixture() async throws -> Fixture {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        let session = try await openSession(root: root)
        let store = try XCTUnwrap(session.store)

        let databaseVersion = Note(title: "Handover", content: "DATABASE-VERSION")
        let identical = Note(title: "Rounds", content: "SAME-EVERYWHERE")
        try await store.notes.save(databaseVersion)
        try await store.notes.save(identical)
        var divergent = databaseVersion
        divergent.content = "MIRROR-VERSION"
        let mirrorOnly = Note(title: "Only on disk", content: "MIRROR-ONLY-MARKER")

        let vault = root.vaultURL
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try write(mirrorOnly, as: "only-on-disk.md", in: vault)
        try write(divergent, as: "handover.md", in: vault)
        try write(identical, as: "rounds.md", in: vault)
        try "not a note".write(to: vault.appendingPathComponent("broken.md"), atomically: true, encoding: .utf8)
        try "plain text".write(to: vault.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("attachments", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("link.md"),
            withDestinationURL: vault.appendingPathComponent("rounds.md"))
        try "x".write(to: vault.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        return Fixture(session: session, root: root, mirrorOnly: mirrorOnly, divergent: divergent,
                       databaseVersion: databaseVersion, identical: identical)
    }

    private func allNotes(_ session: AppSession) async throws -> [Note] {
        let store = try XCTUnwrap(session.store)
        return try await store.db.loadAllNotes()
    }

    // MARK: - Migration

    func testMigrationLeavesTheVaultMirrorForReview() async throws {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("migrate", isDirectory: true))
        let plaintext = try Database(path: root.databaseURL.path)
        try await plaintext.saveNote(Note(title: "kept", content: "BODY"))
        await plaintext.close()
        try FileManager.default.createDirectory(at: root.vaultURL, withIntermediateDirectories: true)
        let mirrorFile = root.vaultURL.appendingPathComponent("only-here.md")
        try write(Note(title: "Only here", content: "MIRROR-ONLY"), as: "only-here.md", in: root.vaultURL)

        let backupURL = tempDir.appendingPathComponent("pre.mednotesbackup")
        let keyManager = InMemoryKeyManager()
        let migrator = StoreMigrator(dataRoot: root, keyManager: keyManager)
        let backupDB = try Database(path: root.databaseURL.path)
        let backups = BackupService(
            db: backupDB,
            fileStore: nil, restorePointsRoot: root.restorePointsURL)
        _ = try await backups.createEncryptedBackup(
            name: "Pre-encryption", to: backupURL, passphrase: "a long enough passphrase")
        // The app closes it before the swap moves the file.
        await backupDB.close()
        _ = try await migrator.migrate(backupDestination: backupURL, passphrase: "a long enough passphrase")
        await migrator.finishCleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrorFile.path),
                      "migration must not delete notes that may exist only in the mirror")
        // Launch-time recovery, with no journal left, leaves it alone as well.
        try await migrator.recoverInterruptedMigration()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrorFile.path))
    }

    // MARK: - The report

    func testReportNamesWhatItCouldNotReadAsNotes() async throws {
        let f = try await fixture()
        let maybeReport = await f.session.legacyVaultReport()
        let report = try XCTUnwrap(maybeReport)
        XCTAssertEqual(report.unresolvedVaultOnly.map(\.noteID), [f.mirrorOnly.id])
        XCTAssertEqual(report.unresolvedDivergent.map(\.noteID), [f.divergent.id])
        XCTAssertEqual(report.parseFailures, ["broken.md"])
        XCTAssertEqual(report.skipped, ["attachments", "link.md", "readme.txt"],
                       "folders, other files and links are listed; hidden files are not")
        XCTAssertTrue(report.hasUnresolved)
    }

    // MARK: - Deleting

    func testDeleteIsRefusedWhileNotesAreUndecided() async throws {
        let f = try await fixture()
        do {
            try await f.session.deleteLegacyVault()
            XCTFail("the mirror held two undecided notes")
        } catch {
            XCTAssertEqual(error as? LegacyVaultError, .unresolved(2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.vaultURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.root.vaultURL.appendingPathComponent("only-on-disk.md").path))
    }

    func testDeleteWorksOnceEveryNoteIsDecided() async throws {
        let f = try await fixture()
        let imported = try await f.session.resolveLegacyVault(.importMirrorOnly)
        let kept = try await f.session.resolveLegacyVault(.keepDatabase)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(kept, 1)
        try await f.session.deleteLegacyVault()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.vaultURL.path))
        let report = await f.session.legacyVaultReport()
        XCTAssertNil(report)
    }

    // MARK: - Deciding

    func testImportingMirrorOnlyNotesAddsThemAndTouchesNothingElse() async throws {
        let f = try await fixture()
        let count = try await f.session.resolveLegacyVault(.importMirrorOnly)
        XCTAssertEqual(count, 1)
        let notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.mirrorOnly.id }?.content, "MIRROR-ONLY-MARKER")
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "DATABASE-VERSION",
                       "a differing note is not touched by importing the mirror-only ones")
        let maybeReport = await f.session.legacyVaultReport()
        let report = try XCTUnwrap(maybeReport)
        XCTAssertTrue(report.unresolvedVaultOnly.isEmpty)
        XCTAssertEqual(report.unresolvedDivergent.count, 1)
    }

    func testKeepingDatabaseVersionsChangesNothingAndSurvivesARelaunch() async throws {
        let f = try await fixture()
        let count = try await f.session.resolveLegacyVault(.keepDatabase)
        XCTAssertEqual(count, 1)
        let notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "DATABASE-VERSION")
        XCTAssertEqual(notes.count, 2, "keeping adds no notes")

        // The mirror file still differs, so the decision is kept in the
        // preferences, not recomputed: a fresh session sees it as decided.
        await f.session.lockNow(reason: "relaunch")
        let second = try await openSession(root: f.root)
        let maybeReport = await second.legacyVaultReport()
        let report = try XCTUnwrap(maybeReport)
        XCTAssertTrue(report.unresolvedDivergent.isEmpty)
        let again = try await second.resolveLegacyVault(.keepDatabase)
        XCTAssertEqual(again, 0)
    }

    func testImportingMirrorVersionsAsCopiesKeepsBothAndNeverRepeats() async throws {
        let f = try await fixture()
        let count = try await f.session.resolveLegacyVault(.importAsCopies)
        XCTAssertEqual(count, 1)
        var notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "DATABASE-VERSION")
        let copies = notes.filter { $0.id != f.divergent.id && $0.content == "MIRROR-VERSION" }
        XCTAssertEqual(copies.count, 1)
        XCTAssertTrue(copies[0].title.hasPrefix("Handover"))
        XCTAssertNotEqual(copies[0].title, "Handover", "the copy is told apart from the original")

        let again = try await f.session.resolveLegacyVault(.importAsCopies)
        XCTAssertEqual(again, 0)
        notes = try await allNotes(f.session)
        XCTAssertEqual(notes.filter { $0.content == "MIRROR-VERSION" }.count, 1, "no second copy")
    }

    func testReplacingWithMirrorVersionsOverwritesTheDatabaseNote() async throws {
        let f = try await fixture()
        let count = try await f.session.resolveLegacyVault(.useMirror)
        XCTAssertEqual(count, 1)
        let notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "MIRROR-VERSION")
        XCTAssertEqual(notes.count, 2)
    }

    func testReplacingWithMirrorVersionsKeepsARestorePointThatBringsTheNotesBack() async throws {
        let f = try await fixture()

        _ = try await f.session.resolveLegacyVault(.useMirror)

        var notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "MIRROR-VERSION")
        let points = await f.session.restorePoints()
        let snapshot = try XCTUnwrap(points.first { $0.name == "Pre-mirror snapshot" },
                                     "the current notes must be kept before they are overwritten")
        XCTAssertEqual(BackupFlowSheet.summary(counts: snapshot.counts).isEmpty, false)

        // And that point puts the database's own version back.
        try await f.session.restoreFromRestorePoint(snapshot)
        notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "DATABASE-VERSION")
    }

    /// An open editor holds the note being replaced, with typing not yet saved.
    /// Its edits go to the store first (so the safety copy holds them), the
    /// mirror's text replaces the note, and the editor must not write its old
    /// draft back over that when it is left.
    func testReplacingANoteAnEditorHasOpenKeepsItsUnsavedEditsInTheSafetyCopyAndDoesNotWriteThemBack() async throws {
        let f = try await fixture()
        var draft = f.databaseVersion
        draft.content = "UNSAVED-EDIT"
        let token = UUID()
        f.session.registerOpenEditor(token) { .note(draft, edited: true) }
        f.session.selectedModule = .notes
        f.session.selectedNoteId = f.divergent.id

        let count = try await f.session.resolveLegacyVault(.useMirror)

        XCTAssertEqual(count, 1)
        var notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "MIRROR-VERSION")
        XCTAssertNil(f.session.selectedNoteId, "a replaced note opens afresh, not on its old draft")
        XCTAssertFalse(f.session.unregisterOpenEditor(token),
                       "the editor is settled: it must not save its stale draft when it goes")

        // The safety copy was taken after the edits were saved.
        let points = await f.session.restorePoints()
        let snapshot = try XCTUnwrap(points.first { $0.name == "Pre-mirror snapshot" })
        try await f.session.restoreFromRestorePoint(snapshot)
        notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "UNSAVED-EDIT")
    }

    func testAnEditorOnANoteThatIsNotReplacedKeepsWorkingAndItsEditsAreSaved() async throws {
        let f = try await fixture()
        var draft = f.identical
        draft.content = "TYPED-IN-ANOTHER-NOTE"
        let token = UUID()
        f.session.registerOpenEditor(token) { .note(draft, edited: true) }
        f.session.selectedModule = .notes
        f.session.selectedNoteId = f.identical.id

        _ = try await f.session.resolveLegacyVault(.useMirror)

        let notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.identical.id }?.content, "TYPED-IN-ANOTHER-NOTE")
        XCTAssertEqual(f.session.selectedNoteId, f.identical.id, "an unrelated note stays open")
        XCTAssertTrue(f.session.unregisterOpenEditor(token), "its editor is not settled")
    }

    func testNothingIsReplacedWhenTheSafetyCopyCannotBeMade() async throws {
        let f = try await fixture()
        // A file where the restore point folder should be: no point can be written.
        try FileManager.default.removeItem(at: f.root.restorePointsURL)
        try Data("not a folder".utf8).write(to: f.root.restorePointsURL)

        do {
            _ = try await f.session.resolveLegacyVault(.useMirror)
            XCTFail("without a safety copy nothing may be replaced")
        } catch {}

        let notes = try await allNotes(f.session)
        XCTAssertEqual(notes.first { $0.id == f.divergent.id }?.content, "DATABASE-VERSION")
    }

    func testDecisionsAreRefusedWhileLocked() async throws {
        let f = try await fixture()
        await f.session.lockNow(reason: "test")
        do {
            _ = try await f.session.resolveLegacyVault(.importMirrorOnly)
            XCTFail("a locked session has no store to write to")
        } catch {
            // Expected: the store is closed.
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.root.vaultURL.appendingPathComponent("only-on-disk.md").path))
    }
}
