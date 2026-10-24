import AppKit
import Combine
import SwiftUI

/// The note body's text view, as `NoteDetailView` needs it: which
/// `NSTextView` shows the draft, where its caret is, and the edits that have
/// to go through it rather than through the binding.
///
/// On macOS 14 a `TextEditor` exposes neither its text view nor its
/// selection, so the text view is found from its own notifications: in the
/// editor's window, the editable text view (not a field editor) that reports
/// while showing exactly the draft's body. That is when editing begins (the
/// first keystroke, before the text changes) or when the caret moves;
/// typing itself reports before the binding has the new text. The window
/// matters: Settings › Templates has a `TextEditor` too, and a note fresh
/// from a template can hold exactly its text.
@MainActor
final class NoteBodyEditor: ObservableObject {
    private weak var window: NSWindow?
    private weak var textView: NSTextView?
    private var noteID: UUID?
    /// The link at the caret when the view last heard; typing redraws
    /// through the binding anyway, so only a change here needs one.
    private var anchorAtCaret: String?
    private var refreshPending = false
    private var stylePending = false
    private var styleNote: Note?
    /// The text view last styled. Kept apart from `textView`: finding the
    /// body to style it must not count as the body being known, which
    /// decides how a link completion edits (through the view, or the draft).
    private weak var styledView: NSTextView?
    /// Left and right inset of the body's text, which holds it to the
    /// readable column while the text view spans the pane.
    private var horizontalInset: CGFloat = 0

    /// The window the editor is in; text views elsewhere are never taken.
    ///
    /// A `nil` is ignored. SwiftUI rebuilds the reader behind the editor,
    /// and the outgoing reader reports leaving its window *after* the new
    /// one reported arriving (logged live), which used to clear the window
    /// for good. The editor's own window going away releases it anyway.
    func attach(to window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        textView = nil
        noteID = nil
        anchorAtCaret = nil
    }

    /// Whether the body holds half-typed input: a Greek tonos waiting for
    /// its vowel, or an input method's composition. It is not in the draft
    /// yet, and any redraw now would put the draft's text back over it.
    var isComposing: Bool { textView?.hasMarkedText() ?? false }

    /// Follows a text view's editing, selection or text change. `object` is
    /// the notification's; anything but the body's text view is ignored.
    func track(_ object: Any?, showing note: Note?) {
        guard let candidate = object as? NSTextView, let note, let window,
              candidate.window === window, !candidate.isFieldEditor, candidate.isEditable,
              // Composing: nothing to do until it is committed, which reports.
              !candidate.hasMarkedText() else { return }
        var adopted = false
        if candidate !== textView || noteID != note.id {
            guard Self.shows(candidate, note) else { return }
            textView = candidate
            noteID = note.id
            adopted = true
        }
        // Read against the text view's own text: while typing it reports
        // before the binding has passed the new text on.
        let selection = candidate.selectedRange()
        let anchor = selection.length == 0
            ? LinkingService.openAnchor(in: candidate.string, caretUTF16: selection.location) : nil
        let anchorMoved = anchor != anchorAtCaret
        anchorAtCaret = anchor
        // A text view ahead of the draft is being typed into (or undone),
        // and the draft's update redraws anyway, reading the caret then.
        let caughtUp = candidate.textStorage?.length == (note.content as NSString).length
        if adopted || (anchorMoved && caughtUp) { refreshSoon() }
        if adopted { restyleSoon(note) }
    }

