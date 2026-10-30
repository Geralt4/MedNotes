import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// The note's right-hand inspector: that it renders where the tests host the
/// editor, takes its width from the body and not the other way round, keeps
/// its setting in the session's preferences, and shows the links panel.
@MainActor
final class NoteInspectorTests: XCTestCase {
    private var roots: [DataRoot] = []
    private var windows: [NSWindow] = []
    private static let defaultsName = "MedNotesTests.NoteInspector"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots = []
        TestDefaults.clear(Self.defaultsName)
    }

    // MARK: - The setting

    func testTheInspectorIsOpenByDefaultAndTheChoiceIsKept() async throws {
        let first = try await makeSession()
        XCTAssertTrue(first.noteInspectorShown, "open by default")
        first.noteInspectorShown = false
        XCTAssertEqual(defaults.object(forKey: AppSession.noteInspectorDefaultsKey) as? Bool, false)

        let secondRoot = try DataRoot.temporary()
        roots.append(secondRoot)
        let second = AppSession.testSession(dataRoot: secondRoot, defaults: defaults)
        addTeardownBlock { @MainActor in
            await second.lockNow(reason: "teardown")
        }
        XCTAssertFalse(second.noteInspectorShown, "a new session reads what the last one chose")
        second.noteInspectorShown = true
        XCTAssertEqual(defaults.object(forKey: AppSession.noteInspectorDefaultsKey) as? Bool, true)
    }

    // MARK: - Layout

    /// The inspector renders in the borderless off-screen window, and it takes
    /// its width from the editor: the body is narrower by about its column.
    func testTheInspectorTakesWidthFromTheBodyWhenShown() async throws {
        let session = try await makeSession()
        let note = try await makeNote(in: session, title: "Wide", content: "Seen on the ward.")
        session.select(note.id)

        var widths: [Bool: CGFloat] = [:]
        for shown in [false, true] {
            session.noteInspectorShown = shown
            let window = host(NoteDetailView().environmentObject(session), width: 1000)
            let body = try await textView(in: window, showing: note.content)
            widths[shown] = try XCTUnwrap(body.enclosingScrollView).frame.width
        }
        XCTAssertEqual(try XCTUnwrap(widths[false]), 1000, accuracy: 2, "hidden: the body spans the pane")
        XCTAssertLessThan(try XCTUnwrap(widths[true]), 1000 - 200, "shown: the inspector has its column")
    }

    /// The inspector must not close and reopen as notes load and switch.
    func testTheInspectorSurvivesSwitchingNotes() async throws {
        let session = try await makeSession()
        let first = try await makeNote(in: session, title: "One", content: "First body.")
        let second = try await makeNote(in: session, title: "Two", content: "Second body.")
        session.noteInspectorShown = true
        session.select(first.id)
        let window = host(NoteDetailView().environmentObject(session), width: 1000)
        let firstBody = try await textView(in: window, showing: first.content)
        let shownWidth = try XCTUnwrap(firstBody.enclosingScrollView).frame.width

        session.select(second.id)
        let secondBody = try await textView(in: window, showing: second.content)
        XCTAssertEqual(try XCTUnwrap(secondBody.enclosingScrollView).frame.width, shownWidth, accuracy: 2)
        XCTAssertTrue(session.noteInspectorShown)
    }

    func testTheWholeWindowStillFitsWithTheInspectorAtAThousandPoints() async throws {
        let session = try await makeSession()
        let note = try await makeNote(in: session, title: "Fit", content: "Fits.")
        session.noteInspectorShown = true
        session.selectedModule = .notes
        session.select(note.id)
        let window = host(ContentView().environmentObject(session), width: 1000)
        _ = try await textView(in: window, showing: note.content)
        XCTAssertTrue(OffscreenHost.hasInk(window.contentView ?? NSView()), "the window rendered blank")
    }

    // MARK: - Properties and outline

    private let sampleBody = """
        ---
        status: draft
        count: 3
        done: true
        seen: 2026-10-27
        tags: [cardio]
        meta:
          nested: 1
        ---
        # Plan
        Text here
        ## Orders
        """

    /// An edit made for one note is not applied to another.
    func testAPropertyEditBelongsToTheNoteItWasMadeFor() {
        let a = Note(title: "A", content: "---\nstatus: draft\n---\n")
        let b = Note(title: "B", content: "---\nstatus: draft\n---\n")
        let edit = FrontMatterEditor.Operation.set(key: "status", value: .text("final"))
        XCTAssertFalse(PropertyEditRouting.accepts(noteID: a.id, draft: b))
        XCTAssertFalse(PropertyEditRouting.accepts(noteID: a.id, draft: nil))
        XCTAssertNil(PropertyEditRouting.draftAfter(edit, expecting: nil, noteID: a.id, draft: b),
                     "a commit that arrives after the user moved to another note changes neither note")
        let changed = PropertyEditRouting.draftAfter(edit, expecting: "status: draft\n", noteID: a.id, draft: a)
        XCTAssertEqual(changed?.content, "---\nstatus: final\n---\n")
        XCTAssertNil(PropertyEditRouting.draftAfter(edit, expecting: "status: other\n", noteID: a.id, draft: a))
    }

    func testThePropertiesShowAsFieldsOfTheRightKind() async throws {
        let session = try await makeSession()
        let note = try await makeNote(in: session, title: "Props", content: sampleBody)
        session.noteInspectorShown = true
        session.select(note.id)
        let window = host(NoteDetailView().environmentObject(session), width: 1000)
        _ = try await textView(in: window, showing: note.content)
        try await waitFor("the property fields") {
            Self.textFieldValues(in: window.contentView).contains("draft")
        }
        let values = Self.textFieldValues(in: window.contentView)
        XCTAssertTrue(values.contains("3"), "a number field: \(values)")
        XCTAssertFalse(values.contains("1"), "the nested entry is not a field of its own")
        XCTAssertFalse(Self.views(NSDatePicker.self, in: window.contentView).isEmpty, "a date picker")
    }

    /// What a committed text field writes. (SwiftUI's focus and submit events
    /// do not reach a field in the inactive test host, so the wiring from a
    /// field to this decision is not covered by a test; it needs a check in
    /// the running app.)
    func testCommittingAFieldWritesOnlyWhatChanged() {
        XCTAssertNil(PropertyCommit.value(for: .text("draft"), text: "draft"))
        XCTAssertEqual(PropertyCommit.value(for: .text("draft"), text: "final"), .text("final"))
        XCTAssertEqual(PropertyCommit.value(for: .text("draft"), text: ""), .text(""))
        XCTAssertNil(PropertyCommit.value(for: .number("3"), text: "3"))
        XCTAssertEqual(PropertyCommit.value(for: .number("3"), text: "4.5"), .number("4.5"))
        XCTAssertEqual(PropertyCommit.value(for: .number("3"), text: "00123"), .text("00123"), "a leading zero is text")
        XCTAssertEqual(PropertyCommit.value(for: .number("3"), text: "abc"), .text("abc"))
        XCTAssertNil(PropertyCommit.value(for: .empty, text: ""))
        XCTAssertEqual(PropertyCommit.value(for: .empty, text: "x"), .text("x"))
        XCTAssertNil(PropertyCommit.value(for: .checkbox(true), text: "anything"))
        XCTAssertNil(PropertyCommit.value(for: .unsupported, text: "anything"))
    }

    func testThePropertyKindsHaveStartingValues() {
        XCTAssertEqual(PropertyKindChoice.text.defaultValue, .empty)
        XCTAssertEqual(PropertyKindChoice.number.defaultValue, .number("0"))
        XCTAssertEqual(PropertyKindChoice.checkbox.defaultValue, .checkbox(false))
        XCTAssertEqual(PropertyKindChoice.list.defaultValue, .list([]))
        if case .date(let day) = PropertyKindChoice.date.defaultValue {
            XCTAssertTrue(FrontMatterYAML.isDate(day), day)
        } else { XCTFail("a date kind starts with a date") }
        if case .dateTime(let moment) = PropertyKindChoice.datetime.defaultValue {
            XCTAssertTrue(FrontMatterYAML.isDateTime(moment), moment)
        } else { XCTFail("a date-and-time kind starts with a datetime") }
        XCTAssertEqual(PropertyKindChoice(kind: "datetime"), .datetime)
        XCTAssertEqual(PropertyKindChoice(kind: "unknown"), .text)
    }

    func testDatesRoundTripInTheFormTheFrontMatterWrites() throws {
        let date = try XCTUnwrap(PropertyDates.date(from: "2026-10-27", time: false))
        XCTAssertEqual(PropertyDates.string(from: date, time: false), "2026-10-27")
        let moment = try XCTUnwrap(PropertyDates.date(from: "2026-10-27T14:30", time: true))
        XCTAssertEqual(PropertyDates.string(from: moment, time: true), "2026-10-27T14:30")
        XCTAssertNil(PropertyDates.date(from: "27/10/2026", time: false))
        // The editor accepts seconds in a stored date-time; the picker must not
        // answer "today" for it.
        let withSeconds = try XCTUnwrap(PropertyDates.date(from: "2024-03-05T14:30:15", time: true))
        XCTAssertEqual(PropertyDates.string(from: withSeconds, time: true), "2024-03-05T14:30")
    }

    // MARK: - Helpers

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    private func makeNote(in session: AppSession, title: String, content: String) async throws -> Note {
        await session.newNote()
        let loaded = await session.loadSelectedNote()
        var note = try XCTUnwrap(loaded)
        note.title = title
        note.content = content
        let saved = await session.save(note)
        XCTAssertTrue(saved)
        return note
    }

    private func host<V: View>(_ view: V, width: CGFloat) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 480))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        let window = NSWindow(
            contentRect: NSRect(x: -20000 - width, y: -20000, width: width, height: 480),
            // Borderless: AppKit moves a titled window at x -20000 onto a screen.
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                       "the test window must stay off every screen")
        return window
    }

    private func textView(in window: NSWindow, showing content: String) async throws -> NSTextView {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let found = Self.textViews(in: window.contentView).first(where: { $0.string == content }) {
                return found
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let shown = Self.textViews(in: window.contentView).map(\.string)
        return try XCTUnwrap(nil as NSTextView?, "never showed \(content.debugDescription); text views show \(shown)")
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var out: [T] = []
        if let match = view as? T { out.append(match) }
        for subview in view.subviews { out += views(type, in: subview) }
        return out
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        views(NSTextField.self, in: view)
    }

    private static func textFieldValues(in view: NSView?) -> [String] {
        textFields(in: view).map(\.stringValue)
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        var out: [NSTextView] = []
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { out.append(text) }
        for subview in view.subviews { out += textViews(in: subview) }
        return out
    }
}
