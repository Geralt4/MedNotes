import CryptoKit
import Foundation

struct DataRoot {
    let rootURL: URL

    /// Where "Open Externally" writes its plaintext copies, and what a lock
    /// empties. The app's own roots, the real one and the preview, share the
    /// folder the app has always used, `appExternalCopiesURL`. Every other
    /// root gets a folder of its own. The XCTest host is this app, in the
    /// same container, so a test's lock that emptied the app's folder would
    /// delete a copy the running app had handed to a viewer.
    let externalCopiesURL: URL

    /// The app's folder for "Open Externally" copies, in the container's
    /// temporary directory. Launch, lock and quit of the app's own session
    /// empty it.
    static var appExternalCopiesURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MedNotesExternal", isDirectory: true)
    }

    /// A folder beside the app's, named after `rootURL`: one per root, the
    /// same for every `DataRoot` over that path, and still in the temporary
    /// directory, never inside the root, where a backup could pick it up.
    static func scopedExternalCopiesURL(for rootURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8))
        let tag = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("MedNotesExternal-\(tag)", isDirectory: true)
    }

    var databaseURL: URL {
        rootURL.appendingPathComponent("mednotes.db")
    }

    var backupsURL: URL {
        rootURL.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Legacy plaintext attachment tree. Read only during migration, then
    /// removed; production reads and writes go to `attachmentsURL`.
    var filesURL: URL {
        rootURL.appendingPathComponent("Files", isDirectory: true)
    }

    /// Encrypted attachments, addressed by opaque storage IDs.
    var attachmentsURL: URL {
        rootURL.appendingPathComponent("Attachments", isDirectory: true)
    }

    /// Encrypted internal restore points written by the backup service.
    var restorePointsURL: URL {
        rootURL.appendingPathComponent("RestorePoints", isDirectory: true)
    }

    /// Plain-text Markdown mirror of the notes database (Obsidian-compatible).
    /// Retired: kept only so the upgrade can reconcile and then delete it.
    var vaultURL: URL {
        rootURL.appendingPathComponent("Vault", isDirectory: true)
    }

    /// `externalCopiesURL`: `nil` gives the root a folder of its own; only the
    /// app's own roots pass `appExternalCopiesURL`.
    init(rootURL: URL, externalCopiesURL: URL? = nil) throws {
        self.rootURL = rootURL
        self.externalCopiesURL = externalCopiesURL ?? Self.scopedExternalCopiesURL(for: rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: restorePointsURL, withIntermediateDirectories: true)
    }

    /// `base`: Application Support, unless a test passes a folder of its own
    /// to check how the app's root is built without touching the real one.
    static func applicationSupport(base: URL? = nil) throws -> DataRoot {
        let base = try base ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return try DataRoot(
            rootURL: base.appendingPathComponent("com.johnteam.MedNotes", isDirectory: true),
            externalCopiesURL: appExternalCopiesURL)
    }

    static func temporary() throws -> DataRoot {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-root-\(UUID().uuidString)", isDirectory: true)
        return try DataRoot(rootURL: dir)
    }

    #if DEBUG

    /// Directory holding the seeded preview store. A literal sibling of the real
    /// root's name, never the real name mutated at runtime: the reason sample
    /// data cannot reach the user's store is that this is a compile-time constant.
    static let previewDirectoryName = "com.johnteam.MedNotes.Preview"

    /// The only way to obtain a preview root.
    ///
    /// The reset happens here, before any `DataRoot` exists and therefore before
    /// `AppStore` can open `mednotes.db`. Handing callers a separate `reset()` to
    /// invoke afterwards would let them delete the directory out from under an
    /// open SQLite connection — sqlite keeps writing to the unlinked inode, the
    /// app looks healthy, and nothing persists. That ordering is not
    /// representable through this API.
    ///
    /// `base`: Application Support, unless a test passes a folder of its own.
    static func preview(reset: Bool, base: URL? = nil) throws -> DataRoot {
        let base = try base ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let root = base.appendingPathComponent(previewDirectoryName, isDirectory: true)
        // Tripwire for a future edit, not the safety argument — see above.
        precondition(isPreviewRoot(root), "refusing to reset a non-preview root: \(root.path)")
        // `removeItem` throws rather than no-oping when the directory was never
        // created, which is the ordinary first-run state.
        if reset, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        return try DataRoot(rootURL: root, externalCopiesURL: appExternalCopiesURL)
    }

    /// Pure predicate, so the isolation claim is assertable in a test.
    static func isPreviewRoot(_ url: URL) -> Bool {
        url.standardizedFileURL.lastPathComponent == previewDirectoryName
    }

    #endif
}
