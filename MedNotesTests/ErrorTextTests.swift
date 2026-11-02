import XCTest
@testable import MedNotes

/// What a failed backup, restore, import or migration shows: a plain line,
/// with the internals (SQLite messages, table and column names, counts) in the
/// log and not on the screen.
final class ErrorTextTests: XCTestCase {
    private var logged: [(event: SecurityLog.Event, detail: String?)] = []
    private var scratch: URL!
    private var roots: [DataRoot] = []

    override func setUpWithError() throws {
        logged = []
        SecurityLog.observer = { [unowned self] event, _, detail in logged.append((event, detail)) }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-errortext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SecurityLog.observer = nil
        try? FileManager.default.removeItem(at: scratch)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    /// Words that name the database's insides or SQLite's own text.
    private let internals = [
        "todo_items", "patients", "audit_logs", "calendar_events", "notes.title", "evil_trigger", "evil_view",
        "SQLite", "no such", "constraint", "btree", "rows, expected", "PRAGMA", "SELECT"
    ]

    private func assertNoInternals(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in internals {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(word),
                           "“\(text)” shows “\(word)”", file: file, line: line)
        }
    }

    // MARK: - The messages

    func testNoRestoreOrMigrationErrorShowsTablesColumnsOrSQLiteText() {
        let errors: [Error] = [
            BackupError.integrityCheckFailed("*** in database main *** Page 5: btree error in table todo_items"),
            BackupError.unexpectedSchema("missing table patients, trigger evil_trigger, view evil_view"),
            BackupError.countMismatch("attachments", expected: 3, actual: 2),
            BackupError.restoreFailed("install: SQLite step failed: no such column: notes.title"),
            BackupError.safetyCopyIncomplete("A database operation failed: no such table: audit_logs"),
            BackupError.rollbackFailed("kept-folder", "UNIQUE constraint failed: patients.amka"),
            StoreMigrator.MigrationError.stagingFailed("no such table: calendar_events"),
            StoreMigrator.MigrationError.validationFailed("todo_items: 3 rows, expected 4"),
            StoreMigrator.MigrationError.swapFailed("SELECT * FROM patients failed"),
            RestoreRecovery.RecoveryError.couldNotReinstate(folder: "kept-folder", detail: "no such table: patients")
        ]
        for error in errors {
            assertNoInternals(error.localizedDescription)
        }
    }

    /// The folder that holds the user's data after a failed rollback is what
    /// they need, and stays in the message.
    func testTheMessagesThatNameTheKeptFolderStillNameIt() {
        XCTAssertTrue(BackupError.rollbackFailed("kept-folder", "x").localizedDescription.contains("kept-folder"))
        XCTAssertTrue(RestoreRecovery.RecoveryError.couldNotReinstate(folder: "kept-folder", detail: "x")
            .localizedDescription.contains("kept-folder"))
    }

    /// Two migration messages were passed as the detail of another case; they
    /// are cases of their own now and still read as they did.
    func testTheMigrationMessagesThatAreForTheUserStayReadable() {
        XCTAssertEqual(StoreMigrator.MigrationError.backupFromNewerVersion.localizedDescription,
                       String(localized: "The backup was made by a newer MedNotes."))
        XCTAssertEqual(StoreMigrator.MigrationError.nothingToConvert.localizedDescription,
                       String(localized: "There is no unencrypted store to convert."))
    }

    // MARK: - The helper

