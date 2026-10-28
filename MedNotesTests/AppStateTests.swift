import XCTest
@testable import MedNotes

/// `app_state`: small named values kept inside the encrypted store.
final class AppStateTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-appstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRoot(_ name: String = "root") throws -> DataRoot {
        try DataRoot(rootURL: tempDir.appendingPathComponent(name, isDirectory: true))
    }

    private func rows(_ root: DataRoot, _ sql: String) throws -> [String] {
        let conn = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        let s = try conn.prepare(sql)
        defer { s.finalize() }
        var out: [String] = []
        while try s.step() { out.append(s.columnText(0) ?? "∅") }
        return out
    }

    private func exec(_ root: DataRoot, _ statements: [String]) throws {
        let conn = try SQLConnection(path: root.databaseURL.path, key: TestKeys.database(for: root))
        defer { conn.close() }
        for statement in statements { try conn.exec(statement) }
    }

    func testANewStoreHasTheTableAndItsMarker() async throws {
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 7)
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try rows(root, "SELECT version FROM migrations WHERE version = '7.0-app-state'"), ["7.0-app-state"])
        XCTAssertEqual(try rows(root, "SELECT name FROM sqlite_master WHERE name = 'app_state'"), ["app_state"])
        await store.close()
    }

    func testValuesAreSavedReplacedAndRemoved() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        let missing = try await store.db.appState(key: "graph.global")
        XCTAssertNil(missing)
        try await store.db.setAppState(key: "graph.global", json: #"{"query":"tag:a"}"#)
        let first = try await store.db.appState(key: "graph.global")
        XCTAssertEqual(first, #"{"query":"tag:a"}"#)
        try await store.db.setAppState(key: "graph.global", json: "{}")
        let second = try await store.db.appState(key: "graph.global")
        XCTAssertEqual(second, "{}")
        try await store.db.removeAppState(key: "graph.global")
        let gone = try await store.db.appState(key: "graph.global")
        XCTAssertNil(gone)
        await store.close()
    }

    func testOversizedOrNamelessValuesAreRefused() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        do {
            try await store.db.setAppState(key: "k", json: String(repeating: "x", count: Database.appStateLimit + 1))
            XCTFail("an oversized value was kept")
        } catch {}
        do {
            try await store.db.setAppState(key: "", json: "{}")
            XCTFail("a nameless value was kept")
        } catch {}
        await store.close()
    }

    /// A v6 store (no table, no marker) opens, gains the table, and keeps its notes.
    func testAVersionSixStoreGainsTheTableOnOpen() async throws {
        let root = try makeRoot()
        let store = try AppStore.testStore(dataRoot: root)
        try await store.notes.save(Note(title: "Kept", content: "text"))
        await store.close()
        try exec(root, ["DROP TABLE app_state", "DELETE FROM migrations WHERE version = '7.0-app-state'"])

        let upgraded = try AppStore.testStore(dataRoot: root)
        XCTAssertEqual(try rows(root, "SELECT version FROM migrations WHERE version = '7.0-app-state'"), ["7.0-app-state"])
        try await upgraded.db.setAppState(key: "k", json: "{}")
        let notes = try await upgraded.notes.loadAll()
        XCTAssertEqual(notes.map(\.title), ["Kept"])
        await upgraded.close()
    }

    func testRebuildingTheIndexesLeavesTheValuesAlone() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "A", content: "#tag text"))
        try await store.db.setAppState(key: "graph.global", json: #"{"query":"patient:Nikos"}"#)
        _ = try await store.db.rebuildIndexes()
        let kept = try await store.db.appState(key: "graph.global")
        XCTAssertEqual(kept, #"{"query":"patient:Nikos"}"#)
        await store.close()
    }

    /// A backup carries the whole database, so the values come back on restore.
    func testABackupRestoresTheValues() async throws {
        let store = try AppStore.testStore(dataRoot: try makeRoot())
        try await store.notes.save(Note(title: "N", content: "x"))
        try await store.db.setAppState(key: "graph.global", json: #"{"query":"patient:Nikos"}"#)
        let file = tempDir.appendingPathComponent("state.mednotesbackup")
        _ = try await store.backups.createEncryptedBackup(
            name: "test", to: file, passphrase: "a long enough passphrase")

        let second = try makeRoot("second")
        let target = try AppStore.testStore(dataRoot: second)
        _ = try await target.backups.restore(
            fromEncryptedBackupAt: file, passphrase: "a long enough passphrase",
            databaseKey: TestKeys.database(for: second),
            attachmentKey: TestKeys.attachment(for: second),
            createRestorePoint: false)
        let restored = try await target.db.appState(key: "graph.global")
        XCTAssertEqual(restored, #"{"query":"patient:Nikos"}"#)
        await store.close()
        await target.close()
    }
}
