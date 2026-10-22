import AppKit

/// Keeps keyboard focus out of the covered windows while the privacy curtain
/// hides records (locked, or the app in the background), and gives it back
/// when the curtain lifts.
///
/// `.accessibilityHidden` takes the covered views out of the accessibility
/// tree, but not out of focus: the first responder under the curtain stays the
/// app's focused element even with the app in the background, readable by any
/// app with Accessibility access (a note's text, a search query, a list and
/// its rows), and its parents lead back into the hidden tree. Measured with a
/// raw AXUIElement reader; System Events reports no focused element there.
///
/// Parking once is not enough. Measured in the running app, a window that
/// finishes loading under the curtain gives its search field focus, and
/// SwiftUI hands a field its focus back on its next update after a lock. So
/// while parked, a covered window whose first responder moves back into its
/// content is parked again on the next turn of the main queue.
///
/// Only the windows that report themselves through `cover(_:)` are touched,
/// never an open or save panel, and never the root hosting view itself: its
/// own focus is SwiftUI's, which on the lock screen is the Unlock button.
@MainActor
final class FocusParking {
    private struct Parked {
        weak var window: NSWindow?
        weak var responder: NSView?
        /// A text field's own selection: it selects all of its text when it
        /// takes focus again, and typing would then replace it.
        var selection: NSRange?
        /// What was being typed into a field. Ending the edit commits it, and
        /// a number field then shows "72," as "72": a "5" typed on return
        /// would make it 725.
        var editingText: String?
    }

    private struct Covered {
        weak var window: NSWindow?
        let observation: NSKeyValueObservation
    }

    private var covered: [ObjectIdentifier: Covered] = [:]
    private var parked: [Parked] = []
    private var isParked = false
    private var dropsEdits = false
    private var isReparkScheduled = false

    /// A window that shows the curtain or a cover; one opened under the
    /// curtain is parked as soon as it reports in.
    func cover(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard covered[id]?.window !== window else { return }
        // Fires inside whatever moved focus, SwiftUI's update included; the
        // parking itself waits for the next turn.
        let observation = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleRepark() }
        }
        covered[id] = Covered(window: window, observation: observation)
        scheduleRepark()
    }

    func park() {
        guard !isParked else { return }
        isParked = true
        parkCoveredWindows()
    }

    /// A lock clears what it covers, search fields included: text typed
    /// before it must not come back with the focus.
    func dropEdits() {
        dropsEdits = true
        for index in parked.indices {
            parked[index].editingText = nil
        }
    }

    /// Only where nothing has taken focus meanwhile, and only to a view still
    /// in its window: a lock unmounts the editors it covered.
    func restore() {
        isParked = false
        dropsEdits = false
        let pending = parked
        parked = []
        for entry in pending {
            guard let window = entry.window, let view = entry.responder, view.window === window,
                  window.firstResponder === window || window.firstResponder === window.contentView,
                  window.makeFirstResponder(view),
                  let field = view as? NSTextField, let editor = field.currentEditor() else { continue }
            if let editingText = entry.editingText, editor.string != editingText {
                editor.string = editingText
            }
            if let selection = entry.selection {
                let length = (editor.string as NSString).length
                let location = min(selection.location, length)
                editor.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            }
        }
    }

    private func parkCoveredWindows() {
        for (id, entry) in covered {
            guard let window = entry.window else {
                covered[id] = nil
                continue
            }
            guard let responder = window.firstResponder,
                  responder !== window, responder !== window.contentView else { continue }
            var view = responder as? NSView
            var selection: NSRange?
            var editingText: String?
            // A field being edited has the window's field editor as its first
            // responder; the field is what takes focus back.
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                view = editor.delegate as? NSTextField
                selection = editor.selectedRange()
                editingText = editor.string
            }
            guard window.makeFirstResponder(nil), let view else { continue }
            // The focus the user had comes back, not one taken under the curtain.
            guard !parked.contains(where: { $0.window === window && $0.responder?.window === window }) else { continue }
            parked.append(Parked(window: window, responder: view, selection: selection,
                                 editingText: dropsEdits ? nil : editingText))
        }
    }

    private func scheduleRepark() {
        guard isParked, !isReparkScheduled else { return }
        isReparkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReparkScheduled = false
            if self.isParked { self.parkCoveredWindows() }
        }
    }
}
