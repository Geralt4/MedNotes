import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// Switching away from an editor with unsaved changes must save once and then
/// load the next record. A save bumps the module epoch, which restarts the
/// detail view's `.task`; without marking the saved draft clean, the restarted
/// task sees the same unsaved draft and saves it again, and again.
@MainActor
final class EditorSwitchTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.EditorSwitch"
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

    func testSwitchingFromAnEditedTodoSavesOnceAndShowsTheNextTodo() async throws {
        let session = try await makeSession()
        let second = try await makeTodo(in: session, title: "Beta")
        // Made last, so it is the todo the user "just created": it opens in
        // the editor. Others open as a record, with no title field to type in.
        let first = try await makeTodo(in: session, title: "Alpha")

        session.selectTodo(first.id)
        let window = try offscreen.hostForTyping(
            TodoDetailView().environmentObject(session), width: 640, height: 700)
        let title = try await field(in: window, value: "Alpha")
        XCTAssertTrue(window.makeFirstResponder(title))
        try type("!", in: title)

        let epochBefore = session.todoEpoch
        session.selectTodo(second.id)
        // The next todo opens as a record, which has no text field at all:
        // the edited editor is gone and the record is showing.
        try await waitUntilNoField(in: window, value: "Alpha!", timeout: 15)
        XCTAssertTrue(Self.textFields(in: window.contentView).isEmpty,
                      "an editor is still showing after switching to the next todo")
        // Let a runaway re-save loop show itself.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertLessThanOrEqual(
            session.todoEpoch - epochBefore, 3,
            "switching away re-saved the edited todo over and over")
        let stored = try await session.store?.todos.load(id: first.id)
        XCTAssertEqual(stored?.title, "Alpha!")
    }

    // MARK: - Helpers

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    private func makeTodo(in session: AppSession, title: String) async throws -> TodoItem {
        await session.newTodo()
        let loaded = await session.loadSelectedTodo()
        var todo = try XCTUnwrap(loaded)
        todo.title = title
        let saved = await session.save(todo)
        XCTAssertTrue(saved)
        return todo
    }

    private func type(_ text: String, in field: NSTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func field(in window: NSWindow, value: String,
                       timeout: TimeInterval = 10) async throws -> NSTextField {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let field = Self.textFields(in: window.contentView).first(where: { $0.stringValue == value }) {
                return field
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let shown = Self.textFields(in: window.contentView).map(\.stringValue)
        return try XCTUnwrap(nil as NSTextField?, "never showed “\(value)”; fields show \(shown)")
    }

    private func waitUntilNoField(in window: NSWindow, value: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if !Self.textFields(in: window.contentView).contains(where: { $0.stringValue == value }) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the editor still shows “\(value)” after switching")
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }
}
