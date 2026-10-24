import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// The note body is an AppKit text view whose typing undo actions hold
/// ranges into the text they were typed into. When the editor replaces that
/// text itself — another note loads, a [[ completion, a template, Revert —
/// ⌘Z must not replay them against the new text: measured off screen, that
/// garbles it, or raises NSRangeException once the ranges no longer fit.
@MainActor
final class NoteEditorUndoTests: XCTestCase {
    private var roots: [DataRoot] = []
    private var windows: [NSWindow] = []
    /// The sessions' preferences: never the host's own, which are the
    /// owner's. One fixed suite, emptied around every test. See `TestDefaults`.
    private static let defaultsName = "MedNotesTests.NoteEditorUndo"
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

    func testTypingInOneNoteCannotBeUndoneIntoTheNext() async throws {
        let edit = try await typeThenSwitchNotes()
        XCTAssertFalse(edit.undoManager.canUndo, "the previous note's typing is still on the undo stack")
        XCTAssertFalse(edit.nextBody === edit.typedBody, "each note gets its own text view")
    }

    /// Each save bumps `noteEpoch`, which restarts the editor's load. The
    /// outgoing note used to be saved again on every restart — hundreds of
    /// times, measured, before the next note appeared.
    func testLeavingAnEditedNoteSavesItOnce() async throws {
        let edit = try await typeThenSwitchNotes()
        XCTAssertLessThanOrEqual(edit.saves, 2, "the outgoing note was saved over and over")
        let saved = try await waitForNote(edit.first.id, in: edit.session) { $0.content.hasSuffix(" Typed here.") }
        XCTAssertEqual(saved.content, edit.first.content + " Typed here.")
    }

    /// Undo changes the body without telling its binding, so the draft kept
    /// the undone typing and leaving the note saved it. Nothing here moves
    /// the caret first: the body has to be found from the typing itself.
    func testUndoneTypingIsNotSaved() async throws {
        try await undoTypingThenLeave(content: "Seen on the ward.")
    }

    /// A blank note gives no caret notification to find the body by.
    func testUndoneTypingInABlankNoteIsNotSaved() async throws {
        try await undoTypingThenLeave(content: "")
    }

    /// Redo, like undo, never reaches the binding.
    func testRedoneTypingIsSaved() async throws {
        let typed = try await openAndType(content: "Seen on the ward.")
        typed.undoManager.undo()
        typed.undoManager.redo()
        XCTAssertEqual(typed.body.string, typed.typedText)

        let epochBefore = typed.session.noteEpoch
        typed.session.select(typed.other.id)
        _ = try await textView(in: typed.window, showing: typed.other.content)
        let saved = try await waitForNote(typed.note.id, in: typed.session) { $0.content.contains(" Typed here.") }
        XCTAssertEqual(saved.content, typed.typedText)
        XCTAssertGreaterThan(typed.session.noteEpoch, epochBefore)
    }

    /// The body's Markdown is drawn as attributes on its text view. That must
    /// never become an edit: the heading is styled, typing and undo keep the
    /// text exact and styled, and the undone note is not saved on leaving.
    func testStyledMarkdownStaysOutOfTheTextAndUndo() async throws {
        let content = "# Assessment\n\nPatient reports **improved** dyspnea."
        let typed = try await openAndType(content: content)
        let headingStyled = { Self.fontSize(typed.body, at: 3) > NSFont.preferredFont(forTextStyle: .body).pointSize }
        try await poll(headingStyled, "the heading was never styled")

        typed.undoManager.undo()
        XCTAssertEqual(typed.body.string, content)
        typed.undoManager.redo()
        XCTAssertEqual(typed.body.string, typed.typedText)
        typed.undoManager.undo()
        XCTAssertEqual(typed.body.string, content)
        try await poll(headingStyled, "undo lost the heading's style")
        XCTAssertFalse(typed.undoManager.canUndo, "styling left a step on the undo stack")

        let epochBefore = typed.session.noteEpoch
        typed.session.select(typed.other.id)
        _ = try await textView(in: typed.window, showing: typed.other.content)
        XCTAssertEqual(typed.session.noteEpoch, epochBefore, "styling made an unchanged note save")
    }

