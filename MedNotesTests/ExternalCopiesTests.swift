import XCTest
@testable import MedNotes

/// "Open Externally" copies are plaintext files in the container's temporary
/// directory, and the XCTest host is this app, in the owner's real container.
/// A test session's lock must empty only its own root's folder. The app's
/// folder holds the copies the owner's running MedNotes has handed to a
/// viewer, and deleting one pulls the file out from under Preview. The same
/// goes for the app's swipe diagnostics log beside it.
@MainActor
final class ExternalCopiesTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.ExternalCopies"
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestDefaults.clear(Self.defaultsName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeRoot(_ name: String = "root") throws -> DataRoot {
        try DataRoot(rootURL: tempDir.appendingPathComponent(name, isDirectory: true))
    }

    /// Stands in for a copy the owner's MedNotes handed to a viewer: a file in
    /// the app's real folder, which this host shares. Removed at teardown,
    /// with the folder if the test made it.
    private func placeAppCopy() throws -> URL {
        let folder = DataRoot.appExternalCopiesURL
        let madeFolder = !FileManager.default.fileExists(atPath: folder.path)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent("MedNotesTests-\(UUID().uuidString)-open-in-preview.txt")
        try Data("Stands in for a copy open in Preview.".utf8).write(to: copy)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: copy)
            if madeFolder { rmdir(folder.path) }
        }
        return copy
    }

    /// A copy a crashed run of `root`'s store left in its folder: nothing
    /// tracks it, so only the purge removes it.
    private func placeOrphan(in root: DataRoot) throws -> URL {
        try FileManager.default.createDirectory(
            at: root.externalCopiesURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let orphan = root.externalCopiesURL.appendingPathComponent("\(UUID().uuidString)-scan.pdf")
        try Data("left by a crash".utf8).write(to: orphan)
        // Only this file, and its folder once empty: never a purge, which in
        // the app's folder would delete the owner's copies.
        addTeardownBlock {
            try? FileManager.default.removeItem(at: orphan)
            if root.externalCopiesURL.standardizedFileURL != DataRoot.appExternalCopiesURL.standardizedFileURL {
                rmdir(root.externalCopiesURL.path)
            }
        }
        return orphan
    }

    private func readySession(_ root: DataRoot) async throws -> AppSession {
        let session = AppSession.testSession(dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "precondition: the session must open its store")
        return session
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Folders

    /// The app's own session keeps the folder it has always used, which its
    /// launch, lock and quit empty.
    func testTheAppKeepsItsExternalFolder() {
        XCTAssertEqual(
            DataRoot.appExternalCopiesURL.standardizedFileURL,
            FileManager.default.temporaryDirectory
                .appendingPathComponent("MedNotesExternal", isDirectory: true).standardizedFileURL)
    }

    /// The real root and the preview root, built over a stand-in for
    /// Application Support: both use the app's folder, which is the one the
    /// launch and quit purges empty.
    func testTheAppsOwnRootsUseTheAppsFolder() throws {
        let base = tempDir.appendingPathComponent("Application Support", isDirectory: true)
        let app = DataRoot.appExternalCopiesURL.standardizedFileURL
        XCTAssertEqual(try DataRoot.applicationSupport(base: base).externalCopiesURL.standardizedFileURL, app)
        #if DEBUG
        XCTAssertEqual(try DataRoot.preview(reset: false, base: base).externalCopiesURL.standardizedFileURL, app)
        #endif
    }

    func testEveryOtherRootHasAFolderOfItsOwn() throws {
        let first = try makeRoot("first")
        let second = try makeRoot("second")
        let firstAgain = try makeRoot("first")
        XCTAssertNotEqual(first.externalCopiesURL.standardizedFileURL,
                          DataRoot.appExternalCopiesURL.standardizedFileURL)
        XCTAssertNotEqual(first.externalCopiesURL, second.externalCopiesURL)
        XCTAssertEqual(first.externalCopiesURL, firstAgain.externalCopiesURL,
                       "the folder belongs to the root, not to one value of it")
        XCTAssertEqual(first.externalCopiesURL.deletingLastPathComponent().standardizedFileURL,
                       FileManager.default.temporaryDirectory.standardizedFileURL,
                       "plaintext stays in the temporary directory, out of the root and its backups")
        XCTAssertFalse(exists(first.externalCopiesURL), "nothing is created before a copy is opened")
    }

    // MARK: - Locks

    /// The review's case: the owner has an attachment open in Preview while
    /// the suite runs, and a test session locks.
    func testATestSessionsLockLeavesTheAppsCopiesAlone() async throws {
        let appCopy = try placeAppCopy()
        let root = try makeRoot()
        let session = try await readySession(root)

        let store = try XCTUnwrap(session.store)
        let id = try await store.fileStore.store(Data("scan".utf8))
        let opened = try await store.fileStore.openExternally(storageID: id, preferredName: "scan.pdf")
        XCTAssertEqual(opened.deletingLastPathComponent().standardizedFileURL,
                       root.externalCopiesURL.standardizedFileURL,
                       "a test session's copies go to its root's folder")
        let orphan = try placeOrphan(in: root)

        await session.lockNow(reason: "test")

        XCTAssertTrue(exists(appCopy), "a test session's lock must leave the app's copies alone")
        XCTAssertFalse(exists(opened), "the lock removes the session's own copy")
        XCTAssertFalse(exists(orphan), "and whatever else is in its root's folder")
        XCTAssertFalse(exists(root.externalCopiesURL), "and the emptied folder itself")
    }

    /// The coordinator empties the folder on its own lock too, without the
    /// session around it.
    func testACoordinatorLockEmptiesOnlyItsRootsFolder() throws {
        let appCopy = try placeAppCopy()
        let root = try makeRoot()
        let coordinator = SecureStoreCoordinator(
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)), dataRoot: root)
        let orphan = try placeOrphan(in: root)

        coordinator.lock()

        XCTAssertTrue(exists(appCopy), "a test coordinator's lock must leave the app's copies alone")
        XCTAssertFalse(exists(orphan))
    }

    /// The app writes its swipe diagnostics log in the same temporary
    /// directory, and its own lock deletes it; a test session's must not.
    func testATestSessionsLockLeavesTheAppsSwipeLogAlone() async throws {
        let log = URL(fileURLWithPath: SwipeDiagnostics.logPath)
        try XCTSkipIf(FileManager.default.fileExists(atPath: log.path),
                      "the app's swipe log exists: a trace being collected is left alone")
        let marker = Data("Stands in for the app's swipe log.\n".utf8)
        try marker.write(to: log, options: .withoutOverwriting)
        // Only while it is still this test's: the owner's MedNotes may have
        // started appending to it.
        addTeardownBlock {
            if (try? Data(contentsOf: log)) == marker { try? FileManager.default.removeItem(at: log) }
        }
        let session = try await readySession(try makeRoot())

        await session.lockNow(reason: "test")

        XCTAssertTrue(exists(log), "a test session's lock must leave the app's swipe log alone")
    }

    /// Nor does the host write to it: it reads the owner's preferences, where
    /// the diagnostics may be on, and would log scrolling over its windows.
    func testTheTestHostWritesNoSwipeDiagnostics() {
        XCTAssertFalse(SwipeDiagnostics.isEnabled)
    }
}
