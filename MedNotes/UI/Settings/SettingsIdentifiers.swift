import SwiftUI

/// Stable identifiers for the Settings controls the security test suite
/// asserts on. They are never localized, so a wording change in English or
/// Greek cannot break a test.
enum SettingsIdentifiers {
    static let launchPicker = "settings.general.launchPicker"
    static let storeState = "settings.general.storeState"
    static let lockInterval = "settings.general.lockInterval"

    static let templateList = "settings.templates.list"
    static let templateName = "settings.templates.name"
    static let templateContent = "settings.templates.content"

    static let calendarStatus = "settings.sync.calendar.status"
    static let calendarDestination = "settings.sync.calendar.destination"
    static let calendarAutoSync = "settings.sync.calendar.autoSync"
    static let remindersStatus = "settings.sync.reminders.status"
    static let remindersDestination = "settings.sync.reminders.destination"
    static let remindersAutoSync = "settings.sync.reminders.autoSync"

    static let storageLocation = "settings.data.location"
    static let storageCounts = "settings.data.counts"
    static let lastBackup = "settings.data.lastBackup"
    static let restorePointList = "settings.data.restorePoints"
    static let integrityButton = "settings.data.integrityCheck"
    static let rebuildIndexesButton = "settings.data.rebuildIndexes"
    static let markdownExport = "settings.data.markdownExport"

    static let backupPassphrase = "backup.passphrase"
    static let backupConfirmation = "backup.confirmation"
    static let backupConfirmButton = "backup.confirm"
}
