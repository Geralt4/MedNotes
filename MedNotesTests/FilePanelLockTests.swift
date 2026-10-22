import AppKit
import XCTest
@testable import MedNotes

/// Stands in for the open and save panels without creating one: in the
/// sandboxed app another process draws a real panel, on whatever screen the
/// tester has in front. `run` spins the run loop in the modal-panel mode, as
/// `runModal()` does, so the session gets to run exactly what it would while
/// a real panel is up, and no more. The "user" keeps the panel up until
/// `closesWhen` holds (at most `patience`), then chooses `answer`.
/// `cancelRunning()` closes it with nothing chosen, unless `ignoresCancel`
/// stands in for a choice made just as the cancel landed.
@MainActor
private final class ModalPanelsDouble: FilePanels {
    var answer: URL?
    var ignoresCancel = false
    var patience: TimeInterval = 3
    /// Runs as the panel comes up: whatever happens while it is up.
    var whileOpen: () -> Void = {}
    var closesWhen: () -> Bool = { false }
    /// Runs as it closes: what was true while it was still up.
    var atClose: () -> Void = {}
    private(set) var requests: [FilePanelRequest] = []
    private(set) var cancelCount = 0
    private var isRunning = false
    private var isCancelled = false

    func run(_ request: FilePanelRequest) -> URL? {
        requests.append(request)
        isRunning = true
        isCancelled = false
        defer { isRunning = false }
        whileOpen()
        let mode = CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString)
        let deadline = Date().addingTimeInterval(patience)
        while !(isCancelled && !ignoresCancel), !closesWhen(), Date() < deadline {
            CFRunLoopRunInMode(mode, 0.02, true)
        }
        atClose()
        return isCancelled && !ignoresCancel ? nil : answer
    }

    func cancelRunning() {
        guard isRunning else { return }
        cancelCount += 1
        isCancelled = true
    }
}

