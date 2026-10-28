import Foundation

/// What a record editor on screen holds at the moment the store locks.
///
/// The lock asks every registered editor for this synchronously, before it
/// detaches the store, and then saves an edited draft (or discards a new
/// record that was never touched) into the closing store — the same rule an
/// editor applies when the user leaves it. Without this the lock would clear
/// the selection, unmount the editor, and its `onDisappear` save would find no
/// store: whatever was typed since the last save would be gone.
///
/// `edited` is the editor's own `hasChanges`; only the editor knows what it
/// loaded.
enum OpenEditorDraft {
    case note(Note, edited: Bool)
    case patient(Patient, edited: Bool, knownFileIDs: Set<UUID>?)
    case todo(TodoItem, edited: Bool)
    case event(CalendarEvent, edited: Bool)
}