    /// On a wide pane the body still spans it, so a click or scroll in the
    /// margins reaches the text, while the text itself keeps to the
    /// readable column; on a narrow one the text starts at the edge.
    func testBodySpansThePaneWithTextInTheReadableColumn() async throws {
        let session = try await makeSession()
        let note = try await makeNote(in: session, title: "Wide", content: "Seen on the ward.")
        session.select(note.id)
        for (width, wide) in [(CGFloat(1400), true), (CGFloat(640), false)] {
            let window = host(NoteDetailView().environmentObject(session), width: width)
            let body = try await textView(in: window, showing: note.content)
            let scroll = try XCTUnwrap(body.enclosingScrollView)
            XCTAssertEqual(scroll.frame.width, width, accuracy: 2, "the body no longer spans the pane")
            let textStart = {
                let glyph = window.convertFromScreen(body.firstRect(
                    forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil))
                return scroll.convert(glyph.origin, from: nil).x
            }
            let column = (width - Chrome.readableWidth) / 2
            if wide {
                // The inset is set a turn after the body appears.
                try await poll({ textStart() > column }, "text is not in the column")
            } else {
                XCTAssertLessThan(textStart(), 40, "a narrow pane should not indent the text")
            }
            window.orderOut(nil)
        }
    }

    /// The whole path through the real editor: "[[" typed above existing
    /// text opens the popover at the caret, a click on the suggestion
    /// completes the link there and keeps the rest of the note, and ⌘Z
    /// brings the typed query back — in the draft too.
    func testCompletingAboveExistingTextThroughThePopover() async throws {
        try await completeThroughPopover(titleFocused: false)
    }

    /// A new note's title takes focus as it opens, and the user can click
    /// into it, so by the time the suggestion is clicked the body may not
    /// have focus. Measured: SwiftUI
    /// then put the old text back over the completion unless the draft had
    /// it first, leaving an undo step that garbled the note.
    func testCompletingThroughThePopoverWhileTheTitleHasFocus() async throws {
        try await completeThroughPopover(titleFocused: true)
    }

