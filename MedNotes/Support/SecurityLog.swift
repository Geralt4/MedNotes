import Foundation
import os

/// The only logging surface in the app.
///
/// The audit trail inside the encrypted database is the record of what
/// happened; this is what reaches the system log, and it must never carry
/// secrets, note content, patient names, EventKit content or full paths. Every
/// event is reduced to a generic name plus opaque identifiers and counts.
enum SecurityLog {
    private static let logger = Logger(subsystem: "com.johnteam.MedNotes", category: "security")

    enum Event: String {
        case appLaunch = "app.launch"
        case appLock = "app.lock"
        case appUnlock = "app.unlock"
        case storeEncrypted = "store.encrypted"
        case storeMigration = "store.migration"
        case backupCreated = "backup.created"
        case backupRestored = "backup.restored"
        case attachmentExternalOpen = "attachment.external_open"
        case markdownExported = "markdown.exported"
        case syncDestinationConfirmed = "sync.destination_confirmed"
        case syncDestinationStale = "sync.destination_stale"
        case integrityFailed = "store.integrity_failed"
        case restorePointUpgradeFailed = "restore_point.upgrade_failed"
        case linkDerivationFailed = "links.derivation_failed"
    }

    /// Records a generic security event with counts and opaque IDs only.
    static func record(_ event: Event, count: Int? = nil, opaqueID: String? = nil) {
        if let count, let opaqueID {
            logger.notice("\(event.rawValue, privacy: .public) count=\(count, privacy: .public) id=\(opaqueID, privacy: .public)")
        } else if let count {
            logger.notice("\(event.rawValue, privacy: .public) count=\(count, privacy: .public)")
        } else if let opaqueID {
            logger.notice("\(event.rawValue, privacy: .public) id=\(opaqueID, privacy: .public)")
        } else {
            logger.notice("\(event.rawValue, privacy: .public)")
        }
    }

    /// Reduces an error to its kind, never its message: an interpolated
    /// `localizedDescription` can carry a path or a record title.
    static func recordFailure(_ event: Event, error: Error) {
        logger.error("\(event.rawValue, privacy: .public) failed type=\(String(describing: type(of: error)), privacy: .public)")
    }

    /// A short opaque label for a file name or path. Never returns the path.
    static func opaqueID(for url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(url.lastPathComponent.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func opaqueID(for uuid: UUID) -> String {
        uuid.uuidString.prefix(8).lowercased()
    }
}
