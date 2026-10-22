import Foundation
import Sodium

/// The portable backup container, version 2.
///
/// A versioned binary stream of typed records only. Directory trees, file
/// names, hard links and symbolic links are not representable: a backup is a
/// manifest, an encrypted database snapshot, attachment metadata, attachment
/// chunks and an end marker, in that order.
///
/// Fixed header (authenticated as additional data on every chunk):
///
///     "MNB2" | version (1) | kdf profile (1) | Argon2 salt (16)
///         | stream header (24) | u64 payloadLength | u16 reserved
///
/// Then a sequence of records, each one `secretstream_xchacha20poly1305`
/// chunk:
///
///     record: u8 type | u64 plaintext length | ciphertext (length + 17)
///
/// The end marker carries the FINAL tag, so truncation, reordering and a
/// missing final tag all fail authentication. Nothing is allocated or derived
/// before the limits below are checked, and the KDF profile is a fixed
/// identifier rather than attacker-controlled numbers.
enum BackupArchiveV2 {
    static let magic = Data("MNB2".utf8)
    static let version: UInt8 = 1
    static let saltLength = 16
    static let reservedLength = 10
    static var headerLength: Int {
        magic.count + 1 + 1 + saltLength + SecretStream.XChaCha20Poly1305.HeaderBytes + reservedLength
    }
    static let fileExtension = "mednotesbackup"

    // Hard limits, checked before allocation or cryptographic work.
    static let maximumHeaderBytes = 4096
    static let maxChunkBytes = 1 << 20
    static let maxRecords = 100_000
    static let maxArchiveBytes: UInt64 = 100 * 1024 * 1024 * 1024
    /// Production v1 archives are at most 1 GiB.
    static let maxV1ArchiveBytes: UInt64 = 1024 * 1024 * 1024
    static let maxAttachmentBytes = 2 * 1024 * 1024 * 1024
    static let maxSnapshotBytes = 8 * 1024 * 1024 * 1024

    enum KDFProfile: UInt8, CaseIterable {
        /// Argon2id v1.3, 64 MiB, three operations — the RFC 9106 low-memory
        /// recommendation.
        case argon2id64MiB3Ops = 1

        var algorithm: PWHash.Alg {
            switch self {
            case .argon2id64MiB3Ops: return .Argon2ID13
            }
        }

        var memoryBytes: Int { 64 * 1024 * 1024 }
        var operations: Int { 3 }
    }

    /// What seals an archive. A portable backup is sealed by a passphrase
    /// the user chose. An internal restore point has no passphrase: it is
    /// sealed by a key derived from the device's restore key, so the file is
    /// useless without that key. The header's profile byte says which one a
    /// file needs, and a reader holding the other kind is refused before any
    /// key derivation runs.
    enum Sealing {
        case passphrase(String)
        case deviceKey(Data)
    }

    /// The header profile byte for archives sealed by `Sealing.deviceKey`.
    static let deviceKeyProfile: UInt8 = 2
    static let deviceKeyContext = "mn.rp.archive.v2"

    enum RecordType: UInt8 {
        case manifest = 1
        /// JSON `SnapshotHeader` describing the database blob that follows.
        case databaseSnapshot = 2
        /// One ≤1 MiB slice of the encrypted database snapshot.
        case databaseChunk = 3
        /// JSON `AttachmentRecord`, one per attachment, in stream order.
        case attachmentMetadata = 4
        /// One ≤1 MiB slice of one attachment's plaintext, in metadata order.
        case attachmentChunk = 5
        /// Empty payload, FINAL tag.
        case end = 6
    }

    struct SnapshotHeader: Codable, Equatable, Sendable {
        var totalLength: Int
        var chunkCount: Int
    }

