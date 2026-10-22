import AppKit
import SwiftUI

/// Where ⌘⌫ goes while the Delete command owns it.
///
/// Edit › Delete asks about the main window's selected record, so only the
/// main window enables it: `ContentView` publishes a `DeleteCommand` with
/// `.focusedSceneValue`, and the command reads it with `@FocusedValue`. In
/// Settings or Activity the value is nil and the item disabled, and a
/// disabled item does not claim its key equivalent, so ⌘⌫ there stays with
/// the focused list or text field. The value is also nil while a sheet, an
/// alert, the quick switcher, the privacy curtain or the confirmation itself
/// covers the main window (`AppSession.canRequestDelete`).
///
/// Inside the main window a menu key equivalent is still matched before the
/// focused view sees the key, so ⌘⌫ in a note body, a title or a search
/// field would otherwise ask to delete the selected record instead of
/// deleting to the start of the line. A click on the menu item, and ⌘⌫
/// anywhere outside editable text (a list row, say), still deletes the record.
@MainActor
enum DeleteShortcut {
    /// Runs the Delete command for `event` in `window` — the application's
    /// current event and key window.
    static func perform(for event: NSEvent?, in window: NSWindow?, deleteRecord: () -> Void) {
        if let textView = textView(for: event, firstResponder: window?.firstResponder) {
            textView.deleteToBeginningOfLine(nil)
        } else {
            deleteRecord()
        }
    }

    /// The text view that should take `event` instead of the Delete command:
    /// `firstResponder` when the event is the ⌘⌫ key press and the responder
    /// is an editable `NSTextView` — a `TextEditor`, or the field editor
    /// behind any `TextField`.
    static func textView(for event: NSEvent?, firstResponder: NSResponder?) -> NSTextView? {
        guard let event, event.type == .keyDown,
              event.modifierFlags.contains(.command),
              // The delete key types U+007F. SwiftUI's `KeyEquivalent.delete`
              // is U+0008, which AppKit matches to that same key.
              let key = event.charactersIgnoringModifiers, key == "\u{7F}" || key == "\u{8}",
              let textView = firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return textView
    }
}

/// Edit › Delete as the main window publishes it. See `DeleteShortcut`.
struct DeleteCommand {
    let deleteRecord: @MainActor () -> Void

    /// Runs the command for the application's current event and key window.
    @MainActor func callAsFunction() {
        perform(for: NSApp.currentEvent, in: NSApp.keyWindow)
    }

    /// Runs the command for `event` in `window`; see `DeleteShortcut.perform`.
    @MainActor func perform(for event: NSEvent?, in window: NSWindow?) {
        DeleteShortcut.perform(for: event, in: window) { deleteRecord() }
    }
}

private struct DeleteCommandKey: FocusedValueKey {
    typealias Value = DeleteCommand
}

extension FocusedValues {
    /// Set by the main window while it can ask about its selected record.
    var deleteCommand: DeleteCommand? {
        get { self[DeleteCommandKey.self] }
        set { self[DeleteCommandKey.self] = newValue }
    }
}
