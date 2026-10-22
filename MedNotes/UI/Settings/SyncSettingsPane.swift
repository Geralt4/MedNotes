import SwiftUI

/// Settings › Sync: the Apple Calendar and Apple Reminders bridges in one
/// place — whether each is connected, what its last pass did, and what
/// leaves the container once it is on. The toolbar pills in the Calendar and
/// Todos modules show the same state; this is where it is explained.
struct SyncSettingsPane: View {
    @ObservedObject var calendar: AppleCalendarService
    @ObservedObject var reminders: AppleRemindersService
    let destinations: [SyncBridgeType: SyncDestinationViewState]
    let calendarSummary: String?
    let remindersSummary: String?
    /// Whether a granted bridge moves data on its own; off, only Sync Now does.
    @Binding var calendarAutoSync: Bool
    @Binding var remindersAutoSync: Bool
    /// Both run the module's Sync Now: the first press raises the permission
    /// dialog, every later one is a plain two-way pass.
    let onSyncCalendar: () -> Void
    let onSyncReminders: () -> Void

    /// See `GeneralSettingsPane.height`. The rows are known up front: a
    /// status row and a switch per bridge, a destination row once one is
    /// chosen, a "Last sync" row once a pass has run, and an error line while
    /// one stands.
    var preferredHeight: CGFloat {
        var height: CGFloat = 600
        if destinations[.calendar] != nil { height += Self.rowHeight }
        if destinations[.reminders] != nil { height += Self.rowHeight }
        if calendarSummary != nil { height += Self.rowHeight }
        if remindersSummary != nil { height += Self.rowHeight }
        if calendar.lastError != nil { height += Self.noteHeight }
        if reminders.lastError != nil { height += Self.noteHeight }
        #if DEBUG
        if PreviewSeed.isActive { height += Self.noteHeight }
        #endif
        return height
    }

    private static let rowHeight: CGFloat = 41
    private static let noteHeight: CGFloat = 40

    var body: some View {
        Form {
            Section {
                SyncBridgeRows(
                    bridge: .calendar,
                    access: calendar.state,
                    destination: destinations[.calendar],
                    summary: calendarSummary,
                    lastError: calendar.lastError,
                    autoSync: $calendarAutoSync,
                    onSync: onSyncCalendar,
                    identifierPrefix: "settings.sync.calendar")
                SettingsNote("A synced event's title, notes and dates go to the calendar you chose, and from there wherever that account syncs. The event type and patient link never leave MedNotes. Choose the destination before the first write; MedNotes never picks one by name.")
            } header: {
                DetailSectionHeader(title: "Apple Calendar", systemImage: "calendar")
            }

            Section {
                SyncBridgeRows(
                    bridge: .reminders,
                    access: reminders.state,
                    destination: destinations[.reminders],
                    summary: remindersSummary,
                    lastError: reminders.lastError,
                    autoSync: $remindersAutoSync,
                    onSync: onSyncReminders,
                    identifierPrefix: "settings.sync.reminders")
                SettingsNote("A synced todo's title, notes, due day, completion and priority go to the list you chose, and from there wherever that account syncs. The patient link and tags never leave MedNotes.")
            } header: {
                DetailSectionHeader(title: "Apple Reminders", systemImage: "checklist")
            }

            Section {
                SettingsNote("Nothing is written to Apple Calendar or Reminders until you choose a destination and confirm. EventKit cannot tell whether a chosen calendar or list is shared, so any cloud account in the source may receive the data. If a destination disappears, the connection stops rather than falling back to a calendar with the same name. Restoring a backup suspends both bridges until you reconnect them.")
                #if DEBUG
                if PreviewSeed.isActive {
                    SettingsNote("Syncing is disabled while running on sample data.")
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .frame(height: preferredHeight)
    }
}

/// What Settings › Sync reports about one bridge's chosen destination.
struct SyncDestinationViewState: Equatable {
    /// Which bridge this destination belongs to, so an app-created container
    /// is named as a calendar or a list, not always a calendar.
    var bridge: SyncBridgeType = .calendar
    var calendarTitle: String
    var sourceTitle: String
    var sourceType: String
    var state: SyncDestination.ConnectionState
    var appCreated: Bool

    var statusText: String {
        switch state {
        case .confirmed:
            return appCreated
                ? String(localized: "Connected to the \(calendarTitle) \(appCreatedLabel)")
                : String(localized: "Connected to \(calendarTitle)")
        case .needsReconnection:
            return String(localized: "Needs reconnection")
        }
    }

    private var appCreatedLabel: String {
        switch bridge {
        case .calendar: return String(localized: "calendar MedNotes created")
        case .reminders: return String(localized: "list MedNotes created")
        }
    }
}

/// Status line, the destination, the action that fits the state, the
/// automatic-sync switch, and the last pass's summary.
struct SyncBridgeRows: View {
    let bridge: SyncBridge
    let access: SyncBridgeAccess
    let destination: SyncDestinationViewState?
    let summary: String?
    let lastError: String?
    @Binding var autoSync: Bool
    let onSync: () -> Void
    /// `settings.sync.calendar` or `settings.sync.reminders`; the rows append
    /// `.status`, `.destination` and `.autoSync`.
    let identifierPrefix: String

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: Chrome.Space.sm) {
                HStack(spacing: Chrome.Space.xs + 2) {
                    Circle()
                        .fill(access.tint)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(access.title)
                }
                switch access {
                case .granted:
                    Button(destination?.state == .needsReconnection ? "Reconnect…" : "Sync Now", action: onSync)
                case .notRequested:
                    Button("Connect…", action: onSync)
                case .denied:
                    Button("Open System Settings") {
                        bridge.openSystemSettings()
                    }
                }
            }
        }
        .accessibilityIdentifier("\(identifierPrefix).status")
        if let destination {
            LabeledContent("Destination") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: destination.statusText)
                    Text(verbatim: "\(destination.sourceTitle) · \(DisplayCopy.syncSourceType(destination.sourceType))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix).destination")
        } else {
            LabeledContent("Destination") {
                Text("Not chosen")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("\(identifierPrefix).destination")
        }
        // Shown in every state so the choice is visible before connecting;
        // it only takes effect once access is granted and a destination is
        // confirmed.
        Toggle("Keep in sync automatically", isOn: $autoSync)
            .disabled(access != .granted || destination?.state != .confirmed)
            .accessibilityIdentifier("\(identifierPrefix).autoSync")
        if let summary {
            LabeledContent("Last sync") {
                Text(verbatim: summary)
                    .foregroundStyle(.secondary)
            }
        }
        if let lastError {
            Text(verbatim: lastError)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
