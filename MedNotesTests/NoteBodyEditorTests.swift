import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MedNotes

/// `NoteBodyEditor` against real SwiftUI text views hosted off screen: which
/// text view it takes for the note body, the caret-aware [[ link, the
/// completion as one undoable edit of the text view, and undo reaching the
/// draft, which the `TextEditor` binding alone never does.
@MainActor
final class NoteBodyEditorTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    // MARK: - Which text view is the body

    func testTakesTheBodyOnlyFromItsOwnWindow() throws {
        var note = Note(title: "Plan", content: "Plan: [[car\nrest of the note")
        let (window, body, _) = try host(note)
        let (_, lookalike, _) = try host(note)   // Settings › Templates, say
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        body.setSelectedRange(NSRange(location: 11, length: 0))       // after "car"
        lookalike.setSelectedRange(NSRange(location: 11, length: 0))

        // The same text in another window is not the body: the whole-text
        // rule still applies, and it finds no link at the note's end.
        editor.track(lookalike, showing: note)
        XCTAssertNil(editor.openAnchor(in: note))
        XCTAssertFalse(editor.complete(with: "Cardiology follow-up", in: note, updateDraft: { _ in XCTFail("edited") }))

        // Nor is a text view showing other text.
        note.content += "!"
        editor.track(body, showing: note)
        XCTAssertNil(editor.openAnchor(in: note))
        note.content.removeLast()

        editor.track(body, showing: note)
        XCTAssertEqual(editor.openAnchor(in: note), "car")
    }

    func testFieldEditorsAreNeverTheBody() throws {
        let note = Note(title: "See [[car", content: "See [[car")
        let box = NoteBox(note)
        let window = host(VStack {
            TextField("Title", text: Binding(get: { box.note.title }, set: { box.note.title = $0 }))
            TextEditor(text: Binding(get: { box.note.content }, set: { box.note.content = $0 }))
        })
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        let field = try XCTUnwrap(Self.first(NSTextField.self, in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.setSelectedRange(NSRange(location: 0, length: 0))

        editor.track(fieldEditor, showing: note)
        // Not taken: with its caret at 0 the title's field editor would have
        // said no link; the whole-text rule finds "car" at the end.
        XCTAssertEqual(editor.openAnchor(in: note), "car")
    }

    func testAnotherNoteNeedsItsOwnTextView() throws {
        let first = Note(title: "A", content: "Plan: [[car\nrest")
        let (window, body, _) = try host(first)
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        body.setSelectedRange(NSRange(location: 11, length: 0))
        editor.track(body, showing: first)
        XCTAssertEqual(editor.openAnchor(in: first), "car")

        // Same text, other note: until a text view is seen showing it, the
        // old one is not used for it.
        let second = Note(title: "B", content: first.content)
        XCTAssertNil(editor.openAnchor(in: second))
        XCTAssertFalse(editor.complete(with: "Cardiology follow-up", in: second, updateDraft: { _ in XCTFail("edited") }))
        XCTAssertEqual(body.string, first.content)
    }

    // MARK: - The caret

    func testOpenAnchorFollowsTheCaret() throws {
        let note = Note(title: "Plan", content: "Plan: [[car\nFollow up with [[cardio in two weeks.")
        let (window, body, _) = try host(note)
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        editor.track(body, showing: note)

        body.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertEqual(editor.openAnchor(in: note), "car")
        body.setSelectedRange(NSRange(location: ("Plan: [[car\nFollow up with [[cardio" as NSString).length, length: 0))
        XCTAssertEqual(editor.openAnchor(in: note), "cardio")
        body.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(editor.openAnchor(in: note))
        // A selection is not a caret.
        body.setSelectedRange(NSRange(location: 8, length: 3))
        XCTAssertNil(editor.openAnchor(in: note))
    }

    /// The popover follows the caret only by redrawing. The redraw comes a
    /// turn later — a text view also reports from inside SwiftUI's own
    /// updates — once however often it was asked for, and only when the
    /// link at the caret changes.
    func testRedrawsWhenTheCaretMovesIntoOrOutOfALinkOnly() async throws {
        let (window, body, box) = try host(Note(title: "Plan", content: "Plan: [[car\nrest of the note"))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        var redraws = 0
        let subscription = editor.objectWillChange.sink { redraws += 1 }
        defer { subscription.cancel() }

        body.setSelectedRange(NSRange(location: 3, length: 0))
        editor.track(body, showing: box.note)           // taken as the body
        XCTAssertEqual(redraws, 0, "published during the notification")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(redraws, 1)

        body.setSelectedRange(NSRange(location: 11, length: 0))   // into "[[car"
        editor.track(body, showing: box.note)
        editor.track(body, showing: box.note)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(redraws, 2)

        body.setSelectedRange(NSRange(location: 16, length: 0))   // out, a line down
        editor.track(body, showing: box.note)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(redraws, 3)

        body.setSelectedRange(NSRange(location: 17, length: 0))   // still out
        editor.track(body, showing: box.note)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(redraws, 3)
    }

    /// Preview removes the editor, but its text view can outlive that.
    func testATextViewThatLeftTheWindowIsNotTheBody() throws {
        let box = NoteBox(Note(title: "Plan", content: "Plan: [[car\nrest"))
        let shown = Shown()
        let window = host(Previewable(shown: shown, box: box))
        let body = try XCTUnwrap(Self.first(NSTextView.self, in: window.contentView))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        body.setSelectedRange(NSRange(location: 11, length: 0))
        editor.track(body, showing: box.note)
        XCTAssertEqual(editor.openAnchor(in: box.note), "car")

        shown.editor = false
        settle(window)
        XCTAssertNil(body.window)
        XCTAssertNil(editor.openAnchor(in: box.note), "the whole-text rule: no link at the end")
        XCTAssertFalse(editor.complete(with: "Cardiology follow-up", in: box.note, updateDraft: { _ in XCTFail("edited") }))
        XCTAssertEqual(box.note.content, "Plan: [[car\nrest")
    }

    /// Half-typed input is not in the draft yet: nothing is tracked, and a
    /// click on a suggestion is ignored rather than completing elsewhere.
    func testNothingHappensWhileComposing() throws {
        let (window, body, box) = try host(Note(title: "Plan", content: "Plan: [[car\nrest"))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: 11, length: 0))
        editor.track(body, showing: box.note)
        XCTAssertFalse(editor.isComposing)

        body.setMarkedText("΄", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.isComposing)
        editor.track(body, showing: box.note)
        XCTAssertTrue(editor.complete(with: "Cardiology follow-up", in: box.note, updateDraft: { _ in XCTFail("edited") }))
        XCTAssertTrue(body.hasMarkedText(), "the composition was committed or wiped")
        XCTAssertEqual(body.string, "Plan: [[car΄\nrest")
    }

    // MARK: - Completing

    func testCompletionIsOneUndoableEditThatKeepsTheRestOfTheNote() throws {
        let (window, body, box) = try host(Note(title: "Plan", content: "Plan: [[car\nrest of the note"))
        let undoManager = try perEventUndo(in: window)
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: 11, length: 0))
        asOneEvent(undoManager) {
            body.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        settle(window)
        XCTAssertEqual(box.note.content, "Plan: [[card\nrest of the note")
        editor.track(body, showing: box.note)

        var drafted: String?
        asOneEvent(undoManager) {
            XCTAssertTrue(editor.complete(with: "Cardiology follow-up", in: box.note, updateDraft: {
                drafted = $0
                box.note.content = $0
            }))
        }
        settle(window)
        let completed = "Plan: [[Cardiology follow-up]]\nrest of the note"
        XCTAssertEqual(drafted, completed)
        XCTAssertEqual(body.string, completed)
        XCTAssertEqual(box.note.content, completed)
        XCTAssertEqual(body.selectedRange(), NSRange(location: ("Plan: [[Cardiology follow-up]]" as NSString).length, length: 0))
        XCTAssertIdentical(window.firstResponder, body)

        // ⌘Z undoes the completion alone, back to what was typed ("card",
        // not "car"), and the draft follows once told.
        undoManager.undo()
        XCTAssertEqual(body.string, "Plan: [[card\nrest of the note")
        let undone = editor.textAfterUndo(Notification(name: .NSUndoManagerDidUndoChange, object: undoManager), of: box.note)
        XCTAssertEqual(undone, "Plan: [[card\nrest of the note")
        box.note.content = try XCTUnwrap(undone)

        undoManager.redo()
        XCTAssertEqual(
            editor.textAfterUndo(Notification(name: .NSUndoManagerDidRedoChange, object: undoManager), of: box.note),
            completed)
    }

    /// Picking a suggestion right after typing "[[" is a plain insertion at
    /// the caret, which the text view would otherwise fold into the typing
    /// before it; typing straight after it must not fold into it either.
    func testCompletionRightAfterTheBracketsIsItsOwnUndoStep() throws {
        let (window, body, box) = try host(Note(title: "See", content: "See"))
        let undoManager = try perEventUndo(in: window)
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: 3, length: 0))
        asOneEvent(undoManager) { body.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        asOneEvent(undoManager) { body.insertText("[[", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        settle(window)
        editor.track(body, showing: box.note)
        asOneEvent(undoManager) { _ = editor.complete(with: "Ward Rounds", in: box.note, updateDraft: { box.note.content = $0 }) }
        asOneEvent(undoManager) { body.insertText(" today", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(body.string, "See [[Ward Rounds]] today")

        undoManager.undo()
        XCTAssertEqual(body.string, "See [[Ward Rounds]]", "the typing after it was undone with the completion")
        undoManager.undo()
        XCTAssertEqual(body.string, "See [[", "the completion was undone with the typing before it")
    }

    /// Focus can be in the title by the time a suggestion is clicked. The
    /// completion must still stick, and the body takes focus back.
    func testCompletionWhileTheTitleHasFocus() throws {
        let box = NoteBox(Note(title: "Plan", content: "Plan: [[car\nrest of the note"))
        let window = host(VStack {
            TextField("Title", text: Binding(get: { box.note.title }, set: { box.note.title = $0 }))
            TextEditor(text: Binding(get: { box.note.content }, set: { box.note.content = $0 }))
        })
        let body = try XCTUnwrap(Self.first(NSTextView.self, in: window.contentView))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        body.setSelectedRange(NSRange(location: 11, length: 0))
        editor.track(body, showing: box.note)
        XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(Self.first(NSTextField.self, in: window.contentView))))

        XCTAssertTrue(editor.complete(with: "Cardiology follow-up", in: box.note, updateDraft: { box.note.content = $0 }))
        settle(window)
        let completed = "Plan: [[Cardiology follow-up]]\nrest of the note"
        XCTAssertEqual(body.string, completed, "the old text was put back over the completion")
        XCTAssertEqual(box.note.content, completed)
        XCTAssertIdentical(window.firstResponder, body)
    }

    func testCompletionInsideAnExistingLinkReplacesTheLink() throws {
        let (window, body, box) = try host(Note(title: "See", content: "See [[Ward Rounds]] today"))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        editor.track(body, showing: box.note)
        body.setSelectedRange(NSRange(location: ("See [[Ward Ro" as NSString).length, length: 0))

        XCTAssertEqual(editor.openAnchor(in: box.note), "Ward Ro")
        XCTAssertTrue(editor.complete(with: "Wound Care", in: box.note, updateDraft: { box.note.content = $0 }))
        settle(window)
        XCTAssertEqual(box.note.content, "See [[Wound Care]] today")
    }

    func testWithoutTheTextViewTheCallerFallsBack() throws {
        let note = Note(title: "See", content: "Discussed.\nSee [[car")
        let editor = NoteBodyEditor()
        // Never seen a text view: the whole-text rule, and no edit made.
        XCTAssertEqual(editor.openAnchor(in: note), "car")
        XCTAssertFalse(editor.complete(with: "Cardiology follow-up", in: note, updateDraft: { _ in XCTFail("edited") }))
    }

    func testNoLinkAtTheCaretMeansNoEditAndNoFallback() throws {
        let (window, body, box) = try host(Note(title: "See", content: "No link here.\nSee [[car"))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        editor.track(body, showing: box.note)
        body.setSelectedRange(NSRange(location: 2, length: 0))

        // Handled, so the caller does not complete the note's end behind the
        // user's back; nothing changes.
        XCTAssertTrue(editor.complete(with: "Cardiology follow-up", in: box.note, updateDraft: { _ in XCTFail("edited") }))
        XCTAssertEqual(body.string, "No link here.\nSee [[car")
    }

    // MARK: - Undo

    func testUndoOfTypingReachesTheDraftThroughTheEditor() throws {
        let (window, body, box) = try host(Note(title: "Ward", content: "Ward round."))
        let undoManager = try perEventUndo(in: window)
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(body))
        editor.track(body, showing: box.note)
        body.setSelectedRange(NSRange(location: 11, length: 0))
        asOneEvent(undoManager) {
            body.insertText(" Typed.", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        settle(window)
        XCTAssertEqual(box.note.content, "Ward round. Typed.")

        // Measured on macOS 26: undo posts no text change, so the binding
        // alone would keep " Typed." in the draft and it would be saved.
        undoManager.undo()
        settle(window)
        XCTAssertEqual(body.string, "Ward round.")
        XCTAssertEqual(
            editor.textAfterUndo(Notification(name: .NSUndoManagerDidUndoChange, object: undoManager), of: box.note),
            "Ward round.")

        // Another window's undo, or another note, is none of its business.
        XCTAssertNil(editor.textAfterUndo(Notification(name: .NSUndoManagerDidUndoChange, object: UndoManager()), of: box.note))
        var other = box.note
        other.id = UUID()
        XCTAssertNil(editor.textAfterUndo(Notification(name: .NSUndoManagerDidUndoChange, object: undoManager), of: other))
    }

    // MARK: - Styling

    func testANoteGrownPastTheLimitDropsItsOldStylingAndTypesPlainly() throws {
        let content = "# Assessment\n\nPatient reports **improved** dyspnea."
        let (window, body, box) = try host(Note(title: "Long", content: content))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        editor.track(body, showing: box.note)
        settle(window)
        let base = NSFont.preferredFont(forTextStyle: .body).pointSize
        let styled = { (location: Int) -> CGFloat in
            (body.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        XCTAssertGreaterThan(styled(3), base, "precondition: the heading is styled")

        // Grow the existing storage, as typing past the limit does: the old
        // heading keeps its attributes unless the restyle clears them.
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        body.insertText(String(repeating: "x", count: 60_001),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        box.note.content = body.string
        editor.restyleSoon(box.note)
        settle(window)

        XCTAssertEqual(styled(3), base, "the old heading stayed styled past the limit")
        body.setSelectedRange(NSRange(location: 0, length: 0))
        body.insertText("New ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(styled(1), base, "text typed past the limit inherited the old heading style")
    }

    // MARK: - Properties and jumping

    private let withProperties = "---\nstatus: draft\nowner: Dr. Ana\n---\nBody text here"

    func testAPropertyEditIsOneUndoStepAndKeepsTheCaret() throws {
        let (window, body, box) = try host(Note(title: "P", content: withProperties))
        let undoManager = try perEventUndo(in: window)
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.setSelectedRange(NSRange(location: (withProperties as NSString).length - 4, length: 0))   // in "here"
        editor.track(body, showing: box.note)

        var drafted: String?
        var outcome = NoteBodyEditor.PropertyEditOutcome.refused
        asOneEvent(undoManager) {
            outcome = editor.editProperty(
                .set(key: "status", value: .text("final review")), expecting: "status: draft\n", in: box.note,
                updateDraft: { drafted = $0; box.note.content = $0 })
        }
        settle(window)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(body.string, "---\nstatus: final review\nowner: Dr. Ana\n---\nBody text here")
        XCTAssertEqual(drafted, body.string)
        let shift = ("status: final review\n" as NSString).length - ("status: draft\n" as NSString).length
        XCTAssertEqual(body.selectedRange().location, (withProperties as NSString).length - 4 + shift,
                       "a caret after the edit moves with the text")

        undoManager.undo()
        XCTAssertEqual(body.string, withProperties, "one undo step undoes the whole edit")
        XCTAssertEqual(
            editor.textAfterUndo(Notification(name: .NSUndoManagerDidUndoChange, object: undoManager), of: box.note),
            withProperties)
    }

    func testAPropertyEditUsesTheTextAsTypedNotTheStaleDraft() throws {
        let (window, body, box) = try host(Note(title: "P", content: withProperties))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(body))
        editor.track(body, showing: box.note)
        // Typing the body is ahead of the draft the panel was built from.
        body.setSelectedRange(NSRange(location: (withProperties as NSString).length, length: 0))
        body.insertText(" and more", replacementRange: NSRange(location: NSNotFound, length: 0))

        var drafted: String?
        let outcome = editor.editProperty(
            .set(key: "owner", value: .text("Dr. Eleni")), expecting: nil, in: box.note,
            updateDraft: { drafted = $0 })
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(body.string, "---\nstatus: draft\nowner: Dr. Eleni\n---\nBody text here and more")
        XCTAssertEqual(drafted, body.string, "what was typed is not lost")
    }

    func testAPropertyEditIsRefusedWhenItsLinesChanged() throws {
        let (window, body, box) = try host(Note(title: "P", content: withProperties))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        editor.track(body, showing: box.note)
        let outcome = editor.editProperty(
            .set(key: "status", value: .text("x")), expecting: "status: something else\n", in: box.note,
            updateDraft: { _ in XCTFail("the draft must not change") })
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(body.string, withProperties)
    }

    func testAPropertyEditFindsTheBodyOfAFreshNoteAndLeavesUndoAlone() throws {
        let (window, body, box) = try host(Note(title: "P", content: withProperties))
        let undoManager = try perEventUndo(in: window)
        let editor = NoteBodyEditor()
        editor.attach(to: window)   // never tracked: the user has not touched the body
        var outcome = NoteBodyEditor.PropertyEditOutcome.refused
        asOneEvent(undoManager) {
            outcome = editor.editProperty(
                .set(key: "status", value: .text("final")), expecting: nil, in: box.note,
                updateDraft: { box.note.content = $0 })
        }
        XCTAssertEqual(outcome, .applied)
        XCTAssertTrue(undoManager.canUndo, "it went through the text view, so it can be undone")
        XCTAssertTrue(body.string.contains("status: final"))
    }

    func testAPropertyEditDoesNotStealFocusOrScroll() throws {
        let box = NoteBox(Note(title: "P", content: withProperties))
        let window = host(VStack {
            TextField("Value", text: .constant(""))
            TextEditor(text: Binding(get: { box.note.content }, set: { box.note.content = $0 }))
        })
        let body = try XCTUnwrap(Self.first(NSTextView.self, in: window.contentView))
        let field = try XCTUnwrap(Self.first(NSTextField.self, in: window.contentView))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(window.makeFirstResponder(field))
        let responder = window.firstResponder
        let outcome = editor.editProperty(
            .set(key: "status", value: .text("final")), expecting: nil, in: box.note,
            updateDraft: { box.note.content = $0 })
        XCTAssertEqual(outcome, .applied)
        XCTAssertTrue(window.firstResponder === responder, "the field the edit came from keeps focus")
        XCTAssertTrue(body.string.contains("status: final"))
    }

    func testAPropertyEditWithoutATextViewIsLeftToTheCaller() {
        let editor = NoteBodyEditor()
        let note = Note(title: "P", content: withProperties)
        let outcome = editor.editProperty(
            .set(key: "status", value: .text("x")), expecting: nil, in: note,
            updateDraft: { _ in XCTFail("nothing to edit through") })
        XCTAssertEqual(outcome, .noTextView)
    }

    func testRevealPutsTheCaretAtAnOffsetAndClampsAStaleOne() throws {
        let (window, body, box) = try host(Note(title: "P", content: "# One\nbody\n## Two\nmore"))
        let editor = NoteBodyEditor()
        editor.attach(to: window)
        XCTAssertTrue(editor.reveal(utf16Offset: 11, in: box.note))
        XCTAssertEqual(body.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertIdentical(window.firstResponder, body)
        XCTAssertTrue(editor.reveal(utf16Offset: 10_000, in: box.note))
        XCTAssertEqual(body.selectedRange().location, (body.string as NSString).length)
        XCTAssertTrue(editor.reveal(utf16Offset: -5, in: box.note))
        XCTAssertEqual(body.selectedRange().location, 0)
        XCTAssertFalse(NoteBodyEditor().reveal(utf16Offset: 3, in: box.note), "no text view, no jump")
    }

    // MARK: - Helpers

    private final class NoteBox {
        var note: Note
        init(_ note: Note) { self.note = note }
    }

    private final class Shown: ObservableObject {
        @Published var editor = true
    }

    /// An editor that Preview replaces, as in `NoteDetailView`.
    private struct Previewable: View {
        @ObservedObject var shown: Shown
        let box: NoteBox
        var body: some View {
            if shown.editor {
                TextEditor(text: Binding(get: { box.note.content }, set: { box.note.content = $0 }))
            } else {
                Text(box.note.content)
            }
        }
    }

    /// A window with a `TextEditor` bound to `note`'s body, and its text view.
    private func host(_ note: Note) throws -> (NSWindow, NSTextView, NoteBox) {
        let box = NoteBox(note)
        let window = host(TextEditor(text: Binding(get: { box.note.content }, set: { box.note.content = $0 })))
        let textView = try XCTUnwrap(Self.first(NSTextView.self, in: window.contentView))
        return (window, textView, box)
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: 480, height: 240))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 240),
            // Borderless: AppKit moves a titled window at x -20000 onto a screen.
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        windows.append(window)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) },
                       "the test window must stay off every screen")
        settle(window)
        return window
    }

    /// A test runs inside one run-loop event, which by default would make
    /// all its edits one undo group. The app gets a group per keystroke or
    /// click; `asOneEvent` stands in for that.
    private func perEventUndo(in window: NSWindow) throws -> UndoManager {
        let undoManager = try XCTUnwrap(window.undoManager)
        undoManager.groupsByEvent = false
        return undoManager
    }

    private func asOneEvent(_ undoManager: UndoManager, _ edit: () -> Void) {
        undoManager.beginUndoGrouping()
        edit()
        undoManager.endUndoGrouping()
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }
}
