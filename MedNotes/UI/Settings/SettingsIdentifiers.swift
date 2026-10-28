import SwiftUI

/// Stable identifiers for the Settings controls the security test suite
/// asserts on. They are never localized, so a wording change in English or
/// Greek cannot break a test.
enum SettingsIdentifiers {
    static let launchPicker = "settings.general.launchPicker"
    static let storeState = "settings.general.storeState"
    static let lockInterval = "settings.general.lockInterval"

    static let storageLocation = "settings.data.location"
    static let storageCounts = "settings.data.counts"
    static let lastBackup = "settings.data.lastBackup"
    static let integrityButton = "settings.data.integrityCheck"
    static let rebuildIndexesButton = "settings.data.rebuildIndexes"
    static let markdownExport = "settings.data.markdownExport"
}