    func testARawSQLiteErrorBecomesTheGeneralLineAndItsMessageGoesToTheLog() {
        let error = SQLiteError.step("no such table: patients", sql: "SELECT secret FROM patients")

        let text = UserFacingFailure.message(for: error, during: .restore)

        XCTAssertEqual(text, FailureContext.restore.generalMessage)
        assertNoInternals(text)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.event, .restoreFailed)
        XCTAssertEqual(logged.first?.detail, "step: no such table: patients")
        XCTAssertFalse(logged.first?.detail?.contains("SELECT") ?? true, "the statement is never logged")
    }

    func testEachContextLogsUnderItsOwnEventWithItsOwnLine() {
        let error = SQLiteError.exec("disk I/O error", sql: "PRAGMA rekey = 'raw key'")
        let expected: [(FailureContext, SecurityLog.Event)] = [
            (.backup, .backupFailed), (.restore, .restoreFailed),
            (.importing, .importFailed), (.migration, .migrationFailed)
        ]
        for (context, event) in expected {
            logged = []
            let text = UserFacingFailure.message(for: error, during: context)
            XCTAssertEqual(text, context.generalMessage)
            XCTAssertEqual(logged.map(\.event), [event])
            XCTAssertFalse(logged.first?.detail?.contains("raw key") ?? true)
        }
        XCTAssertEqual(Set(expected.map { $0.0.generalMessage }).count, 4, "each context has its own line")
    }

    func testATypedErrorKeepsItsOwnMessageAndItsDetailGoesToTheLog() {
        let error = BackupError.unexpectedSchema("missing table patients")

        let text = UserFacingFailure.message(for: error, during: .restore)

        XCTAssertEqual(text, error.localizedDescription)
        XCTAssertEqual(logged.first?.event, .restoreFailed)
        XCTAssertEqual(logged.first?.detail, "unexpectedSchema: missing table patients")
    }

    /// An error with nothing internal to hide is neither replaced nor logged.
    func testAnErrorWithoutInternalsIsShownAsItIsAndNotLogged() {
        let error = BackupError.missingManifest(URL(fileURLWithPath: "/tmp/x"))

        XCTAssertEqual(UserFacingFailure.message(for: error, during: .restore), error.localizedDescription)
        let failures: Set<SecurityLog.Event> = [.backupFailed, .restoreFailed, .importFailed, .exportFailed, .migrationFailed]
        XCTAssertTrue(logged.filter { failures.contains($0.event) }.isEmpty)
    }

    /// A duplicate AMKA has a plain message of its own that the user can act
    /// on; it is neither replaced nor logged.
    func testADuplicateAMKAKeepsItsOwnMessage() {
        let error = SQLiteError.step("UNIQUE constraint failed: patients.amka", sql: "INSERT INTO patients …")

        let text = UserFacingFailure.message(for: error, during: .importing)

        XCTAssertEqual(text, String(localized: "Another patient already has this AMKA."))
        XCTAssertTrue(logged.isEmpty)
    }

    /// A backup from a newer build tells the user to update, as the migration does.
    func testABackupFromANewerVersionStillSaysSo() {
        XCTAssertEqual(BackupError.madeByNewerVersion.localizedDescription,
                       String(localized: "The backup was made by a newer MedNotes."))
    }

    func testTheRedactionHandlesGreekQuotesAndPathsWithSpaces() {
        let cleaned = SecurityLog.redactingPaths(
            "Το αρχείο «Μαρία Π.pdf» δεν ανοίγει στο /Volumes/My Backup Disk/Μαρία Π.mnbk")
        XCTAssertFalse(cleaned.contains("Μαρία"), cleaned)
        XCTAssertFalse(cleaned.contains("Backup Disk"), cleaned)
        XCTAssertTrue(cleaned.contains("<path>"), cleaned)
    }

    func testTheLoggedDetailHasNoPathsAndNoQuotedFileNames() {
        let error = BackupError.restoreFailed(
            "install: The file “Maria Papadopoulou.pdf” could not be moved to /Users/doctor/Library/Containers/x/Data")

        _ = UserFacingFailure.message(for: error, during: .restore)

        let detail = logged.first?.detail ?? ""
        XCTAssertFalse(detail.contains("Maria"), detail)
        XCTAssertFalse(detail.contains("/Users"), detail)
        XCTAssertTrue(detail.contains("<path>"), detail)
    }

    // MARK: - A real failure

    /// A version 1 backup whose database is not a database: the restore fails
    /// inside SQLite, and what the sheet shows says nothing of it.
    func testAFailedRestoreShowsNoSQLiteText() async throws {
        let root = try DataRoot.temporary()
        roots.append(root)
        let target = try AppStore.testStore(dataRoot: root)
        let children: [String: FileWrapper] = [
            "mednotes.db": FileWrapper(regularFileWithContents: Data("this is not a database at all".utf8)),
            "manifest.json": FileWrapper(regularFileWithContents:
                Data(#"{"name":"old","createdAt":0,"schemaVersion":1,"counts":{}}"#.utf8))
        ]
        for (name, wrapper) in children { wrapper.preferredFilename = name }
        let payload = try XCTUnwrap(FileWrapper(directoryWithFileWrappers: children).serializedRepresentation)
        let sealed = try EncryptedBackupFormat.seal(payload, passphrase: "a long enough passphrase", iterations: 100_000)
        let archive = scratch.appendingPathComponent("broken.mnbk")
        try sealed.write(to: archive)

        do {
            _ = try await target.backups.restore(
                fromLegacyBackupAt: archive, passphrase: "a long enough passphrase",
                databaseKey: TestKeys.database(for: root), attachmentKey: TestKeys.attachment(for: root),
                createRestorePoint: false)
            XCTFail("a file that is not a database cannot be restored")
        } catch {
            let shown = UserFacingFailure.message(for: error, during: .restore)
            assertNoInternals(shown)
            XCTAssertFalse(shown.localizedCaseInsensitiveContains("not a database"), shown)
        }
        await target.close()
    }
}
