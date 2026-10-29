import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// A value typed into an inspector property field is written to the note when
/// the field is submitted or loses focus. A lock reads the open drafts at once
/// and unmounts the editor, so that write used to arrive after the draft had
/// been read, and the typed value was lost. The session now asks such fields to
/// write what they hold before it reads a draft.
@MainActor
final class PropertyFieldLockTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.PropertyFieldLock"
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

    func testAValueTypedInAPropertyFieldIsKeptWhenTheSessionLocks() async throws {
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
        session.selectedModule = .notes
        session.noteInspectorShown = true
        await session.newNote()
        let created = await session.loadSelectedNote()
        var note = try XCTUnwrap(created)
        note.title = "Props"
        note.content = "---\nstatus: draft\n---\nBody text."
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        session.select(note.id)

        let window = try offscreen.hostForTyping(
            NoteDetailView().environmentObject(session), width: 1000, height: 800)
        let field = try await propertyField(showing: "draft", in: window)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("ed", replacementRange: editor.selectedRange())

        await session.lockNow(reason: "idle")

        let file = try Database.testDatabase(path: root.databaseURL.path, root: root)
        let notes = try await file.loadAllNotes()
        await file.close()
        let stored = try XCTUnwrap(notes.first { $0.id == note.id })
        XCTAssertTrue(stored.content.contains("status: drafted"),
                      "the typed value must be written before the lock reads the note: \(stored.content)")
    }

    private func propertyField(showing value: String, in window: NSWindow,
                               timeout: TimeInterval = 15) async throws -> NSTextField {
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

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }
}