/// A lock while a file panel is up, or while what it started is writing
/// outside the container. The panels used to run inside the task that asked
/// for them, which held every other main-actor task, the lock's among them,
/// until they closed; see `AppSession.choose(_:)`.
///
/// Every lock here is posted on a private workspace center passed to
/// `observeSystemLockEvents`, so it goes through the app's own sink and
/// `Task` as a real display sleep does, and never reaches the host's session.
@MainActor
final class FilePanelLockTests: XCTestCase {
    private var tempDir: URL!
    /// The sessions' preferences, the import's saved folder among them: never
    /// the host's own. One fixed suite, emptied around every test, its file
    /// removed when the bundle finishes: the hosted suite runs in the app's
    /// real container, where a suite per test would leave a file per test
    /// behind. See `TestDefaults`.
    private static let defaultsName = "MedNotesTests.FilePanelLock"
    private var defaults: UserDefaults!
    private let passphrase = "a long enough passphrase"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-panels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDownWithError() throws {
        TestDefaults.clear(Self.defaultsName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// A session with an open store and `notes` notes, locking on display
    /// sleep posted on `workspace`, and checking for idleness every
    /// `idleCheck` seconds. Locked at teardown, unless a test already locked
    /// it; that lock may still be closing the connection as the test ends.
    private func session(_ panels: ModalPanelsDouble, workspace: NotificationCenter = NotificationCenter(),
                         notes: Int = 1, idleCheck: TimeInterval? = nil) async throws -> AppSession {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        let session = AppSession(
            dataRoot: root, defaults: defaults,
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)), panels: panels)
        // Before the store opens, which starts the timer.
        if let idleCheck { session.idleCheckInterval = idleCheck }
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        // The closures tests hand the double and the session capture the
        // session, which holds the double: let both go.
        addTeardownBlock { @MainActor in
            panels.whileOpen = {}
            panels.closesWhen = { false }
            panels.atClose = {}
            session.outgoingWillBegin = {}
            session.backupProgress = nil
        }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "precondition: the session must open its store")
        session.observeSystemLockEvents(workspace: workspace, distributed: NotificationCenter())
        for index in 0..<notes {
            try await session.store?.notes.save(Note(title: "Ward round \(index)", content: "PANEL-PLAINTEXT-MARKER"))
        }
        return session
    }

    private func postDisplaySleep(on workspace: NotificationCenter) {
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    }

    /// The audit trail, read after an unlock; polled, because the lock
    /// writes its own entry after the store is detached.
    private func activity(of session: AppSession, awaiting action: String) async -> [AuditLogEntry] {
        await session.unlock()
        let deadline = Date().addingTimeInterval(5)
        var entries = await session.recentActivity()
        while !entries.contains(where: { $0.action == action }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            entries = await session.recentActivity()
        }
        XCTAssertTrue(entries.contains { $0.action == action },
                      "precondition: the trail must be readable after the unlock")
        return entries
    }

    private func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: - Back Up

    /// The reported bug: display sleep while File › Back Up…'s save panel is
    /// up. The lock waited for the panel, keys in memory, and then landed
    /// under the backup the panel had just started.
    func testALockWhileTheBackUpPanelIsUpLocksAtOnceAndClosesIt() async throws {
        let panels = ModalPanelsDouble()
        let workspace = NotificationCenter()
        let session = try await session(panels, workspace: workspace)
        session.presentBackup()
        let destination = tempDir.appendingPathComponent("Locked.mednotesbackup")
        panels.answer = destination
        panels.whileOpen = { self.postDisplaySleep(on: workspace) }
        var lockedWhileUp = false
        panels.atClose = { lockedWhileUp = session.isLocked && session.store == nil }

        var thrown: Error?
        do {
            try await session.performBackup(name: "Locked", passphrase: passphrase)
        } catch {
            thrown = error
        }

        XCTAssertTrue(lockedWhileUp, "the store must lock while the save panel is still up")
        XCTAssertEqual(panels.cancelCount, 1, "the lock must close the panel")
        XCTAssertNil(thrown)
        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.backupFlow)
        XCTAssertNil(session.errorMessage, "no backup had started, so there is nothing to report")
        XCTAssertEqual(contents(of: tempDir), ["root"], "no archive and no staging file")
    }

    /// The user pressed Save just as the lock landed: the panel still hands
    /// back a location, and nothing may be written to it.
    func testALocationChosenAsTheLockLandsGetsNoBackup() async throws {
        let panels = ModalPanelsDouble()
        let workspace = NotificationCenter()
        let session = try await session(panels, workspace: workspace)
        session.presentBackup()
        panels.answer = tempDir.appendingPathComponent("Raced.mednotesbackup")
        panels.ignoresCancel = true
        panels.closesWhen = { session.isLocked }
        panels.whileOpen = { self.postDisplaySleep(on: workspace) }

        var thrown: Error?
        do {
            try await session.performBackup(name: "Raced", passphrase: passphrase)
        } catch {
            thrown = error
        }

        XCTAssertNil(thrown, "a locked store is not a failure to report")
        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(contents(of: tempDir), ["root"], "no archive and no staging file")
        let entries = await activity(of: session, awaiting: "app_lock")
        XCTAssertFalse(entries.contains { $0.action == "backup_create" })
    }

    /// A lock as the archive starts: the backup stops, nothing is left where
    /// the user chose, and the alert after the unlock says no backup was made.
    func testALockAsTheBackupStartsLeavesNothingAndSaysSo() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        session.presentBackup()
        panels.answer = tempDir.appendingPathComponent("Stopped.mednotesbackup")
        panels.closesWhen = { true }
        session.outgoingWillBegin = { await session.lockNow(reason: "test") }

        var thrown: Error?
        do {
            try await session.performBackup(name: "Stopped", passphrase: passphrase)
        } catch {
            thrown = error
        }

        XCTAssertNil(thrown, "the sheet that would show an error is gone; the alert reports it")
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.errorMessage, String(localized: "MedNotes locked before the backup was finished, so nothing was saved to “\("Stopped.mednotesbackup")”. Choose File › Back Up… to make one."))
        XCTAssertEqual(contents(of: tempDir), ["root"], "no archive and no staging file")
    }

    /// The reported symptom: a lock while the archive is being written. The
    /// staging file is there by then; the lock's cancel reaches the archive
    /// through the backup's own task, and the file the user chose to replace
    /// is left as it was.
    func testALockWhileTheArchiveIsWrittenLeavesTheOldFileAndSaysSo() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        var patient = Patient.newRecord()
        patient.files = [PatientFile(name: "scan.pdf", type: .pdf, data: Data(repeating: 7, count: 4096))]
        try await session.store?.patients.save(patient)
        session.presentBackup()
        let destination = tempDir.appendingPathComponent("Older.mednotesbackup")
        let older = Data("an older backup".utf8)
        try older.write(to: destination)
        panels.answer = destination
        panels.closesWhen = { true }
        let staging = destination.appendingPathExtension("staging")
        let sawStaging = SendableFlag()
        session.backupProgress = { _, _ in
            // On the backup's actor, part-way through the archive.
            sawStaging.set(FileManager.default.fileExists(atPath: staging.path))
            Task { @MainActor in await session.lockNow(reason: "test") }
            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }

        try await session.performBackup(name: "Older", passphrase: passphrase)

        XCTAssertTrue(sawStaging.value, "precondition: the lock landed while the archive was being written")
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(try Data(contentsOf: destination), older, "the file the user chose to replace stays as it was")
        XCTAssertEqual(contents(of: tempDir), ["Older.mednotesbackup", "root"], "no staging file beside it")
        XCTAssertEqual(session.errorMessage, String(localized: "MedNotes locked before the backup was finished, so nothing was saved to “\("Older.mednotesbackup")”. Choose File › Back Up… to make one."))
    }

    func testBackUpWritesTheArchiveWhereTheUserChose() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        session.presentBackup()
        let destination = tempDir.appendingPathComponent("Chosen.mednotesbackup")
        panels.answer = destination
        panels.closesWhen = { true }

        try await session.performBackup(name: "Chosen", passphrase: passphrase)

        XCTAssertEqual(panels.requests, [FilePanelRequest(
            kind: .save(suggestedName: "Chosen.mednotesbackup"),
            message: String(localized: "The backup is encrypted with the passphrase you entered."))])
        let opened = try BackupArchiveV2.inspect(at: destination, passphrase: passphrase)
        XCTAssertEqual(opened.manifest.counts["notes"], 1)
        XCTAssertEqual(contents(of: tempDir), ["Chosen.mednotesbackup", "root"], "no staging file beside it")
        XCTAssertNil(session.backupFlow)
        XCTAssertNotNil(session.notice)
        XCTAssertNil(session.errorMessage)
        let entries = await session.recentActivity()
        XCTAssertTrue(entries.contains { $0.action == "backup_create" })
    }

    func testCancellingTheBackUpPanelKeepsTheSheet() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        session.presentBackup()
        panels.answer = nil
        panels.closesWhen = { true }

        try await session.performBackup(name: "Cancelled", passphrase: passphrase)

        XCTAssertEqual(panels.requests.count, 1)
        XCTAssertEqual(session.backupFlow?.id, AppSession.BackupFlow.backUp.id, "the sheet stays for another try")
        XCTAssertNil(session.notice)
        XCTAssertFalse(session.isLocked)
    }

    // MARK: - Markdown export

    /// The export's folder panel returns a folder even though the lock
    /// closed it: no plaintext may leave a locked store.
    func testALockWhileTheExportPanelIsUpExportsNothing() async throws {
        let panels = ModalPanelsDouble()
        let workspace = NotificationCenter()
        let session = try await session(panels, workspace: workspace)
        let folder = tempDir.appendingPathComponent("export", isDirectory: true)
        panels.answer = folder
        panels.ignoresCancel = true
        panels.closesWhen = { session.isLocked }
        panels.whileOpen = { self.postDisplaySleep(on: workspace) }
        var lockedWhileUp = false
        panels.atClose = { lockedWhileUp = session.isLocked && session.store == nil }

        let report = try await session.exportMarkdownVault()

        XCTAssertTrue(lockedWhileUp, "the store must lock while the folder panel is still up")
        XCTAssertEqual(panels.cancelCount, 1, "the lock must close the panel")
        XCTAssertNil(report)
        XCTAssertEqual(contents(of: folder), [], "no plaintext may leave a locked store")
        XCTAssertNil(session.notice)
        XCTAssertNil(session.errorMessage)
    }

    /// A lock as the files start: none is written, the export was already on
    /// the audit trail, and Settings › Data says what happened, whether or not
    /// the main window is open. The next export starts with a clean slate.
    func testALockAsTheExportStartsWritingWritesNoNoteAndSaysSo() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels, notes: 3)
        let folder = tempDir.appendingPathComponent("export", isDirectory: true)
        panels.answer = folder
        panels.closesWhen = { true }
        session.outgoingWillBegin = { await session.lockNow(reason: "test") }

        let report = try await session.exportMarkdownVault()

        XCTAssertNil(report)
        XCTAssertTrue(session.isLocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "no plaintext after the lock")
        XCTAssertEqual(session.markdownExportInterruption, String(localized: "MedNotes locked during the Markdown export: \(0) of \(3) notes were written to “\("export")” as plaintext before it stopped. Export again to write them all."))
        XCTAssertNil(session.errorMessage, "said in Settings, where the export was asked for")
        let entries = await activity(of: session, awaiting: "app_lock")
        XCTAssertEqual(entries.filter { $0.action == "markdown_export" }.count, 1,
                       "the export is audited before any plaintext leaves the app")
        XCTAssertTrue(entries.contains { $0.action == "markdown_export" && $0.details.hasPrefix("notes=3 ") })

        session.outgoingWillBegin = {}
        panels.answer = nil
        _ = try await session.exportMarkdownVault()
        XCTAssertNil(session.markdownExportInterruption, "a new export clears the last one's")
    }

    /// An export the audit trail cannot record does not run.
    func testAnExportTheTrailCannotRecordWritesNothing() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels, notes: 2)
        let folder = tempDir.appendingPathComponent("export", isDirectory: true)
        panels.answer = folder
        panels.closesWhen = { true }
        try await session.store?.db.execForTesting("""
            CREATE TRIGGER refuse_audit BEFORE INSERT ON audit_logs
            BEGIN SELECT RAISE(ABORT, 'audit refused'); END
            """)

        var thrown: Error?
        do {
            _ = try await session.exportMarkdownVault()
        } catch {
            thrown = error
        }

        XCTAssertNotNil(thrown, "the failed audit must reach the Settings pane")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "no plaintext without an audit entry")
        XCTAssertNil(session.notice)
    }

    func testTheExportWritesAndAuditsWhereTheUserChose() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels, notes: 3)
        let folder = tempDir.appendingPathComponent("export", isDirectory: true)
        panels.answer = folder
        panels.closesWhen = { true }

        let exported = try await session.exportMarkdownVault()
        let report = try XCTUnwrap(exported)

        XCTAssertEqual(panels.requests.map(\.kind), [.folder(canCreate: true)])
        XCTAssertEqual(report.notesWritten, 3)
        XCTAssertEqual(contents(of: folder).count, 3)
        XCTAssertEqual(session.notice, String(localized: "Exported \(3) notes as plaintext Markdown."))
        let entries = await session.recentActivity()
        XCTAssertEqual(entries.filter { $0.action == "markdown_export" }.map(\.details),
                       ["notes=3 bytes=\(report.bytesWritten)"])
    }

    func testCancellingTheExportPanelReportsNothing() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        panels.answer = nil
        panels.closesWhen = { true }

        let report = try await session.exportMarkdownVault()

        XCTAssertNil(report, "a cancelled panel is not \"Exported 0 notes\"")
        XCTAssertNil(session.notice)
    }

    // MARK: - Restore and import

    func testALockWhileTheRestorePanelIsUpClosesItAndOpensNoSheet() async throws {
        let panels = ModalPanelsDouble()
        let workspace = NotificationCenter()
        let session = try await session(panels, workspace: workspace)
        panels.answer = tempDir.appendingPathComponent("Old.mednotesbackup")
        panels.ignoresCancel = true
        panels.closesWhen = { session.isLocked }
        panels.whileOpen = { self.postDisplaySleep(on: workspace) }
        var lockedWhileUp = false
        panels.atClose = { lockedWhileUp = session.isLocked && session.store == nil }

        await session.presentRestore()

        XCTAssertEqual(panels.requests.map(\.kind), [.file(types: [.data])])
        XCTAssertTrue(lockedWhileUp)
        XCTAssertEqual(panels.cancelCount, 1, "the lock must close the panel")
        XCTAssertNil(session.backupFlow)
    }

    func testTheRestorePanelOpensTheRestoreSheet() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        let archive = tempDir.appendingPathComponent("Old.mednotesbackup")
        panels.answer = archive
        panels.closesWhen = { true }

        await session.presentRestore()

        XCTAssertEqual(session.backupFlow?.id, AppSession.BackupFlow.restore(fileURL: archive).id)
    }

    func testALockWhileTheImportPanelIsUpOpensNothingAndKeepsNoGrant() async throws {
        let panels = ModalPanelsDouble()
        let workspace = NotificationCenter()
        let session = try await session(panels, workspace: workspace)
        panels.answer = tempDir
        panels.ignoresCancel = true
        panels.closesWhen = { session.isLocked }
        panels.whileOpen = { self.postDisplaySleep(on: workspace) }

        await session.presentImport()

        XCTAssertEqual(panels.requests.map(\.kind), [.folder(canCreate: false)])
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(panels.cancelCount, 1, "the lock must close the panel")
        XCTAssertNil(session.importFlow)
        XCTAssertNil(defaults.data(forKey: AppSession.legacyImportBookmarkKey), "no grant is kept for a folder chosen after a lock")
    }

    /// The chosen folder's grant is kept, in the session's own preferences,
    /// so the next import starts where this one did.
    func testTheImportPanelOpensTheImportSheet() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        let folder = tempDir.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        panels.answer = folder
        panels.closesWhen = { true }

        await session.presentImport()

        XCTAssertEqual(session.importFlow?.folderURL, folder)
        let bookmark = try XCTUnwrap(defaults.data(forKey: AppSession.legacyImportBookmarkKey),
                                     "the grant must be kept in the session's defaults")
        XCTAssertEqual(try Self.resolve(bookmark), folder.resolvingSymlinksInPath().path)
    }

    func testTheImportPanelStartsWhereTheLastImportDid() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        let folder = tempDir.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set(try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                             relativeTo: nil),
                     forKey: AppSession.legacyImportBookmarkKey)
        panels.answer = nil
        panels.closesWhen = { true }

        await session.presentImport()

        let start = try XCTUnwrap(panels.requests.first?.directoryURL)
        XCTAssertEqual(start.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertNil(session.importFlow)
    }

    private static func resolve(_ bookmark: Data) throws -> String {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                       relativeTo: nil, bookmarkDataIsStale: &stale).resolvingSymlinksInPath().path
    }

    // MARK: - The idle lock, and a lock before the panel

    /// The idle timer locks through a `Task` too, so it waited for the panel
    /// as the system events did. Its own check fires here, in the panel's
    /// modal run-loop mode, with five minutes gone by while the panel was up.
    func testTheIdleTimerLocksWhileAPanelIsUp() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels, idleCheck: 0.05)
        session.presentBackup()
        panels.answer = tempDir.appendingPathComponent("Idle.mednotesbackup")
        panels.whileOpen = {
            session.clock = { Date().addingTimeInterval(SecureStoreCoordinator.idleInterval + 60) }
        }
        var lockedWhileUp = false
        panels.atClose = { lockedWhileUp = session.isLocked }

        try await session.performBackup(name: "Idle", passphrase: passphrase)

        XCTAssertTrue(lockedWhileUp, "the idle timer must lock while the panel is up")
        XCTAssertEqual(panels.cancelCount, 1)
        XCTAssertEqual(contents(of: tempDir), ["root"])
    }

    /// A panel opens only from the default run-loop mode, never inside
    /// another modal session: a second one waits for the first to close.
    func testASecondPanelWaitsForTheFirstToClose() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        let legacy = tempDir.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        panels.answer = legacy
        let opened = Date()
        panels.closesWhen = { Date().timeIntervalSince(opened) > 0.3 }
        var second: Task<Void, Never>?
        panels.whileOpen = {
            if second == nil { second = Task { await session.presentImport() } }
        }
        var requestsAtFirstClose: Int?
        panels.atClose = { requestsAtFirstClose = requestsAtFirstClose ?? panels.requests.count }

        await session.presentRestore()
        await second?.value

        XCTAssertEqual(requestsAtFirstClose, 1, "the second panel must not open inside the first")
        XCTAssertEqual(panels.requests.map(\.kind), [.file(types: [.data]), .folder(canCreate: false)])
        XCTAssertEqual(session.importFlow?.folderURL, legacy, "the second panel opens once the first has closed")
    }

    /// A lock that runs after Back Up asked for its panel but before the
    /// panel could open: no panel opens over the locked session.
    func testNoPanelOpensOverASessionThatLockedFirst() async throws {
        let panels = ModalPanelsDouble()
        let session = try await session(panels)
        session.presentBackup()
        panels.answer = tempDir.appendingPathComponent("Late.mednotesbackup")
        panels.closesWhen = { true }

        // Enqueued one after the other: the backup asks for its panel and
        // suspends, then the lock runs, before the run loop gets to the panel.
        let backup = Task { try await session.performBackup(name: "Late", passphrase: passphrase) }
        let lock = Task { await session.lockNow(reason: "test") }
        try await backup.value
        await lock.value

        XCTAssertEqual(panels.requests.count, 0, "the panel must not open once the session has locked")
        XCTAssertEqual(contents(of: tempDir), ["root"])
    }
}