    /// A Greek tonos waits for its vowel as marked text, which is not in the
    /// draft; a redraw then — the caret having moved, or suggestions coming
    /// in — would put the draft's text back and the vowel would land at the
    /// end of the note.
    func testAccentTypedInsideALinkSurvivesTheSuggestions() async throws {
        let session = try await makeSession()
        _ = try await makeNote(in: session, title: "Cardiology follow-up", content: "Echo booked.")
        let plan = try await makeNote(in: session, title: "Plan", content: "Plan: \nDiscussed with the team.")
        _ = session.consumeFocusRequest(for: plan.id)
        session.select(plan.id)
        let window = host(NoteDetailView().environmentObject(session))
        let body = try await textView(in: window, showing: plan.content)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: ("Plan: " as NSString).length, length: 0))
        body.insertText("[[car", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        body.setMarkedText("΄", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 800_000_000)   // the lookup lands meanwhile

        XCTAssertTrue(body.hasMarkedText(), "the half-typed accent was wiped")
        XCTAssertEqual(body.string, "Plan: [[car΄\nDiscussed with the team.")
        XCTAssertEqual(body.selectedRange(), NSRange(location: ("Plan: [[car΄" as NSString).length, length: 0))
    }

    /// Until the body is edited or clicked its text view is not known, and
    /// the popover follows the note's end. Completing then replaces the text
    /// through the draft, which leaves nothing on the undo stack to replay.
    func testCompletingBeforeTheBodyWasTouched() async throws {
        let session = try await makeSession()
        let target = try await makeNote(in: session, title: "Cardiology follow-up", content: "Echo booked.")
        let plan = try await makeNote(in: session, title: "Plan", content: "Discussed.\nSee [[cardio")
        session.select(plan.id)
        let window = host(NoteDetailView().environmentObject(session))
        let body = try await textView(in: window, showing: plan.content)
        let undoManager = try XCTUnwrap(window.undoManager)
        try await Task.sleep(nanoseconds: 800_000_000)   // the lookup's debounce and search

        try await click(Self.popoverRow(above: body), in: window)
        let completed = "Discussed.\nSee [[Cardiology follow-up]]"
        XCTAssertEqual(body.string, completed, "the suggestion was not clicked")
        XCTAssertFalse(undoManager.canUndo)
        session.select(target.id)
        let saved = try await waitForNote(plan.id, in: session) { $0.content != plan.content }
        XCTAssertEqual(saved.content, completed)
    }

    // MARK: - Helpers

    private struct Typed {
        let session: AppSession
        let note: Note
        let other: Note
        let window: NSWindow
        let body: NSTextView
        let undoManager: UndoManager
        /// The body with the typing in it.
        let typedText: String
    }

    /// Opens a note and types " Typed here." into its body as one undo
    /// group, as a keystroke gets in the app (a test otherwise runs as a
    /// single event). The caret is not placed first: moving it would let the
    /// body be found by its selection, not by the typing.
    private func openAndType(content: String) async throws -> Typed {
        let session = try await makeSession()
        let note = try await makeNote(in: session, title: "Ward rounds", content: content)
        let other = try await makeNote(in: session, title: "Short", content: "Short.")
        session.select(note.id)
        let window = host(NoteDetailView().environmentObject(session))
        let body = try await textView(in: window, showing: content)
        let undoManager = try XCTUnwrap(window.undoManager)
        undoManager.groupsByEvent = false
        XCTAssertTrue(window.makeFirstResponder(body))
        undoManager.beginUndoGrouping()
        body.insertText(" Typed here.", replacementRange: NSRange(location: NSNotFound, length: 0))
        undoManager.endUndoGrouping()
        XCTAssertTrue(body.string.contains(" Typed here."))
        return Typed(session: session, note: note, other: other, window: window, body: body,
                     undoManager: undoManager, typedText: body.string)
    }

    private static func fontSize(_ body: NSTextView, at location: Int) -> CGFloat {
        guard let storage = body.textStorage, location < storage.length else { return 0 }
        return (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    /// Waits for main-queue work (the styling is deferred a turn) by
    /// suspending, which a nested run loop would not let run.
    private func poll(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    private func undoTypingThenLeave(content: String) async throws {
        let typed = try await openAndType(content: content)
        typed.undoManager.undo()
        XCTAssertEqual(typed.body.string, content)

        let epochBefore = typed.session.noteEpoch
        typed.session.select(typed.other.id)
        _ = try await textView(in: typed.window, showing: typed.other.content)
        XCTAssertEqual(typed.session.noteEpoch, epochBefore, "leaving an unchanged note saved it")
        let stored = try await waitForNote(typed.note.id, in: typed.session) { _ in true }
        XCTAssertEqual(stored.content, content)
    }

    private func completeThroughPopover(titleFocused: Bool) async throws {
        let session = try await makeSession()
        let target = try await makeNote(in: session, title: "Cardiology follow-up", content: "Echo booked.")
        let plan = try await makeNote(in: session, title: "Plan", content: "Plan: \nDiscussed with the team.")
        // A note just created asks for its title to take focus a turn after
        // it loads; this test moves focus itself, at a known moment.
        _ = session.consumeFocusRequest(for: plan.id)
        session.select(plan.id)
        let window = host(NoteDetailView().environmentObject(session))
        let body = try await textView(in: window, showing: plan.content)
        let undoManager = try XCTUnwrap(window.undoManager)
        undoManager.groupsByEvent = false
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: ("Plan: " as NSString).length, length: 0))
        undoManager.beginUndoGrouping()
        body.insertText("[[cardio", replacementRange: NSRange(location: NSNotFound, length: 0))
        undoManager.endUndoGrouping()
        try await Task.sleep(nanoseconds: 800_000_000)   // the lookup's debounce and search
        if titleFocused {
            let title = try XCTUnwrap(Self.textFields(in: window.contentView).first { $0.stringValue == plan.title })
            XCTAssertTrue(window.makeFirstResponder(title))
        }
        XCTAssertEqual(window.firstResponder !== body, titleFocused, "focus is not where this case needs it")

        undoManager.beginUndoGrouping()
        try await click(Self.popoverRow(above: body), in: window)
        undoManager.endUndoGrouping()
        let completed = "Plan: [[Cardiology follow-up]]\nDiscussed with the team."
        XCTAssertEqual(body.string, completed, "the suggestion was not clicked, or completed the wrong place")
        XCTAssertIdentical(window.firstResponder, body)

        undoManager.undo()
        XCTAssertEqual(body.string, "Plan: [[cardio\nDiscussed with the team.")
        // The draft follows the undo, so leaving the note saves the query.
        session.select(target.id)
        let saved = try await waitForNote(plan.id, in: session) { $0.content != plan.content }
        XCTAssertEqual(saved.content, "Plan: [[cardio\nDiscussed with the team.")
    }

    /// The popover's one suggestion, in window coordinates: the popover sits
    /// at the body's bottom-left (the editor's 12pt inset less its own 8pt
    /// vertical padding), and its bottom row is 8pt above its edge.
    private static func popoverRow(above body: NSTextView) throws -> NSPoint {
        let scroll = try XCTUnwrap(body.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to: nil)
        return NSPoint(x: frame.minX + 40, y: frame.minY + 4 + 8 + 7)
    }

    private func click(_ point: NSPoint, in window: NSWindow) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private struct Switched {
        let session: AppSession
        let first: Note
        let undoManager: UndoManager
        let typedBody: NSTextView
        let nextBody: NSTextView
        /// Epoch bumps between selecting the next note and seeing it.
        let saves: Int
    }

    /// Opens a long note, types into its body, then selects a short one.
    private func typeThenSwitchNotes() async throws -> Switched {
        let session = try await makeSession()
        let first = try await makeNote(in: session, title: "Ward rounds",
                                       content: "Long enough that its typing ranges run past the next note.")
        let second = try await makeNote(in: session, title: "Short", content: "Short.")

        session.select(first.id)
        let window = host(NoteDetailView().environmentObject(session))
        let body = try await textView(in: window, showing: first.content)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        body.insertText(" Typed here.", replacementRange: NSRange(location: NSNotFound, length: 0))
        let undoManager = try XCTUnwrap(window.undoManager)
        XCTAssertTrue(undoManager.canUndo, "typing registers with the window's undo manager")

        let epochBefore = session.noteEpoch
        session.select(second.id)
        let next = try await textView(in: window, showing: second.content)
        return Switched(session: session, first: first, undoManager: undoManager,
                        typedBody: body, nextBody: next, saves: session.noteEpoch - epochBefore)
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
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

    /// Borderless: AppKit moves a titled window at x -20000 onto a screen
    /// (measured, onto the built-in display at (160, 437)), so every run of
    /// these tests used to show its windows to whoever sat at the Mac.
    private func host<V: View>(_ view: V, width: CGFloat = 640) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 480))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        let window = NSWindow(
            contentRect: NSRect(x: -20000 - width, y: -20000, width: width, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                       "the test window must stay off every screen")
        return window
    }

    /// The body's text view once it shows `content`; the note loads async.
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

    /// The stored note once `condition` holds; the switch saves it async.
    private func waitForNote(_ id: UUID, in session: AppSession,
                             until condition: (Note) -> Bool) async throws -> Note {
        let store = try XCTUnwrap(session.store)
        let deadline = Date().addingTimeInterval(15)
        var last: Note?
        while Date() < deadline {
            last = try await store.notes.load(id: id)
            if let last, condition(last) { return last }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(last)
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let textView = view as? NSTextView { return [textView] }
        return view.subviews.flatMap { textViews(in: $0) }
    }
}
