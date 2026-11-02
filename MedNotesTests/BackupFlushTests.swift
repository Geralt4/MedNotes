import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// A file panel that answers at once.
private final class AnsweringPanels: FilePanels {
    var answer: URL?
    func run(_ request: FilePanelRequest) -> URL? { answer }
    func cancelRunning() {}
}

/// What is typed in an open editor and not yet saved is in what a backup, a
/// restore point and the Markdown export read: each editor on screen saves
/// through its own Save first (`commitEditorsOnScreen`), as Done does.
///
/// The editors are real ones, hosted off screen, with a tag typed into the tag
/// field and neither added nor saved: the case that has no other way into the
/// store.
@MainActor
final class BackupFlushTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.BackupFlush"
    private let passphrase = "a long enough passphrase"
    private var tempDir: URL!
    private var panels: AnsweringPanels!
    private let offscreen = OffscreenHost()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        panels = AnsweringPanels()
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDownWithError() throws {
        offscreen.tearDown()
        TestDefaults.clear(Self.defaultsName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot(rootURL: tempDir.appendingPathComponent("root", isDirectory: true))
        let session = AppSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName),
            keyManager: InMemoryKeyManager(key: TestKeys.root(for: root)), panels: panels)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    /// A saved todo, open in its editor, with "diabetes" typed into the tag
    /// field and not added.
    private func openTodoWithATypedTag(_ session: AppSession) async throws -> TodoItem {
        session.selectedModule = .todos
        await session.newTodo()
        let loaded = await session.loadSelectedTodo()
        var todo = try XCTUnwrap(loaded)
        todo.title = "Chase labs"
        let saved = await session.save(todo)
        XCTAssertTrue(saved)
        let window = try offscreen.hostForTyping(
            TodoDetailView().environmentObject(session), width: 900, height: 900)
        try await typeIntoTagField("diabetes", in: window)
        return todo
    }

    /// A saved note, open in its editor with the inspector shown, with "ed"
    /// typed after "draft" in the `status` property field and not committed.
    private func openNoteWithATypedProperty(_ session: AppSession) async throws -> Note {
        session.selectedModule = .notes
        session.noteInspectorShown = true
        await session.newNote()
        let loaded = await session.loadSelectedNote()
        var note = try XCTUnwrap(loaded)
        note.title = "Props"
        note.content = "---\nstatus: draft\n---\nBody text."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        session.select(note.id)
        let window = try offscreen.hostForTyping(
            NoteDetailView().environmentObject(session), width: 1000, height: 800)
        let deadline = Date().addingTimeInterval(15)
        var field: NSTextField?
        while field == nil, Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            field = Self.textFields(in: window.contentView).first { $0.stringValue == "draft" }
            if field == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let propertyField = try XCTUnwrap(field, "the inspector never showed the status value")
        XCTAssertTrue(window.makeFirstResponder(propertyField))
        let editor = try XCTUnwrap(propertyField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("ed", replacementRange: editor.selectedRange())
        return note
    }

    private func typeIntoTagField(_ text: String, in window: NSWindow) async throws {
        let field = try await tagField(in: window)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func tagField(in window: NSWindow, timeout: TimeInterval = 15) async throws -> NSTextField {
        let prompt = String(localized: "Add a tag")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let field = Self.textFields(in: window.contentView).first(where: { $0.placeholderString == prompt }) {
                return field
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(nil as NSTextField?, "the editor never showed “\(prompt)”")
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }

    private func allText(in folder: URL) -> String {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// A folder in the legacy layout holding one note, from the test bundle.
    private func legacyNotesFolder() throws -> URL {
        let source = tempDir.appendingPathComponent("legacy-\(UUID().uuidString)/MedNotes", isDirectory: true)
        let notes = source.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "note_simple", withExtension: "json"),
                                    "fixture note_simple is missing from the test bundle")
        try Data(contentsOf: fixture).write(to: notes.appendingPathComponent("note_simple.json"))
        return source
    }

    // MARK: - Back Up

    func testATagTypedInAnOpenEditorIsInTheBackup() async throws {
        let session = try await makeSession()
        let todo = try await openTodoWithATypedTag(session)
        let archive = tempDir.appendingPathComponent("Ward.mednotesbackup")
        panels.answer = archive

        try await session.performBackup(name: "Ward", passphrase: passphrase)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let store = try XCTUnwrap(session.store)
        let loaded = try await store.todos.load(id: todo.id)
        var later = try XCTUnwrap(loaded)
        XCTAssertEqual(later.tags, ["diabetes"], "the editor saved before the backup read the store")
        // The backup holds it: change the todo, restore, and the tag is back.
        later.tags = []
        later.title = "Changed afterwards"
        _ = try await store.todos.save(later)
        try await session.performRestore(from: archive, passphrase: passphrase)
        let restored = try await XCTUnwrap(session.store).todos.load(id: todo.id)
        XCTAssertEqual(restored?.tags, ["diabetes"])
        XCTAssertEqual(restored?.title, "Chase labs")
    }

    /// The editor's baseline moves with the store, so what Revert and Cancel go
    /// back to is what was saved: the editor does not still report the edit as
    /// unsaved while the store already holds it.
    func testAfterABackupTheEditorNoLongerReportsTheEditAsUnsaved() async throws {
        let session = try await makeSession()
        _ = try await openTodoWithATypedTag(session)
        panels.answer = tempDir.appendingPathComponent("Ward.mednotesbackup")

        try await session.performBackup(name: "Ward", passphrase: passphrase)

        let drafts = session.openEditorDrafts().map(\.draft)
        XCTAssertEqual(drafts.count, 1)
        guard case .todo(let draft, let edited)? = drafts.first else { return XCTFail("no todo editor: \(drafts)") }
        XCTAssertFalse(edited, "the store holds the edit, so the editor has nothing unsaved")
        XCTAssertEqual(draft.tags, ["diabetes"])
    }

    /// A new record nobody touched is neither saved nor discarded by a backup.
    func testABackupLeavesAnUntouchedNewRecordUnderItsEditorAlone() async throws {
        let session = try await makeSession()
        session.selectedModule = .todos
        await session.newTodo()
        let loaded = await session.loadSelectedTodo()
        let fresh = try XCTUnwrap(loaded)
        _ = try offscreen.hostForTyping(TodoDetailView().environmentObject(session), width: 900, height: 900)
        panels.answer = tempDir.appendingPathComponent("Plain.mednotesbackup")

        try await session.performBackup(name: "Plain", passphrase: passphrase)

        let stillThere = try await XCTUnwrap(session.store).todos.load(id: fresh.id)
        XCTAssertNotNil(stillThere, "a backup must not discard the new record under an open editor")
    }

    // MARK: - Markdown export

    func testAValueTypedInAnOpenNotesPropertyFieldIsInTheMarkdownExport() async throws {
        let session = try await makeSession()
        _ = try await openNoteWithATypedProperty(session)
        let folder = tempDir.appendingPathComponent("export", isDirectory: true)
        panels.answer = folder

        let report = try await session.exportMarkdownVault()

        XCTAssertEqual(report?.notesWritten, 1)
        XCTAssertTrue(allText(in: folder).contains("status: drafted"),
                      "the export read the note without the typed value: \(allText(in: folder))")
    }

    // MARK: - Restore point before an import

    func testATagTypedInAnOpenEditorIsInThePreImportRestorePoint() async throws {
        let session = try await makeSession()
        let todo = try await openTodoWithATypedTag(session)

        try await session.performImport(from: try legacyNotesFolder())

        let points = await session.restorePoints()
        let snapshot = try XCTUnwrap(points.first { $0.name == "Pre-import snapshot" })
        let store = try XCTUnwrap(session.store)
        let loaded = try await store.todos.load(id: todo.id)
        var later = try XCTUnwrap(loaded)
        later.tags = []
        _ = try await store.todos.save(later)
        try await session.restoreFromRestorePoint(snapshot)
        let restored = try await XCTUnwrap(session.store).todos.load(id: todo.id)
        XCTAssertEqual(restored?.tags, ["diabetes"])
    }

    // MARK: - An editor that cannot save

    /// One editor that cannot save (an Add row with text, a duplicate AMKA)
    /// stops all three, and nothing is made.
    func testAnEditorThatCannotSaveStopsTheBackupTheExportAndTheImport() async throws {
        let session = try await makeSession()
        let token = UUID()
        session.registerOpenEditor(token, draft: { nil }, commit: { false })
        let archive = tempDir.appendingPathComponent("Blocked.mednotesbackup")
        let folder = tempDir.appendingPathComponent("blocked-export", isDirectory: true)

        panels.answer = archive
        do {
            try await session.performBackup(name: "Blocked", passphrase: passphrase)
            XCTFail("the backup went ahead without the edit")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "\(1) edit(s) could not be saved, so no backup was made."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))

        panels.answer = folder
        do {
            _ = try await session.exportMarkdownVault()
            XCTFail("the export went ahead without the edit")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "\(1) edit(s) could not be saved, so nothing was exported."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        do {
            try await session.performImport(from: try legacyNotesFolder())
            XCTFail("the import went ahead without the edit")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "\(1) edit(s) could not be saved, so nothing was imported."))
        }
        let points = await session.restorePoints()
        XCTAssertTrue(points.isEmpty, "no restore point was made without the edit")
        _ = session.unregisterOpenEditor(token)
    }

    /// An editor that registered no commit is not counted as failing.
    func testAnEditorWithoutACommitDoesNotStopABackup() async throws {
        let session = try await makeSession()
        let token = UUID()
        session.registerOpenEditor(token) { nil }
        let archive = tempDir.appendingPathComponent("Fine.mednotesbackup")
        panels.answer = archive

        try await session.performBackup(name: "Fine", passphrase: passphrase)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        _ = session.unregisterOpenEditor(token)
    }
}
