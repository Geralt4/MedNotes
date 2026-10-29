import SwiftUI

/// MedNotes › Settings… (⌘,). One window, one tab per concern: how the app
/// opens and where notes go, the clinical templates, the two Apple bridges,
/// and the store itself.
///
/// The panes are plain views over values, bindings and closures, so they
/// render offscreen and in tests without a session (the same rule the record
/// editors follow); this root is the only place the session is wired in.
struct SettingsView: View {
    @EnvironmentObject private var session: AppSession

    /// One width for every tab, so switching tabs moves the window's bottom
    /// edge and nothing else.
    static let width: CGFloat = 540

    var body: some View {
        TabView {
            GeneralSettingsPane(
                launchModule: $session.launchModule,
                isEncrypted: !session.storeIsPlaintext,
                idleMinutes: 5
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            TemplatesSettingsPane(actions: TemplateActions(
                load: { try await session.loadTemplates() },
                save: { try await session.saveTemplate($0) },
                create: { try await session.newTemplate() },
                delete: { try await session.deleteTemplate(id: $0) },
                reset: { try await session.resetTemplate(id: $0) },
                discardIfUntouched: { await session.discardTemplateIfUntouched($0) }
            ), defaultTemplateID: $session.defaultNoteTemplateID)
            .tabItem { Label("Templates", systemImage: "doc.badge.plus") }

            SyncSettingsPane(
                calendar: session.appleCalendar,
                reminders: session.appleReminders,
                destinations: session.syncDestinationCandidates,
                calendarSummary: session.lastCalendarSyncSummary,
                remindersSummary: session.lastRemindersSyncSummary,
                calendarAutoSync: Binding(
                    get: { session.calendarAutoSyncEnabled },
                    set: { on in Task { await session.setCalendarAutoSync(on) } }
                ),
                remindersAutoSync: Binding(
                    get: { session.remindersAutoSyncEnabled },
                    set: { on in Task { await session.setRemindersAutoSync(on) } }
                ),
                onSyncCalendar: { Task { await session.syncCalendarNow() } },
                onSyncReminders: { Task { await session.syncRemindersNow() } }
            )
            .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            DataSettingsPane(
                loadSummary: { await session.storageSummary() },
                loadRestorePoints: { await session.restorePoints() },
                deleteRestorePoint: { try await session.deleteRestorePoint($0) },
                restoreRestorePoint: { try await session.restoreFromRestorePoint($0) },
                checkIntegrity: { await session.checkIntegrity() },
                rebuildIndexes: { await session.rebuildIndexes() },
                exportMarkdown: { try await session.exportMarkdownVault() },
                exportInterruption: session.markdownExportInterruption,
                legacyVaultReport: { await session.legacyVaultReport() },
                legacyVaultURL: session.legacyVaultURL,
                deleteLegacyVault: { try await session.deleteLegacyVault() },
                resolveLegacyVault: { try await session.resolveLegacyVault($0) }
            )
            // Rebuilt when the store locks and when it opens again: what the
            // pane read from the store (the legacy vault's note titles among
            // it) is not kept behind the curtain, and is read afresh after.
            .id(session.canUseStore)
            .tabItem { Label("Data", systemImage: "internaldrive") }
        }
        .frame(width: Self.width)
    }
}
