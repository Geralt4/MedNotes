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
    }

    func unregisterOpenEditor(_ token: UUID) {
        openEditors[token] = nil
    }

    /// The retired Markdown mirror's folder. Kept only so the upgrade can
    /// reconcile it once and then report it for deletion.
    var legacyVaultURL: URL? {
        dataRoot?.vaultURL
    }
}
