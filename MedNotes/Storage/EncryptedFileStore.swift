import Foundation
import Sodium

/// Encrypted attachment storage.
///
/// Files live under `Attachments/<storageID>` where `storageID` is a fresh
/// random UUID unconnected to the patient, and are encrypted with
/// `secretstream_xchacha20poly1305` in 1 MiB authenticated chunks. The plain
/// container is:
///
///     "MNAF" | version (1) | salt (16) | stream header (24) | chunks | final tag
///
/// Every chunk carries its own Poly1305 tag, so a flipped bit, a truncated
/// file, a reordered chunk or a missing final tag all fail authentication.
/// The true length is encrypted in the first chunk; the payload is padded to
/// the next 64 KiB boundary so the ciphertext length does not leak the exact
/// plaintext size.
///
/// Plaintext is materialised only in memory. `openExternally` is the single
/// deliberate exception: it writes a 0600 temporary file for the caller to
/// hand to another application, and tracks it for cleanup.
actor EncryptedFileStore: AttachmentStore {
    static let magic = Data("MNAF".utf8)
    static let version: UInt8 = 1
    static let saltLength = 16
    static let chunkSize = 1 << 20
    static let paddingBlock = 64 << 10

    enum StoreError: Error, LocalizedError, Equatable {
        case notAnAttachment
        case unsupportedVersion(UInt8)
        case corruptOrWrongKey
        case tooLarge
        case maliciousIdentifier
        case invalidLength
        case unreadable
        case externalCopyFailed

        var errorDescription: String? {
            switch self {
            case .notAnAttachment:
                return String(localized: "This file is not an encrypted MedNotes attachment.")
            case .unsupportedVersion(let v):
                return String(localized: "This attachment was written by a newer MedNotes (format \(Int(v))).")
            case .corruptOrWrongKey:
                return String(localized: "The attachment is damaged, or its key is wrong.")
            case .tooLarge:
                return String(localized: "The attachment is too large to open safely.")
            case .maliciousIdentifier:
                return String(localized: "Refusing to use an unsafe storage identifier.")
            case .invalidLength:
                return String(localized: "The attachment's length header is invalid.")
            case .unreadable:
                return String(localized: "The attachment file couldn't be read. Check that it still exists and that you have permission to open it.")
            case .externalCopyFailed:
                return String(localized: "The attachment couldn't be opened because its temporary copy couldn't be saved. Free up disk space or check that the folder is writable, then try again.")
            }
        }
    }

    private let root: URL
    private let key: Data
    /// Where `openExternally` writes. The app's store gets its data root's
    /// folder; a store given none (a staging store, a test's) writes to a
    /// folder of its own, never the app's.
    private let externalCopiesURL: URL
    private var openTemporaries: Set<URL> = []

    init(root: URL, key: Data, externalCopiesURL: URL? = nil) throws {
        guard key.count == 32 else { throw KeyManagerError.invalidKeyLength(key.count) }
        self.root = root
        self.key = key
        self.externalCopiesURL = externalCopiesURL ?? DataRoot.scopedExternalCopiesURL(for: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Identifier safety

    /// Storage identifiers are generated here and only here: a random UUID.
    /// Anything that is not exactly a UUID is refused, which makes path
    /// traversal, separators and symlink names unrepresentable.
    static func newStorageID() -> String {
        UUID().uuidString.lowercased()
    }

    static func isSafeStorageID(_ raw: String) -> Bool {
        guard let uuid = UUID(uuidString: raw) else { return false }
        return uuid.uuidString.lowercased() == raw.lowercased()
    }

    /// Per-file key derivation: the first 64 bits of the random salt become
    /// the KDF index, so two files do not share a keystream under the same
    /// store key. (The secretstream header, random for every file, keeps them
    /// apart as well.)
    private func streamKey(salt: Data) -> Bytes? {
        let index = salt.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let sodium = Sodium()
        return sodium.keyDerivation.derive(
            secretKey: [UInt8](key), index: index, length: 32, context: StoreKeyContext.attachments)
    }

    nonisolated func url(for storageID: String) throws -> URL {
        guard Self.isSafeStorageID(storageID) else { throw StoreError.maliciousIdentifier }
        return root.appendingPathComponent(storageID, isDirectory: false)
    }

    // MARK: - Encryption

    /// Encrypts `plaintext` and writes it atomically under a fresh storage ID.
    /// The temporary file is created with 0600 permissions; the final rename
    /// is atomic, so a crash never leaves a partially written attachment.
    @discardableResult
    func store(_ plaintext: Data, storageID: String? = nil) throws -> String {
        let id = storageID ?? Self.newStorageID()
        guard Self.isSafeStorageID(id) else { throw StoreError.maliciousIdentifier }
        let destination = try url(for: id)

        let sodium = Sodium()
        // An empty salt would make every caller derive the same stream key and
        // would write a container whose header cannot be read back.
        guard let saltBytes = sodium.randomBytes.buf(length: Self.saltLength) else {
            throw StoreError.corruptOrWrongKey
        }
        let salt = Data(saltBytes)
        guard let streamKey = streamKey(salt: salt),
              let push = sodium.secretStream.xchacha20poly1305.initPush(secretKey: streamKey) else {
            throw StoreError.corruptOrWrongKey
        }

        var payload = Data()
        var lengthHeader = withUnsafeBytes(of: UInt64(plaintext.count).bigEndian) { Data($0) }
        lengthHeader.append(salt)
        payload.append(lengthHeader)
        payload.append(plaintext)
        // Pad to the next 64 KiB boundary. libsodium's padding helper writes a
        // 16-bit length prefix; the true length is already encrypted above, so
        // a simple zero fill to the boundary is enough and cheaper.
        let padded = ((payload.count + Self.paddingBlock - 1) / Self.paddingBlock) * Self.paddingBlock
        payload.append(Data(repeating: 0, count: max(0, padded - payload.count)))

        var output = Data()
        output.append(Self.magic)
        output.append(Self.version)
        output.append(salt)
        output.append(contentsOf: push.header())

        var offset = 0
        while offset < payload.count {
            let end = min(offset + Self.chunkSize, payload.count)
            let chunk = [UInt8](payload[offset..<end])
            let tag: SecretStream.XChaCha20Poly1305.Tag = end == payload.count ? .FINAL : .MESSAGE
            guard let sealed = push.push(message: chunk, tag: tag) else {
                throw StoreError.corruptOrWrongKey
            }
            output.append(contentsOf: sealed)
            offset = end
        }

        let tmp = destination.appendingPathExtension("staging-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StoreError.corruptOrWrongKey }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: output)
        try handle.synchronize()
        try handle.close()
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        return id
    }

    /// Decrypts a whole attachment into memory. Used by previews and by the
    /// digest verifier; nothing writes plaintext to disk on this path.
    func read(storageID: String) throws -> Data {
        let source = try url(for: storageID)
        guard let data = try? Data(contentsOf: source) else { throw StoreError.unreadable }
        return try decrypt(data)
    }

    func decrypt(_ container: Data) throws -> Data {
        let minimumHeader = Self.magic.count + 1 + Self.saltLength
            + SecretStream.XChaCha20Poly1305.HeaderBytes
        guard container.count >= minimumHeader else { throw StoreError.notAnAttachment }
        guard container.prefix(Self.magic.count) == Self.magic else { throw StoreError.notAnAttachment }
        var offset = Self.magic.count
        let version = container[container.startIndex + offset]
        guard version == Self.version else { throw StoreError.unsupportedVersion(version) }
        offset += 1
        let salt = container.subdata(in: offset..<(offset + Self.saltLength))
        offset += Self.saltLength
        let header = [UInt8](container.subdata(in: offset..<(offset + SecretStream.XChaCha20Poly1305.HeaderBytes)))
        offset += SecretStream.XChaCha20Poly1305.HeaderBytes

        let sodium = Sodium()
        guard let streamKey = streamKey(salt: salt),
              let pull = sodium.secretStream.xchacha20poly1305.initPull(secretKey: streamKey, header: header) else {
            throw StoreError.corruptOrWrongKey
        }

        var plaintext = Data()
        var sawFinal = false
        var firstChunk: Data?
        while offset < container.count {
            let end = min(offset + Self.chunkSize + SecretStream.XChaCha20Poly1305.ABytes, container.count)
            let chunk = [UInt8](container[offset..<end])
            guard let (message, tag) = pull.pull(cipherText: chunk) else {
                throw StoreError.corruptOrWrongKey
            }
            if firstChunk == nil { firstChunk = Data(message) }
            plaintext.append(contentsOf: message)
            offset = end
            if tag == .FINAL { sawFinal = true; break }
        }
        // Nothing may follow the final chunk: bytes appended to the container
        // are a change the tags do not cover.
        guard sawFinal, offset == container.count else { throw StoreError.corruptOrWrongKey }

        // Unwrap the encrypted length header and drop the padding.
        guard let first = firstChunk, first.count >= 8 + Self.saltLength else {
            throw StoreError.invalidLength
        }
        let length = first.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length <= UInt64(plaintext.count) else { throw StoreError.invalidLength }
        let start = 8 + Self.saltLength
        let end = start + Int(length)
        guard end <= plaintext.count else { throw StoreError.invalidLength }
        return plaintext.subdata(in: start..<end)
    }

    /// BLAKE2b digest over the decrypted bytes, for the DB's content_digest.
    nonisolated func digest(of plaintext: Data) -> String {
        Self.digest(of: plaintext)
    }

    nonisolated static func digest(of plaintext: Data) -> String {
        let sodium = Sodium()
        guard let hash = sodium.genericHash.hash(message: [UInt8](plaintext), outputLength: 32) else {
            return ""
        }
        return Data(hash).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Removal

    func remove(storageID: String) throws {
        let target = try url(for: storageID)
        try? FileManager.default.removeItem(at: target)
    }

    /// Removes what no database row refers to: half-written `.staging-` files
    /// and attachment objects whose save never committed (a crash between the
    /// file write and the metadata commit). Run once when a store opens, before
    /// anything can save, with every referenced ID lowercased. Names that are
    /// not storage IDs are left alone, and so is anything younger than
    /// `minimumAge`, which only gives a save in flight time to commit.
    ///
    /// When the database references no attachment at all, only half-written
    /// staging files go. Every stored object would otherwise count as an
    /// orphan, and age does not protect them: a database that was lost or
    /// opened empty beside a full folder would cost the user every file that
    /// is still recoverable.
    func sweepOrphans(referenced: Set<String>, minimumAge: TimeInterval = 3600) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        let cutoff = Date().addingTimeInterval(-minimumAge)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            guard modified <= cutoff else { continue }
            let name = entry.lastPathComponent
            let isStaging = name.contains(".staging-")
            let isOrphan = !referenced.isEmpty
                && Self.isSafeStorageID(name) && !referenced.contains(name.lowercased())
            guard isStaging || isOrphan else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Controlled external opening

    /// Writes a decrypted copy to a 0600 temporary file, registers it for
    /// cleanup, and returns its URL. The caller (UI) must have shown the
    /// disclosure first; nothing else in the app calls this.
    func openExternally(storageID: String, preferredName: String) throws -> URL {
        let data = try read(storageID: storageID)
        let directory = externalCopiesURL
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.externalCopyFailed
        }
        var safeName = preferredName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "_")
        // The copy's name gets a 37-byte UUID prefix, so keep the name under the
        // 255-byte file-name limit. Trim from the front so the extension stays.
        while safeName.utf8.count > 200 { safeName.removeFirst() }
        let file = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StoreError.externalCopyFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw StoreError.externalCopyFailed
        }
        openTemporaries.insert(file)
        return file
    }

    /// Removes every plaintext temporary this store produced. Called on lock,
    /// on focus loss and on app exit.
    func clearExternalTemporaries() {
        for url in openTemporaries {
            try? FileManager.default.removeItem(at: url)
        }
        openTemporaries.removeAll()
    }

    /// Removes every copy in `directory`, leftovers from a previous process
    /// among them: a data root's `externalCopiesURL`, never a guess, so a
    /// test's lock cannot empty the app's folder. A root's own folder goes
    /// too once it is empty; the app's stays, as it always has.
    nonisolated static func purgeOrphanedTemporaries(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry)
        }
        if directory.standardizedFileURL != DataRoot.appExternalCopiesURL.standardizedFileURL {
            rmdir(directory.path)
        }
    }
}
