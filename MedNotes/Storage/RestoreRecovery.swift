import Foundation

/// What a restore leaves behind while it installs, and how a launch undoes an
/// install that was cut off.
///
/// A restore moves the live database and attachments into `RestoreRollback-<id>/`
/// before it puts the backup's in their place, and deletes that folder only
/// once the installed store has been verified. A crash or power loss in between
/// used to leave the app with a half-installed store and nobody looking at the
/// folder: the database file missing, or half rekeyed and unreadable, or a
/// restored database beside the old attachments, which the orphan sweep then
/// deleted as unreferenced.
///
/// The install writes `restore.json` into the folder at each step. At launch,
/// before any key is read and before any store opens, `recoverInterruptedRestore`
/// puts the originals back for every folder whose install did not reach
/// `verified`. It only moves files, so it needs no key, and what it takes out
/// of the way goes to a `RestoreDiscard-` folder that is deleted last.
enum RestoreRecovery {
    static let rollbackPrefix = "RestoreRollback-"
    static let discardPrefix = "RestoreDiscard-"
    static let journalName = "restore.json"

    /// How far the install got. Only `verified` means the restored store holds.
    enum Phase: String, Codable, Sendable {
        case started
        case databaseReplaced
        case attachmentsAside
        case attachmentsIn
        case verified
    }

    private struct Journal: Codable {
        var phase: Phase
    }

    enum RecoveryError: Error, LocalizedError {
        /// The originals are still in `folder`; nothing was deleted.
        case couldNotReinstate(folder: String, detail: String)

        var errorDescription: String? {
            switch self {
            case let .couldNotReinstate(folder, detail):
                return String(localized: "An interrupted restore could not be undone automatically. Your original data is in the folder “\(folder)” inside the MedNotes data folder, and nothing was deleted. \(detail)")
            }
        }
    }

    static func writeJournal(_ phase: Phase, in folder: URL) throws {
        let data = try JSONEncoder().encode(Journal(phase: phase))
        try data.write(to: folder.appendingPathComponent(journalName), options: .atomic)
    }

    /// `nil` for a folder with no readable journal (written by an older build).
    static func phase(in folder: URL) -> Phase? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(journalName)),
              let journal = try? JSONDecoder().decode(Journal.self, from: data) else { return nil }
        return journal.phase
    }

    /// The folders a restore may have left in `rootURL`, newest first.
    static func rollbackFolders(in rootURL: URL) -> [URL] {
        folders(withPrefix: rollbackPrefix, in: rootURL)
    }

    private static func folders(withPrefix prefix: String, in rootURL: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
    }

    /// Undoes the newest install that did not reach `verified`. Returns how
    /// many folders it reinstated.
    ///
    /// - A `verified` folder is a restore that held and whose delete was cut
    ///   off: it is removed, and the live store is left alone.
    /// - An older unverified folder is left where it is. Putting its original
    ///   back after the newest one's would replace a later state with an earlier.
    /// - A folder with no journal comes from an older build, so nothing says
    ///   whether the live store is a finished restore or a broken one. It is
    ///   reinstated only when the live database is missing; otherwise it is left
    ///   alone rather than risk reverting a restore that completed.
    @discardableResult
    static func recoverInterruptedRestore(rootURL: URL) throws -> Int {
        let fm = FileManager.default
        for leftover in folders(withPrefix: discardPrefix, in: rootURL) {
            try? fm.removeItem(at: leftover)
        }
        var reinstated = 0
        // Only the newest folder may be put back, whatever became of it: when
        // it was a restore that held (removed) or an older build's (left
        // alone), an older unverified folder holds an earlier state.
        var newestSeen = false
        for folder in rollbackFolders(in: rootURL) {
            let isNewest = !newestSeen
            newestSeen = true
            switch phase(in: folder) {
            case .verified:
                try? fm.removeItem(at: folder)
            case nil:
                let live = rootURL.appendingPathComponent("mednotes.db")
                if isNewest, !fm.fileExists(atPath: live.path) {
                    try reinstate(from: folder, rootURL: rootURL)
                    reinstated += 1
                }
            default:
                if isNewest {
                    try reinstate(from: folder, rootURL: rootURL)
                    reinstated += 1
                }
            }
        }
        return reinstated
    }

    /// Puts the originals kept in `folder` back. Safe to run again after being
    /// cut off itself: each step looks at what is on disk, not at what the
    /// previous step was.
    private static func reinstate(from folder: URL, rootURL: URL) throws {
        let fm = FileManager.default
        let live = rootURL.appendingPathComponent("mednotes.db")
        let keptDatabase = folder.appendingPathComponent("mednotes.db")
        let discard = rootURL.appendingPathComponent(
            discardPrefix + UUID().uuidString, isDirectory: true)
        do {
            // A kept database means the install had moved the original out, so
            // whatever is at the live path is the incoming copy: whole, half
            // rekeyed, or gone. A rekey in progress also leaves a `-journal`,
            // which would be replayed into the original if it stayed.
            if fm.fileExists(atPath: keptDatabase.path) {
                for suffix in ["", "-wal", "-shm", "-journal"]
                where fm.fileExists(atPath: live.path + suffix) {
                    try fm.removeItem(atPath: live.path + suffix)
                }
                for suffix in ["", "-wal", "-shm"]
                where fm.fileExists(atPath: keptDatabase.path + suffix) {
                    try fm.moveItem(atPath: keptDatabase.path + suffix, toPath: live.path + suffix)
                }
            }
            let keptAttachments = folder.appendingPathComponent("Attachments", isDirectory: true)
            let liveAttachments = rootURL.appendingPathComponent("Attachments", isDirectory: true)
            if fm.fileExists(atPath: keptAttachments.path) {
                // What is live now is the backup's copy, or an empty folder the
                // app made on the way in. Moved aside, never deleted first.
                if fm.fileExists(atPath: liveAttachments.path) {
                    try fm.createDirectory(at: discard, withIntermediateDirectories: true)
                    try fm.moveItem(
                        at: liveAttachments, to: discard.appendingPathComponent("Attachments"))
                }
                try fm.moveItem(at: keptAttachments, to: liveAttachments)
            }
        } catch {
            throw RecoveryError.couldNotReinstate(
                folder: folder.lastPathComponent, detail: error.localizedDescription)
        }
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: discard)
    }
}
