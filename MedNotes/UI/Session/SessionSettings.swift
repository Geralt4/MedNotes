import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Settings the session keeps in its injected defaults, and the open editors it tracks.
extension AppSession {
    /// Absent means on: `bool(forKey:)` would read a never-set key as off.
    static func autoSyncSetting(_ defaults: UserDefaults, key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    func setCalendarAutoSync(_ on: Bool) async {
        guard on != calendarAutoSyncEnabled else { return }
        calendarAutoSyncEnabled = on
        defaults.set(on, forKey: Self.calendarAutoSyncDefaultsKey)
        try? await store?.audit.log(
            action: on ? "calendar_auto_sync_on" : "calendar_auto_sync_off",
            entityType: "calendar", entityId: "settings")
    }

    func setRemindersAutoSync(_ on: Bool) async {
        guard on != remindersAutoSyncEnabled else { return }
        remindersAutoSyncEnabled = on
        defaults.set(on, forKey: Self.remindersAutoSyncDefaultsKey)
        try? await store?.audit.log(
            action: on ? "reminders_auto_sync_on" : "reminders_auto_sync_off",
            entityType: "reminders", entityId: "settings")
    }

    func isUntouchedNewNote(_ note: Note) -> Bool {
        note.isUntouchedNewRecord(seededContent: seededNoteContent[note.id])
    }

    /// Called by a record editor when it appears. `draft` must not capture
    /// the view itself (pass its state bindings), or the session would keep
    /// the view alive.
    func registerOpenEditor(_ token: UUID, draft: @escaping () -> OpenEditorDraft?) {
        openEditors[token] = draft
        settledEditors.remove(token)
    }

    /// Called by an editor as it goes away. Returns whether the editor should
    /// still save or discard its own draft: `false` when the session already
    /// did (see `settledEditors`).
    @discardableResult
    func unregisterOpenEditor(_ token: UUID) -> Bool {
        openEditors[token] = nil
        return settledEditors.remove(token) == nil
    }

    /// The drafts of the editors on screen, as `save` would store them, with
    /// the token each registered under.
    func openEditorDrafts() -> [(token: UUID, draft: OpenEditorDraft)] {
        openEditors.compactMap { token, read in
            read().map { (token, preparedForSave($0)) }
        }
    }

    /// The retired Markdown mirror's folder. Kept only so the upgrade can
    /// reconcile it once and then report it for deletion.
    var legacyVaultURL: URL? {
        dataRoot?.vaultURL
    }
}
