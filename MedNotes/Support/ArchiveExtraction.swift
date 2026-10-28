import Foundation

/// The one place a v2 archive is streamed out into a snapshot file and an
/// attachment store. Restore, missing-key recovery and restore-point upgrades
/// all use it, so none of them can disagree about which bytes belong to which
/// attachment.
///
/// The writer emits every attachment's metadata first, then the content of
/// each attachment in the same order. Metadata therefore goes into a queue,
/// and content advances through it: an attachment is stored the moment its
/// last byte arrives, and an empty one the moment the queue reaches it.
enum ArchiveExtraction {
    struct Extracted {
        var manifest: BackupArchiveV2.Manifest
        /// Every attachment now in the store, in archive order.
        var attachments: [BackupArchiveV2.AttachmentRecord]
    }

    static func extract(
        opened: BackupArchiveV2.OpenedArchive,
        snapshotURL: URL,
        store: AttachmentStore
    ) async throws -> Extracted {
        guard FileManager.default.createFile(
            atPath: snapshotURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: snapshotURL.path) else {
            throw BackupError.invalidArchive
        }
        defer { try? handle.close() }

        var expectedSnapshotBytes = 0
        var snapshotBytes = 0
        var queue: [BackupArchiveV2.AttachmentRecord] = []
        var seenStorageIDs = Set<String>()
        var next = 0
        var pending = Data()

        func storeCompleted() async throws {
            while next < queue.count, pending.count == queue[next].plaintextLength {
                let record = queue[next]
                guard store.digest(of: pending) == record.digest else {
                    throw BackupError.integrityCheckFailed(
                        String(localized: "attachment \(record.fileID)"))
                }
                // Even empty attachments occupy a full padding block on disk.
                // Check the staging volume immediately before every write so
                // a small archive cannot silently bypass the space estimate.
                let payload = Int64(record.plaintextLength) + 24
                let block = Int64(EncryptedFileStore.paddingBlock)
                let padded = ((payload + block - 1) / block) * block
                let overhead = ((padded + Int64(EncryptedFileStore.chunkSize) - 1)
                    / Int64(EncryptedFileStore.chunkSize)) * 17 + 128
                try BackupService.requireFreeSpace(bytes: padded + overhead, at: snapshotURL.deletingLastPathComponent())
                _ = try await store.store(pending, storageID: record.storageID)
                pending.removeAll(keepingCapacity: true)
                next += 1
            }
        }

        let manifest = try await BackupArchiveV2.read(opened: opened) { item in
            switch item {
            case .databaseSnapshotHeader(let header):
                guard header.totalLength <= BackupArchiveV2.maxSnapshotBytes else {
                    throw BackupError.invalidArchive
                }
                expectedSnapshotBytes = header.totalLength
            case .databaseChunk(let chunk):
                snapshotBytes += chunk.count
                guard snapshotBytes <= expectedSnapshotBytes else { throw BackupError.invalidArchive }
                try handle.write(contentsOf: chunk)
            case .attachment(let record):
                guard EncryptedFileStore.isSafeStorageID(record.storageID),
                      seenStorageIDs.insert(record.storageID.lowercased()).inserted else {
                    throw BackupError.invalidArchive
                }
                queue.append(record)
            case .attachmentChunk(let chunk):
                try await storeCompleted()
                guard next < queue.count else { throw BackupError.invalidArchive }
                pending.append(chunk)
                guard pending.count <= queue[next].plaintextLength else {
                    throw BackupError.invalidArchive
                }
                try await storeCompleted()
            case .end:
                try await storeCompleted()
            }
        }
        guard next == queue.count, snapshotBytes == expectedSnapshotBytes else {
            throw BackupError.invalidArchive
        }
        return Extracted(manifest: manifest, attachments: queue)
    }

    /// Backups written by the migration wizard before this check existed hold
    /// a plaintext database inside the archive (the archive itself is
    /// encrypted). Restore and recovery open the snapshot under the archive
    /// key, so such a snapshot is exported into one first. A snapshot that is
    /// already encrypted is left alone.
    static func ensureEncryptedSnapshot(at url: URL, key: Data) async throws {
        guard SQLiteHeaderInspection.isPlaintextSQLite(at: url) else { return }
        // Judged before `Database(path:)` migrates it.
        try Database.validateSnapshotFile(path: url.path, key: nil)
        let plain = try Database(path: url.path)
        let converted = url.appendingPathExtension("encrypted")
        do {
            try await plain.vacuumInto(path: converted.path, key: key)
            await plain.close()
        } catch {
            await plain.close()
            throw error
        }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        try fm.moveItem(at: converted, to: url)
    }
}