    enum ArchiveError: Error, LocalizedError, Equatable {
        case notAnArchive
        case unsupportedVersion(UInt8)
        case unknownKDFProfile(UInt8)
        case wrongPassphraseOrCorrupt
        case tooManyRecords
        case oversizedField
        case truncated
        case badRecordOrder
        case missingFinalTag
        case unexpectedRecord(UInt8)
        case passphrasePolicy(String)
        case ioFailure(String)
        case insufficientSpace
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return String(localized: "This file is not a MedNotes backup.")
            case .unsupportedVersion(let v):
                return String(localized: "This backup was written by a newer MedNotes (format \(Int(v))).")
            case .unknownKDFProfile(let p):
                return String(localized: "This backup uses an unknown key-derivation profile (\(Int(p))).")
            case .wrongPassphraseOrCorrupt:
                return String(localized: "The passphrase is wrong, or the backup file is damaged.")
            case .tooManyRecords:
                return String(localized: "The backup contains too many records to process safely.")
            case .oversizedField:
                return String(localized: "The backup contains a field that is too large.")
            case .truncated:
                return String(localized: "The backup ends before its final marker.")
            case .badRecordOrder:
                return String(localized: "The backup's records are out of order.")
            case .missingFinalTag:
                return String(localized: "The backup's final authentication tag is missing.")
            case .unexpectedRecord(let type):
                return String(localized: "The backup contains an unknown record type (\(Int(type))).")
            case .passphrasePolicy(let message):
                return message
            case .ioFailure(let detail):
                return String(localized: "The backup file could not be read or written: \(detail)")
            case .insufficientSpace:
                return String(localized: "There is not enough free disk space to stage this backup.")
            case .cancelled:
                return String(localized: "The backup operation was cancelled.")
            }
        }
    }

    // MARK: - Manifest

    struct Manifest: Codable, Equatable, Sendable {
        var formatVersion = 2
        var name: String
        var createdAt: Date
        var schemaVersion: Int
        var counts: [String: Int]
        var attachmentCount: Int
    }

    struct AttachmentRecord: Codable, Equatable, Sendable {
        var fileID: String
        var patientID: String
        var name: String
        var type: String
        var storageID: String
        var plaintextLength: Int
        var digest: String
        var uploadDate: Date
        var notes: String
        var tags: [String]
    }

    // MARK: - Header

    private struct Header {
        var profile: UInt8
        var salt: Data
        var streamHeader: [UInt8]
        var canonical: Data
    }

    private static func makeHeader(salt: Data, streamHeader: [UInt8], profile: UInt8) -> Data {
        var header = magic
        header.append(version)
        header.append(profile)
        header.append(salt)
        header.append(contentsOf: streamHeader)
        header.append(contentsOf: withUnsafeBytes(of: UInt64(0).bigEndian) { Data($0) })
        header.append(contentsOf: [0, 0])
        return header
    }

    private static func parseHeader(_ data: Data) throws -> Header {
        guard data.count >= headerLength, data.prefix(magic.count) == magic else {
            throw ArchiveError.notAnArchive
        }
        var offset = magic.count
        let version = data[data.startIndex + offset]; offset += 1
        guard version == Self.version else { throw ArchiveError.unsupportedVersion(version) }
        let profileRaw = data[data.startIndex + offset]; offset += 1
        guard profileRaw == KDFProfile.argon2id64MiB3Ops.rawValue || profileRaw == deviceKeyProfile else {
            throw ArchiveError.unknownKDFProfile(profileRaw)
        }
        let salt = data.subdata(in: offset..<(offset + saltLength)); offset += saltLength
        let streamHeader = [UInt8](data.subdata(
            in: offset..<(offset + SecretStream.XChaCha20Poly1305.HeaderBytes)))
        return Header(profile: profileRaw, salt: salt, streamHeader: streamHeader, canonical: data.prefix(headerLength))
    }

    // MARK: - Seal

    /// Writes a v2 archive.
    ///
    /// `databaseSnapshot` receives the derived archive key and must return a
    /// SQLCipher database encrypted with it, so no plaintext database is ever
    /// written during backup creation. `attachmentReader` supplies each
    /// attachment's plaintext, which is encrypted into the stream.
    static func seal(
        manifest: Manifest,
        databaseSnapshot: (Data) async throws -> Data,
        attachments: [AttachmentRecord],
        attachmentReader: (AttachmentRecord) async throws -> Data,
        passphrase: String,
        to destination: URL,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) async throws {
        try await seal(
            manifest: manifest, databaseSnapshot: databaseSnapshot, attachments: attachments,
            attachmentReader: attachmentReader, sealing: .passphrase(passphrase),
            to: destination, progress: progress, isCancelled: isCancelled)
    }

    static func seal(
        manifest: Manifest,
        databaseSnapshot: (Data) async throws -> Data,
        attachments: [AttachmentRecord],
        attachmentReader: (AttachmentRecord) async throws -> Data,
        sealing: Sealing,
        to destination: URL,
        progress: ((Int, Int) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) async throws {
        if case .passphrase(let passphrase) = sealing,
           let policyError = BackupPassphrasePolicy.validate(passphrase) {
            throw ArchiveError.passphrasePolicy(policyError)
        }
        guard attachments.count <= maxRecords else { throw ArchiveError.tooManyRecords }

        let sodium = Sodium()
        let salt = Data(sodium.randomBytes.buf(length: saltLength) ?? [])
        let key = try deriveSealingKey(sealing, salt: salt)
        guard let push = sodium.secretStream.xchacha20poly1305.initPush(secretKey: key) else {
            throw ArchiveError.wrongPassphraseOrCorrupt
        }
        let profile: UInt8
        switch sealing {
        case .passphrase: profile = KDFProfile.argon2id64MiB3Ops.rawValue
        case .deviceKey: profile = deviceKeyProfile
        }
        let header = makeHeader(salt: salt, streamHeader: push.header(), profile: profile)

        let tmp = destination.appendingPathExtension("staging")
        _ = FileManager.default.createFile(atPath: tmp.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        // Whatever stops the archive (a failed write, a cancelled backup)
        // takes the partial copy with it: it sits beside the user's file.
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: tmp) } }
        guard let handle = FileHandle(forWritingAtPath: tmp.path) else {
            throw ArchiveError.ioFailure(String(localized: "could not open staging file"))
        }
        // Declared after the removal, so it runs first.
        defer { try? handle.close() }
        try handle.write(contentsOf: header)

        var recordCount = 0
        // The header is authenticated on every chunk, so no record can be
        // replayed into a different archive.
        let ad = [UInt8](header)
        var bytesWritten = header.count
        func writeRecord(_ type: RecordType, _ payload: Data, final: Bool) throws {
            if isCancelled?() == true { throw ArchiveError.cancelled }
            guard recordCount < maxRecords else { throw ArchiveError.tooManyRecords }
            guard payload.count <= maxChunkBytes else { throw ArchiveError.oversizedField }
            guard bytesWritten < Int(min(maxArchiveBytes, UInt64(Int.max))) else {
                throw ArchiveError.oversizedField
            }
            guard let sealed = push.push(message: [UInt8](payload),
                                         tag: final ? .FINAL : .MESSAGE,
                                         ad: ad) else {
                throw ArchiveError.wrongPassphraseOrCorrupt
            }
            var framed = Data([type.rawValue])
            framed.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Data($0) })
            framed.append(contentsOf: sealed)
            try handle.write(contentsOf: framed)
            bytesWritten += framed.count
            recordCount += 1
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var stamped = manifest
        stamped.attachmentCount = attachments.count
        try writeRecord(.manifest, try encoder.encode(stamped), final: false)

        // The database snapshot: SQLCipher-encrypted with the archive key, then
        // sliced into ≤1 MiB records inside the archive stream.
        let snapshot = try await databaseSnapshot(Self.snapshotKey(from: key))
        guard snapshot.count <= maxSnapshotBytes else { throw ArchiveError.oversizedField }
        let chunkCount = max(1, (snapshot.count + maxChunkBytes - 1) / maxChunkBytes)
        let snapshotHeader = SnapshotHeader(totalLength: snapshot.count, chunkCount: chunkCount)
        try writeRecord(.databaseSnapshot, try encoder.encode(snapshotHeader), final: false)
        var offset = 0
        while offset < snapshot.count {
            let end = min(offset + maxChunkBytes, snapshot.count)
            try writeRecord(.databaseChunk, snapshot.subdata(in: offset..<end), final: false)
            offset = end
        }

        for record in attachments {
            guard record.plaintextLength <= maxAttachmentBytes else {
                throw ArchiveError.oversizedField
            }
            try writeRecord(.attachmentMetadata, try encoder.encode(record), final: false)
        }

        for (index, record) in attachments.enumerated() {
            let bytes = try await attachmentReader(record)
            guard bytes.count == record.plaintextLength else {
                throw ArchiveError.badRecordOrder
            }
            var chunkOffset = 0
            while chunkOffset < bytes.count {
                let end = min(chunkOffset + maxChunkBytes, bytes.count)
                try writeRecord(.attachmentChunk, bytes.subdata(in: chunkOffset..<end), final: false)
                chunkOffset = end
            }
            progress?(index + 1, attachments.count)
        }
        try writeRecord(.end, Data(), final: true)
        try handle.synchronize()
        try handle.close()
        // The last moment to stop: nothing is at `destination` yet.
        if isCancelled?() == true { throw ArchiveError.cancelled }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
        committed = true
    }

    // MARK: - Stream reader

    /// Buffered, bounded reader over the sealed record stream. Each record is
    /// one secretstream chunk; `readExact` never allocates more than the
    /// declared record length plus its tag.
    final class RecordReader {
        let handle: FileHandle
        let pull: SecretStream.XChaCha20Poly1305.PullStream
        let ad: [UInt8]
        var finished = false
        var recordsRead = 0
        private var exhausted = false

        init(handle: FileHandle, pull: SecretStream.XChaCha20Poly1305.PullStream, ad: [UInt8]) {
            self.handle = handle
            self.pull = pull
            self.ad = ad
        }

        func readExact(_ count: Int) throws -> Data {
            guard count >= 0 else { throw ArchiveError.truncated }
            var out = Data()
            out.reserveCapacity(min(count, maxChunkBytes + 64))
            while out.count < count {
                guard let chunk = try handle.read(upToCount: count - out.count), !chunk.isEmpty else {
                    throw ArchiveError.truncated
                }
                out.append(chunk)
            }
            return out
        }

        /// Returns nil at the physical end of the stream. Validates the record
        /// framing and decrypts exactly one chunk.
        func next() throws -> (type: RecordType, payload: Data)? {
            if finished || exhausted { return nil }
            guard let frame = try? readExact(9), frame.count == 9 else {
                exhausted = true
                return nil
            }
            recordsRead += 1
            guard recordsRead <= maxRecords else { throw ArchiveError.tooManyRecords }
            guard let type = RecordType(rawValue: frame[frame.startIndex]) else {
                throw ArchiveError.unexpectedRecord(frame[frame.startIndex])
            }
            let declared = frame.subdata(in: 1..<9).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            // Guard the integer arithmetic before converting or allocating.
            guard declared <= UInt64(maxChunkBytes) else { throw ArchiveError.oversizedField }
            let length = Int(declared)
            let sealed = try readExact(length + SecretStream.XChaCha20Poly1305.ABytes)
            guard let (message, tag) = pull.pull(cipherText: [UInt8](sealed), ad: ad) else {
                throw ArchiveError.wrongPassphraseOrCorrupt
            }
            if tag == .FINAL {
                finished = true
                if type != .end { throw ArchiveError.badRecordOrder }
            }
            return (type, Data(message))
        }
    }

    /// Parsed stream header plus the derived archive key.
    struct OpenedArchive {
        var reader: RecordReader
        var archiveKey: Data
        var key: Bytes
    }

    static func openReader(at url: URL, passphrase: String) throws -> OpenedArchive {
        try openReader(at: url, sealing: .passphrase(passphrase))
    }

    /// The header profile byte of the file at `url`, or nil if it has no
    /// readable v2 header. Reads 28 bytes and derives nothing.
    static func profile(at url: URL) -> UInt8? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerLength), head.count >= headerLength,
              let parsed = try? parseHeader(head) else { return nil }
        return parsed.profile
    }

    static func openReader(at url: URL, sealing: Sealing) throws -> OpenedArchive {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= maxArchiveBytes else { throw ArchiveError.oversizedField }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchiveError.notAnArchive
        }
        let headerData = try handle.read(upToCount: maximumHeaderBytes) ?? Data()
        guard headerData.count >= headerLength else { throw ArchiveError.notAnArchive }
        let header = try parseHeader(headerData)
        // A file needs the kind of key it was sealed with; the other kind is
        // refused here, before the (slow) derivation.
        switch sealing {
        case .passphrase: guard header.profile == KDFProfile.argon2id64MiB3Ops.rawValue else {
            throw ArchiveError.wrongPassphraseOrCorrupt
        }
        case .deviceKey: guard header.profile == deviceKeyProfile else {
            throw ArchiveError.wrongPassphraseOrCorrupt
        }
        }
        // Trim the read-ahead back to the exact header boundary so record
        // framing starts where the writer left off.
        if headerData.count > headerLength {
            try handle.seek(toOffset: UInt64(headerLength))
        }
        let sodium = Sodium()
        let key = try deriveSealingKey(sealing, salt: header.salt)
        guard let pull = sodium.secretStream.xchacha20poly1305.initPull(
            secretKey: key, header: header.streamHeader) else {
            throw ArchiveError.wrongPassphraseOrCorrupt
        }
        let reader = RecordReader(handle: handle, pull: pull, ad: [UInt8](header.canonical))
        return OpenedArchive(reader: reader, archiveKey: Self.snapshotKey(from: key), key: key)
    }

    // MARK: - Inspection and full read

    struct Inspection: Sendable, Equatable {
        var manifest: Manifest
    }

    /// Reads only the manifest record.
    static func inspect(at url: URL, passphrase: String) throws -> Inspection {
        try inspect(at: url, sealing: .passphrase(passphrase))
    }

    static func inspect(at url: URL, sealing: Sealing) throws -> Inspection {
        let opened = try openReader(at: url, sealing: sealing)
        defer { try? opened.reader.handle.close() }
        guard let first = try opened.reader.next(), first.type == .manifest else {
            throw ArchiveError.badRecordOrder
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: first.payload) else {
            throw ArchiveError.wrongPassphraseOrCorrupt
        }
        return Inspection(manifest: manifest)
    }

    /// What a full read hands to its sink.
    enum StreamItem: Sendable {
        case databaseSnapshotHeader(SnapshotHeader)
        case databaseChunk(Data)
        case attachment(AttachmentRecord)
        case attachmentChunk(Data)
        case end
    }

    /// Streams the whole archive to `sink` in order. The manifest comes first.
    @discardableResult
    static func read(
        at url: URL,
        passphrase: String,
        sink: (StreamItem) async throws -> Void
    ) async throws -> Manifest {
        let opened = try openReader(at: url, passphrase: passphrase)
        defer { try? opened.reader.handle.close() }
        return try await read(opened: opened, sink: sink)
    }

    @discardableResult
    static func read(
        opened: OpenedArchive,
        sink: (StreamItem) async throws -> Void
    ) async throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest: Manifest?
        var snapshotHeader: SnapshotHeader?
        var snapshotChunks = 0
        var metadata: [AttachmentRecord] = []
        // Which metadata record the current attachment chunk belongs to.
        var attachmentIndex = 0
        var attachmentBytesSeen = 0
        var sawEnd = false

        while let record = try opened.reader.next() {
            switch record.type {
            case .manifest:
                guard manifest == nil else { throw ArchiveError.badRecordOrder }
                guard let decoded = try? decoder.decode(Manifest.self, from: record.payload) else {
                    throw ArchiveError.wrongPassphraseOrCorrupt
                }
                manifest = decoded
            case .databaseSnapshot:
                guard manifest != nil, snapshotHeader == nil else { throw ArchiveError.badRecordOrder }
                guard let decoded = try? decoder.decode(SnapshotHeader.self, from: record.payload),
                      decoded.chunkCount > 0,
                      decoded.totalLength >= 0,
                      decoded.totalLength <= maxSnapshotBytes else {
                    throw ArchiveError.oversizedField
                }
                snapshotHeader = decoded
                try await sink(.databaseSnapshotHeader(decoded))
            case .databaseChunk:
                guard let header = snapshotHeader, snapshotChunks < header.chunkCount else {
                    throw ArchiveError.badRecordOrder
                }
                snapshotChunks += 1
                try await sink(.databaseChunk(record.payload))
            case .attachmentMetadata:
                guard let header = snapshotHeader, snapshotChunks == header.chunkCount else {
                    throw ArchiveError.badRecordOrder
                }
                guard let decoded = try? decoder.decode(AttachmentRecord.self, from: record.payload) else {
                    throw ArchiveError.wrongPassphraseOrCorrupt
                }
                guard decoded.plaintextLength <= maxAttachmentBytes else {
                    throw ArchiveError.oversizedField
                }
                metadata.append(decoded)
                guard metadata.count <= maxRecords else { throw ArchiveError.tooManyRecords }
                try await sink(.attachment(decoded))
            case .attachmentChunk:
                // Chunks arrive grouped under their metadata record, in order.
                while attachmentIndex < metadata.count,
                      attachmentBytesSeen >= metadata[attachmentIndex].plaintextLength {
                    attachmentIndex += 1
                    attachmentBytesSeen = 0
                }
                guard attachmentIndex < metadata.count else { throw ArchiveError.badRecordOrder }
                attachmentBytesSeen += record.payload.count
                guard attachmentBytesSeen <= metadata[attachmentIndex].plaintextLength else {
                    throw ArchiveError.badRecordOrder
                }
                try await sink(.attachmentChunk(record.payload))
            case .end:
                sawEnd = true
                try await sink(.end)
            }
            if record.type == .end { break }
        }
        guard sawEnd else { throw ArchiveError.missingFinalTag }
        guard let manifest, let snapshotHeader, snapshotChunks == snapshotHeader.chunkCount else {
            throw ArchiveError.badRecordOrder
        }
        guard metadata.count == manifest.attachmentCount else { throw ArchiveError.badRecordOrder }
        return manifest
    }

    // MARK: - Key derivation

    static func deriveSealingKey(_ sealing: Sealing, salt: Data) throws -> Bytes {
        switch sealing {
        case .passphrase(let passphrase):
            return try deriveKey(passphrase: passphrase, salt: salt, profile: .argon2id64MiB3Ops)
        case .deviceKey(let restoreKey):
            guard salt.count == saltLength, restoreKey.count == 32 else { throw ArchiveError.notAnArchive }
            let sodium = Sodium()
            guard let key = sodium.genericHash.hash(
                message: [UInt8](salt) + Array(deviceKeyContext.utf8),
                key: [UInt8](restoreKey), outputLength: 32) else {
                throw ArchiveError.wrongPassphraseOrCorrupt
            }
            return key
        }
    }

    static func deriveKey(passphrase: String, salt: Data, profile: KDFProfile) throws -> Bytes {
        guard salt.count == saltLength else { throw ArchiveError.notAnArchive }
        let sodium = Sodium()
        let normalized = BackupPassphrasePolicy.normalized(passphrase)
        guard let key = sodium.pwHash.hash(
            outputLength: 32,
            passwd: [UInt8](normalized.utf8),
            salt: [UInt8](salt),
            opsLimit: profile.operations,
            memLimit: profile.memoryBytes,
            alg: profile.algorithm) else {
            throw ArchiveError.wrongPassphraseOrCorrupt
        }
        return key
    }

    /// The inner SQLCipher key for the database snapshot, derived from the
    /// archive key. Deterministic, so the reader can rebuild it from the
    /// passphrase alone.
    static func snapshotKey(from archiveKey: Bytes) -> Data {
        let sodium = Sodium()
        guard let digest = sodium.genericHash.hash(
            message: archiveKey + Array("mn.snapshot.v1".utf8), outputLength: 32) else {
            return Data(archiveKey.prefix(32))
        }
        return Data(digest)
    }

    // MARK: - Schema expectations for restore validation

    /// Confirms the expected tables and columns, and rejects unexpected
    /// triggers or views, on a restored database snapshot.
    static let expectedTables: [String: Set<String>] = [
        "patients": ["id", "first_name", "last_name", "date_of_birth", "amka"],
        "notes": ["id", "title", "content", "created_at", "updated_at"],
        "todo_items": ["id", "title", "is_completed", "created_at", "updated_at"],
        "calendar_events": ["id", "title", "start_date", "end_date"],
        "patient_files": ["id", "patient_id", "file_name", "storage_id"],
        "sync_destinations": ["id", "bridge_type", "calendar_identifier", "source_identifier"],
        "audit_logs": ["id", "timestamp", "action", "entity_type", "entity_id"]
    ]
}
