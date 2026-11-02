import Foundation

/// What a backup, a restore, an import or the encryption migration shows when
/// it fails, and what goes to the log instead.
///
/// Several of these errors carry internals: a SQLite message ("no such table:
/// notes"), a table or trigger name, a row count, an `integrity_check` result.
/// The user gets a plain line; the detail goes to `SecurityLog` for whoever
/// has to diagnose it. The error types' own `errorDescription` already leaves
/// the detail out, so no screen that shows one can leak it; this adds the log
/// line, and makes the same true of a raw `SQLiteError`.
enum FailureContext {
    case backup, restore, importing, migration, export

    var event: SecurityLog.Event {
        switch self {
        case .backup: return .backupFailed
        case .restore: return .restoreFailed
        case .importing: return .importFailed
        case .migration: return .migrationFailed
        case .export: return .exportFailed
        }
    }

    /// The line for an error whose own text would show internals.
    var generalMessage: String {
        switch self {
        case .backup: return String(localized: "The backup could not be made.")
        case .restore: return String(localized: "The restore could not be completed.")
        case .importing: return String(localized: "The import could not be completed.")
        case .migration: return String(localized: "The store could not be encrypted.")
        case .export: return String(localized: "The export could not be completed.")
        }
    }
}

/// An error that holds detail for the log that its message does not show.
protocol DetailedFailure: Error {
    var logDetail: String? { get }
}

extension BackupError: DetailedFailure {
    var logDetail: String? {
        switch self {
        case let .integrityCheckFailed(detail), let .restoreFailed(detail),
             let .unexpectedSchema(detail), let .safetyCopyIncomplete(detail):
            return "\(Self.caseName(self)): \(detail)"
        case let .countMismatch(entity, expected, actual):
            return "countMismatch: \(entity) expected \(expected), found \(actual)"
        case let .rollbackFailed(_, detail):
            return "rollbackFailed: \(detail)"
        default:
            return nil
        }
    }

    private static func caseName(_ error: BackupError) -> String {
        switch error {
        case .integrityCheckFailed: return "integrityCheckFailed"
        case .restoreFailed: return "restoreFailed"
        case .unexpectedSchema: return "unexpectedSchema"
        case .safetyCopyIncomplete: return "safetyCopyIncomplete"
        default: return "backupError"
        }
    }
}

extension StoreMigrator.MigrationError: DetailedFailure {
    var logDetail: String? {
        switch self {
        case let .stagingFailed(detail): return "stagingFailed: \(detail)"
        case let .validationFailed(detail): return "validationFailed: \(detail)"
        case let .swapFailed(detail): return "swapFailed: \(detail)"
        default: return nil
        }
    }
}

extension RestoreRecovery.RecoveryError: DetailedFailure {
    var logDetail: String? {
        switch self {
        case let .couldNotReinstate(_, detail): return "couldNotReinstate: \(detail)"
        }
    }
}

extension SQLiteError: DetailedFailure {
    /// The message SQLite gave, never the statement: for `PRAGMA key` and
    /// `rekey` the SQL holds the raw key.
    var logDetail: String? {
        switch self {
        // The one SQLite message with a plain, useful text of its own.
        case let .step(msg, _) where msg.hasPrefix("UNIQUE constraint failed: patients.amka"): return nil
        case let .open(msg): return "open: \(msg)"
        case let .prepare(msg, _): return "prepare: \(msg)"
        case let .step(msg, _): return "step: \(msg)"
        case let .exec(msg, _): return "exec: \(msg)"
        case let .keyingFailed(msg): return "keying: \(msg)"
        default: return nil
        }
    }
}

enum UserFacingFailure {
    /// The text to show for `error` while `context` was running, with its
    /// detail written to the log. An error whose own message carries SQLite's
    /// text is replaced by the context's general line; any other error keeps
    /// its own message (a wrong passphrase, a file that is not a backup).
    static func message(for error: Error, during context: FailureContext) -> String {
        if let detailed = error as? DetailedFailure, let detail = detailed.logDetail {
            SecurityLog.recordFailure(context.event, detail: detail)
            if error is SQLiteError { return context.generalMessage }
        }
        return error.localizedDescription
    }
}