/// A flag the backup's actor can set and the test read.
private final class SendableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ newValue: Bool) { lock.lock(); stored = newValue; lock.unlock() }
}

/// Stands in for an NSSavePanel under `AppKitFilePanels`, which then runs its
/// own code around it: no real panel is created.
@MainActor
private final class StandInPanel: ModalFilePanel {
    var url: URL?
    /// Runs as the panel comes up.
    var whileOpen: () -> Void = {}
    /// Chooses `url` at once rather than waiting to be cancelled.
    var choosesAtOnce = false
    private(set) var cancelCount = 0

    func runModal() -> NSApplication.ModalResponse {
        whileOpen()
        let mode = CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString)
        let deadline = Date().addingTimeInterval(1)
        while !choosesAtOnce, cancelCount == 0, Date() < deadline {
            CFRunLoopRunInMode(mode, 0.02, true)
        }
        return cancelCount > 0 ? .cancel : .OK
    }

    func cancel(_ sender: Any?) {
        cancelCount += 1
    }
}

/// The production panels' own bookkeeping: a lock closes the panel they are
/// running. Everything else here runs on `ModalPanelsDouble`.
@MainActor
final class AppKitFilePanelsTests: XCTestCase {
    private let request = FilePanelRequest(kind: .folder(canCreate: false), message: "Choose a folder.")

    func testCancellingClosesThePanelThatIsRunning() {
        let standIn = StandInPanel()
        standIn.url = FileManager.default.temporaryDirectory
        var requested: [FilePanelRequest] = []
        let panels = AppKitFilePanels(makePanel: { requested.append($0); return standIn })
        standIn.whileOpen = { panels.cancelRunning() }

        XCTAssertNil(panels.run(request), "a panel a lock closed chooses nothing")
        XCTAssertEqual(standIn.cancelCount, 1)
        XCTAssertEqual(requested, [request])

        panels.cancelRunning()
        XCTAssertEqual(standIn.cancelCount, 1, "once run returns, no panel is running")
    }

    func testThePanelsChoiceComesBack() {
        let standIn = StandInPanel()
        standIn.url = FileManager.default.temporaryDirectory
        standIn.choosesAtOnce = true
        let panels = AppKitFilePanels(makePanel: { _ in standIn })

        XCTAssertEqual(panels.run(request), standIn.url)
        XCTAssertEqual(standIn.cancelCount, 0)
    }

    /// A session built without its own panels must never put a real one on
    /// the tester's screen.
    func testNoRealPanelOpensInTheTestHost() {
        XCTAssertNil(AppKitFilePanels().run(request))
    }
}
