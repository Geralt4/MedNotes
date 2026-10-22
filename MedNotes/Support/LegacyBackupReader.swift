import CommonCrypto
import CryptoKit
import Foundation

/// Read-only support for version-1 `.mednotesbackup` archives, with the
/// containment the original format lacked.
///
/// The original (see `EncryptedBackupFormat`) sealed a serialized `FileWrapper`
/// tree. That made path separators, nested directories and symbolic links
/// representable. This reader keeps the crypto identical but never calls
/// `FileWrapper.write`: the header is validated first, the archive size and
/// iteration count are bounded, then each file is extracted one at a time with
/// no-follow and exclusive-create semantics.
enum LegacyBackupReader {
    static let magic = Data("MNBK".utf8)
    static let version: UInt8 = 1
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    static let headerLength = magic.count + 1 + 4 + saltLength + nonceLength

    /// PBKDF2-HMAC-SHA256 bounds. A production v1 archive is within this range;
    /// anything outside is rejected before the KDF runs.
    static let iterationRange: ClosedRange<UInt32> = 100_000...2_000_000
    static let maxArchiveBytes: UInt64 = BackupArchiveV2.maxV1ArchiveBytes
    static let maxEntries = 10_000
    static let maxPathDepth = 32
    static let maxEntryBytes = 512 * 1024 * 1024