    /// The link being typed at the body's caret.
    ///
    /// The caret is read live, so it always belongs to the text it is
    /// compared with. Until the body's text view is known and shows `note`,
    /// this is the whole-text rule, which only looks at the note's end.
    func openAnchor(in note: Note) -> String? {
        guard let textView = bodyTextView(showing: note) else {
            return LinkingService.openAnchor(in: note.content)
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        return LinkingService.openAnchor(in: note.content, caretUTF16: selection.location)
    }

    /// Completes the link at the caret as an edit of the text view itself.
    ///
    /// That makes it one step on the text view's undo stack, so ⌘Z brings
    /// the typed query back. Not `insertText`: its smart quotes and dashes
    /// could change the title so the link no longer resolves.
    ///
    /// `updateDraft` receives the completed text before the text view does.
    /// SwiftUI puts the binding's text back into a text view that changes
    /// outside its own editing (measured: with focus gone to the title since
    /// the "[[" was typed, the completion was undone as soon as it landed,
    /// leaving an undo step that garbled the note). With the draft already
    /// holding it, there is nothing to put back.
    ///
    /// - Returns: false when the body's text view is not known or does not
    ///   show `note`; the caller then falls back to the whole-text rule.
    func complete(with choice: String, in note: Note, updateDraft: (String) -> Void) -> Bool {
        // Mid-composition the text view is ahead of the draft; the click is
        // ignored rather than completing somewhere the popover never meant.
        if let textView, noteID == note.id, textView.window != nil, textView.hasMarkedText() { return true }
        guard let textView = bodyTextView(showing: note) else { return false }
        let text = textView.string
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let edit = LinkingService.completion(in: text, caretUTF16: selection.location, choice: choice)
        else { return true }
        // Its own undo step, apart from the typing before and after it. An
        // edit made in code already is one (measured on macOS 26 and 27);
        // the breaks keep it so.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
        updateDraft((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        let caret = NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        // Typing carries on in the body after the link.
        textView.window?.makeFirstResponder(textView)
        return true
    }

    /// The body's text after an undo or redo, when `note` no longer has it.
    ///
    /// Undo and redo change the text view without `didChangeText`, so the
    /// binding never hears about them: measured, the draft kept the undone
    /// text, and leaving the note saved it.
    func textAfterUndo(_ notification: Notification, of note: Note?) -> String? {
        guard let textView, let note, noteID == note.id,
              let undoManager = notification.object as? UndoManager,
              undoManager === textView.undoManager else { return nil }
        return Self.shows(textView, note) ? nil : textView.string
    }

    // MARK: - Markdown styling

    /// Draws the body's Markdown (headings, bold, italic, dimmed markers and
    /// front matter) once the current event is handled.
    ///
    /// Only attributes change, never the string. Measured on macOS 26
    /// (TextKit 2) with a harness: an attribute-only edit of the text storage
    /// posts no text change, never reaches the binding, registers no undo,
    /// and typing, undo and redo around it keep their text. It is skipped
    /// while text is marked, so a composition is never touched. Coalesced:
    /// a burst of changes styles once, with the latest note.
    func restyleSoon(_ note: Note?) {
        guard let note else { return }
        styleNote = note
        guard !stylePending else { return }
        stylePending = true
        DispatchQueue.main.async { [weak self] in self?.restylePending(attempt: 0) }
    }

    /// A note just selected has no text view in the window yet when its
    /// draft arrives (measured: the first try found none), so a miss retries
    /// for a moment rather than leaving the note plain until it is typed in.
    private func restylePending(attempt: Int) {
        guard let note = styleNote else {
            stylePending = false
            return
        }
        if restyle(note) || attempt >= 20 {
            stylePending = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.restylePending(attempt: attempt + 1)
        }
    }

    /// Whether the body's text view was found and styled.
    @discardableResult
    private func restyle(_ note: Note) -> Bool {
        let view: NSTextView?
        if let known = textView, noteID == note.id, known.window != nil {
            // Typing may have moved it ahead of `note`; it is still the body,
            // and the styling reads its own text.
            view = known
        } else if let styledView, styledView.window === window, Self.shows(styledView, note) {
            view = styledView
        } else {
            // A note just opened: nothing has reported yet, so look for the
            // text view in this window showing exactly its body.
            view = window?.contentView.flatMap { Self.findBody(showing: note, in: $0) }
        }
        guard let view, let storage = view.textStorage else { return false }
        applyInset(to: view)
        // Mid-composition: done for now; committing it is a change, which
        // asks again.
        guard !view.hasMarkedText() else { return true }
        // Each change restyles the whole body, which a clinical note never
        // notices; past this size (an imported dump) it stays plain instead.
        guard storage.length <= Self.styledLengthLimit else { return true }
        styledView = view
        Self.apply(MarkdownStyler.spans(in: view.string), to: storage)
        return true
    }

    private static let styledLengthLimit = 60_000

    /// Sets the body's horizontal text inset, now on the text view showing
    /// `note` and on every one found after (a new note, leaving Preview).
    func setHorizontalInset(_ inset: CGFloat, for note: Note?) {
        horizontalInset = inset
        restyleSoon(note)
    }

    /// Layout only: changing the inset touches neither the text nor undo.
    private func applyInset(to view: NSTextView) {
        guard abs(view.textContainerInset.width - horizontalInset) > 0.5 else { return }
        view.textContainerInset = NSSize(width: horizontalInset, height: view.textContainerInset.height)
    }

    private static func findBody(showing note: Note, in view: NSView) -> NSTextView? {
        if let candidate = view as? NSTextView, candidate.isEditable, !candidate.isFieldEditor,
           shows(candidate, note) {
            return candidate
        }
        for subview in view.subviews {
            if let found = findBody(showing: note, in: subview) { return found }
        }
        return nil
    }

    private static func apply(_ spans: [MarkdownStyler.Span], to storage: NSTextStorage) {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let size = base.pointSize
        let manager = NSFontManager.shared
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // The editor's own defaults (measured): body font, text colour.
        storage.addAttributes([.font: base, .foregroundColor: NSColor.textColor], range: full)
        for span in spans {
            switch span.role {
            case .heading(let level):
                let scale: CGFloat = [1.5, 1.3, 1.15][min(level, 3) - 1]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: (size * scale).rounded(), weight: .bold),
                                     range: span.range)
            case .bold:
                storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                    let font = value as? NSFont ?? base
                    storage.addAttribute(.font, value: manager.convert(font, toHaveTrait: .boldFontMask), range: range)
                }
            case .italic:
                storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                    let font = value as? NSFont ?? base
                    storage.addAttribute(.font, value: manager.convert(font, toHaveTrait: .italicFontMask), range: range)
                }
            case .syntaxMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            case .frontMatter:
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ], range: span.range)
            case .wikiLink:
                storage.addAttribute(.foregroundColor, value: NSColor(named: "AccentColor") ?? .controlAccentColor,
                                     range: span.range)
            }
        }
        storage.endEditing()
    }

    private func bodyTextView(showing note: Note) -> NSTextView? {
        guard let textView, noteID == note.id, textView.window != nil, Self.shows(textView, note) else { return nil }
        return textView
    }

    /// Exact UTF-16 equality, which the edits' ranges rely on; also much
    /// cheaper than comparing Swift strings, and it runs on every redraw.
    private static func shows(_ textView: NSTextView, _ note: Note) -> Bool {
        (textView.string as NSString).isEqual(to: note.content)
    }

    /// Redraws once the current event is handled. A text view reports
    /// changes from inside SwiftUI's own updates too (it posts when the
    /// binding pushes new text in), where publishing is not allowed.
    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshPending = false
            objectWillChange.send()
        }
    }
}

/// Reports the window the view it backs is in.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
