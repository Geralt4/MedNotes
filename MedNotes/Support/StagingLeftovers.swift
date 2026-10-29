import Foundation

/// Folders a restore, a recovery or an upgrade builds in the temporary
/// directory and removes in a `defer`. A crash or a kill skips the `defer`, and
/// what was left can be a decrypted database and the attachments beside it, in
/// the clear. Nothing else reads them, and each can be made again from the file
/// the user still has, so they are removed when the app launches.
enum StagingLeftovers {
    /// The names those operations give their working folders and files.
    static let prefixes = [
        "mednotes-restore-", "mednotes-legacy-restore-", "mednotes-recovery-",
        "mednotes-upgrade-", "mednotes-snapshot-"
    ]

    /// Removes the direct children of `directory` whose names start with one of
    /// `prefixes`, and returns how many went. A symbolic link is removed as a
    /// link, never followed.
    @discardableResult
    static func purge(in directory: URL = FileManager.default.temporaryDirectory) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where prefixes.contains(where: name.hasPrefix) {
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