    enum LegacyError: Error, LocalizedError, Equatable {
        case notAnArchive
        case unsupportedVersion(UInt8)
        case wrongPassphraseOrCorrupt
        case iterationsOutOfRange(UInt32)
        case archiveTooLarge
        case tooManyEntries
        case unsafeEntryName(String)
        case pathTooDeep(String)
        case nonRegularEntry(String)
        case duplicateEntry(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return String(localized: "This file is not a MedNotes backup.")
            case .unsupportedVersion(let v):
                return String(localized: "This backup was written by a newer MedNotes (format \(Int(v))).")
            case .wrongPassphraseOrCorrupt:
                return String(localized: "The passphrase is wrong, or the backup file is damaged.")
            case .iterationsOutOfRange(let value):
                return String(localized: "The backup's key-derivation count (\(value)) is outside the accepted range.")
            case .archiveTooLarge:
                return String(localized: "This backup is larger than the 1 GiB the legacy format can be opened safely.")
            case .tooManyEntries:
                return String(localized: "The backup contains too many files to extract safely.")
            case .unsafeEntryName(let name):
                return String(localized: "The backup contains an unsafe file name (\(name)).")
            case .pathTooDeep(let name):
                return String(localized: "The backup nests files too deeply (\(name)).")
            case .nonRegularEntry(let name):
                return String(localized: "The backup contains a symbolic link or non-regular file (\(name)).")
            case .duplicateEntry(let name):
                return String(localized: "The backup contains the same file twice (\(name)).")
            case .extractionFailed(let detail):
                return String(localized: "The backup could not be extracted: \(detail)")
            }
        }
    }

    struct Entry: Sendable {
        var relativePath: String
        var data: Data
    }

    struct Contents: Sendable {
        var entries: [Entry]
        /// The `manifest.json` payload, parsed leniently by the service.
        var manifestData: Data?
    }

    /// Validates the fixed header without deriving a key: the caller can show
    /// the size and version before asking for a passphrase.
    static func probeHeader(at url: URL) throws -> (iterations: UInt32, salt: Data, nonce: Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= maxArchiveBytes else { throw LegacyError.archiveTooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LegacyError.notAnArchive
        }
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: headerLength), head.count == headerLength,
              head.prefix(magic.count) == magic else {
            throw LegacyError.notAnArchive
        }
        var offset = magic.count
        let version = head[head.startIndex + offset]; offset += 1
        guard version == Self.version else { throw LegacyError.unsupportedVersion(version) }
        let iterations = head.subdata(in: offset..<(offset + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        guard iterationRange.contains(iterations) else {
            throw LegacyError.iterationsOutOfRange(iterations)
        }
        let salt = head.subdata(in: offset..<(offset + saltLength)); offset += saltLength
        let nonce = head.subdata(in: offset..<(offset + nonceLength))
        return (iterations, salt, nonce)
    }

    /// Opens the archive and returns its entries as in-memory data. No file is
    /// written here; `extract` is the only writer, and it enforces the
    /// no-follow/exclusive-create contract per entry.
    static func open(at url: URL, passphrase: String) throws -> Contents {
        let header = try probeHeader(at: url)
        guard let handle = try? FileHandle(forReadingFrom: url), let archive = try handle.readToEnd() else {
            throw LegacyError.notAnArchive
        }
        try? handle.close()
        guard archive.count >= headerLength + tagLength else { throw LegacyError.notAnArchive }
        let headerBytes = archive.prefix(headerLength)
        let body = archive.suffix(from: archive.startIndex + headerLength)
        let ciphertext = body.prefix(body.count - tagLength)
        let tag = body.suffix(tagLength)

        let key = try deriveKey(passphrase: passphrase, salt: header.salt, iterations: header.iterations)
        let payload: Data
        do {
            let nonce = try AES.GCM.Nonce(data: header.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            payload = try AES.GCM.open(box, using: key, authenticating: headerBytes)
        } catch {
            throw LegacyError.wrongPassphraseOrCorrupt
        }
        return try parseTree(payload)
    }

    /// Extracts entries into `directory` one file at a time. Every name is
    /// re-validated here; `O_NOFOLLOW | O_EXCL` makes a symlink planted by a
    /// concurrent process fail instead of being written through.
    static func extract(_ contents: Contents, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var seen = Set<String>()
        for entry in contents.entries {
            guard seen.insert(entry.relativePath).inserted else {
                throw LegacyError.duplicateEntry(entry.relativePath)
            }
            let destination = directory.appendingPathComponent(entry.relativePath)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else {
                throw LegacyError.extractionFailed(String(localized: "could not create \(entry.relativePath)"))
            }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: entry.data)
            try file.close()
        }
    }

    // MARK: - Tree parsing

    /// The v1 payload is a binary plist from `FileWrapper.serializedRepresentation`.
    /// Rather than rehydrating it, the plist is walked as data and each
    /// `NSFileWrapper` node is inspected for the keys that make it dangerous.
    private static func parseTree(_ payload: Data) throws -> Contents {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: payload, options: [], format: nil) as? [String: Any] else {
            throw LegacyError.wrongPassphraseOrCorrupt
        }
        var entries: [Entry] = []
        var manifestData: Data?
        var count = 0
        var names = Set<String>()

        func walk(_ node: [String: Any], prefix: String, depth: Int) throws {
            guard depth <= maxPathDepth else { throw LegacyError.pathTooDeep(prefix) }
            // A symbolic link is a file wrapper with a link destination and no
            // regular-file contents.
            if node["NSFileWrapperLinkDestination"] != nil {
                throw LegacyError.nonRegularEntry(prefix.isEmpty ? String(localized: "link") : prefix)
            }
            let isDirectory = (node["NSFileWrapperDirectory"] as? Bool) ?? false
            let name = node["NSFileWrapperPreferredFilename"] as? String
                ?? node["NSFileWrapperFilename"] as? String ?? ""
            let relative = prefix.isEmpty ? name : (prefix + "/" + name)
            if !name.isEmpty {
                try validateName(name, relative: relative)
            }

            if isDirectory {
                let children = node["NSFileWrapperChildren"] as? [[String: Any]] ?? []
                for child in children {
                    try walk(child, prefix: relative, depth: depth + 1)
                }
                return
            }
            if let contents = node["NSFileWrapperContents"] as? Data {
                count += 1
                guard count <= maxEntries else { throw LegacyError.tooManyEntries }
                guard contents.count <= maxEntryBytes else {
                    throw LegacyError.extractionFailed(String(localized: "\(relative) is too large"))
                }
                guard names.insert(relative).inserted else {
                    throw LegacyError.duplicateEntry(relative)
                }
                if relative == "manifest.json" || relative.hasSuffix("/manifest.json") {
                    manifestData = contents
                }
                entries.append(Entry(relativePath: relative, data: contents))
            }
        }

        if let root = plist["NSFileWrapperDirectory"] as? Bool, root {
            let children = plist["NSFileWrapperChildren"] as? [[String: Any]] ?? []
            for child in children {
                try walk(child, prefix: "", depth: 0)
            }
        } else {
            try walk(plist, prefix: "", depth: 0)
        }
        return Contents(entries: entries, manifestData: manifestData)
    }

    private static func validateName(_ name: String, relative: String) throws {
        guard !name.isEmpty,
              name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.contains("\u{0}"),
              !name.hasPrefix(".") else {
            throw LegacyError.unsafeEntryName(relative.isEmpty ? name : relative)
        }
        guard !relative.contains("..") else { throw LegacyError.unsafeEntryName(relative) }
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let normalized = BackupPassphrasePolicy.normalized(passphrase)
        let status = salt.withUnsafeBytes { saltBytes -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                normalized, normalized.utf8.count,
                saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count)
        }
        guard status == kCCSuccess else { throw LegacyError.wrongPassphraseOrCorrupt }
        return SymmetricKey(data: Data(derived))
    }
}
