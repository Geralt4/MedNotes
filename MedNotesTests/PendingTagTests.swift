import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// A tag typed into a tag field and not added used to be dropped by Done,
/// leaving the record and a lock. It is now added wherever the editor is left.
final class PendingTagTests: XCTestCase {
    func testTheTextIsTrimmedAndAddedAfterTheExistingTags() {
        XCTAssertEqual(PendingTag.merged("  diabetes \n", into: ["cardio"]), ["cardio", "diabetes"])
        XCTAssertEqual(PendingTag.merged("Υπέρταση", into: []), ["Υπέρταση"])
    }

    func testNothingIsAddedForEmptyTextOrATagThatIsAlreadyThere() {
        XCTAssertNil(PendingTag.merged("", into: ["cardio"]))
        XCTAssertNil(PendingTag.merged("  \n", into: ["cardio"]))
        XCTAssertNil(PendingTag.merged("cardio", into: ["cardio"]))
        XCTAssertNil(PendingTag.merged(" cardio ", into: ["cardio"]), "compared after trimming")
    }
}

/// The same, through the todo editor a user actually leaves: type into the tag
/// field, then lock, or move to another todo.
@MainActor
final class PendingTagEditorTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.PendingTag"
    private var roots: [DataRoot] = []
    private let offscreen = OffscreenHost()

    override func setUp() {
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDown() {
        offscreen.tearDown()
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    func testATagTypedAndNotAddedIsKeptWhenTheSessionLocks() async throws {
        let (session, root) = try await makeSession()
        let todo = try await makeOpenTodo(in: session)
        let window = try offscreen.hostForTyping(
            TodoDetailView().environmentObject(session), width: 900, height: 900)
        let field = try await tagField(in: window)
        XCTAssertTrue(window.makeFirstResponder(field))
        try type("diabetes", in: field)

        await session.lockNow(reason: "idle")

        let file = try Database.testDatabase(path: root.databaseURL.path, root: root)
        let stored = try await file.loadTodo(id: todo.id)
        await file.close()
        XCTAssertEqual(stored?.tags, ["diabetes"])
    }

    func testATagTypedAndNotAddedIsKeptWhenMovingToAnotherTodo() async throws {
        let (session, _) = try await makeSession()
        let other = try await makeSavedTodo(in: session, title: "Other")
        let todo = try await makeOpenTodo(in: session)
        let window = try offscreen.hostForTyping(
            TodoDetailView().environmentObject(session), width: 900, height: 900)
        let field = try await tagField(in: window)
        XCTAssertTrue(window.makeFirstResponder(field))
        try type("diabetes", in: field)

        session.selectTodo(other.id)

        var stored: TodoItem?
        for _ in 0..<200 where stored?.tags.isEmpty != false {
            try await Task.sleep(nanoseconds: 50_000_000)
            stored = try await session.store?.todos.load(id: todo.id)
        }
        XCTAssertEqual(stored?.tags, ["diabetes"])
        let untouched = try await session.store?.todos.load(id: other.id)
        XCTAssertEqual(untouched?.tags, [], "it belongs to the todo it was typed for")
    }

    // MARK: - Helpers

    private func makeSession() async throws -> (AppSession, DataRoot) {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        session.selectedModule = .todos
        return (session, root)
    }

    /// A todo with a title of its own, saved, and not the one left selected.
    private func makeSavedTodo(in session: AppSession, title: String) async throws -> TodoItem {
        await session.newTodo()
        let loaded = await session.loadSelectedTodo()
        var todo = try XCTUnwrap(loaded)
        todo.title = title
        let saved = await session.save(todo)
        XCTAssertTrue(saved)
        return todo
    }

    /// A new todo, selected and asking for focus, so its editor opens.
    private func makeOpenTodo(in session: AppSession) async throws -> TodoItem {
        await session.newTodo()
        let loaded = await session.loadSelectedTodo()
        return try XCTUnwrap(loaded)
    }

    private func type(_ text: String, in field: NSTextField) throws {
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
        let shown = Self.textFields(in: window.contentView).map { $0.placeholderString ?? $0.stringValue }
        return try XCTUnwrap(nil as NSTextField?, "never showed “\(prompt)”; fields show \(shown)")
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }
}
