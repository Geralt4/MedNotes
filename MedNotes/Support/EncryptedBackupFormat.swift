import CommonCrypto
import CryptoKit
import Foundation

/// The container written by File › Back Up…: a small header and one
/// AES-256-GCM sealed box over the serialised backup directory.
/// See `docs/adr/0001-encryption-at-rest.md`.
///
/// Layout, version 1:
///
///     "MNBK" | version (1) | iterations (4, big-endian) | salt (16) | nonce (12) | ciphertext | tag (16)
///
/// The header is authenticated as additional data, so a tampered iteration
/// count or salt fails the same way a tampered payload does. Both frameworks
/// used are part of the system: no dependency is added.
enum EncryptedBackupFormat {
    static let fileExtension = "mednotesbackup"
    static let magic = Data("MNBK".utf8)
    static let version: UInt8 = 1
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    /// PBKDF2-HMAC-SHA256 rounds; the value is stored, so it can rise later.
    static let defaultIterations: UInt32 = 600_000

    enum FormatError: Error, LocalizedError, Equatable {
        case notAnArchive
        case unsupportedVersion(UInt8)
        case wrongPassphraseOrCorrupt
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return String(localized: "This file is not a MedNotes backup.")
            case .unsupportedVersion(let version):
                return String(localized: "This backup was written by a newer MedNotes (format \(Int(version))).")
            case .wrongPassphraseOrCorrupt:
                return String(localized: "The passphrase is wrong, or the backup file is damaged.")
            case .keyDerivationFailed:
                return String(localized: "The backup key could not be derived.")
            }
        }
    }

    static func seal(_ payload: Data, passphrase: String,
                     iterations: UInt32 = defaultIterations) throws -> Data {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max) })
        let nonce = AES.GCM.Nonce()
        let header = header(iterations: iterations, salt: salt, nonce: Data(nonce))
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: header)
        var archive = header
        archive.append(box.ciphertext)
        archive.append(box.tag)
        return archive
    }

    static func open(_ archive: Data, passphrase: String) throws -> Data {
        let headerLength = magic.count + 1 + 4 + saltLength + nonceLength
        guard archive.count >= headerLength + tagLength,
              archive.prefix(magic.count) == magic else {
            throw FormatError.notAnArchive
        }
        var offset = magic.count
        let version = archive[archive.startIndex + offset]
        guard version == Self.version else { throw FormatError.unsupportedVersion(version) }
        offset += 1
        let iterations = archive.subdata(in: (archive.startIndex + offset)..<(archive.startIndex + offset + 4))
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        let salt = archive.subdata(in: (archive.startIndex + offset)..<(archive.startIndex + offset + saltLength))
        offset += saltLength
        let nonceData = archive.subdata(in: (archive.startIndex + offset)..<(archive.startIndex + offset + nonceLength))
        offset += nonceLength
        let header = archive.prefix(headerLength)
        let body = archive.suffix(from: archive.startIndex + headerLength)
        let ciphertext = body.prefix(body.count - tagLength)
        let tag = body.suffix(tagLength)

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw FormatError.wrongPassphraseOrCorrupt
        }
    }

    private static func header(iterations: UInt32, salt: Data, nonce: Data) -> Data {
        var header = magic
        header.append(version)
        header.append(contentsOf: [
            UInt8(iterations >> 24 & 0xff), UInt8(iterations >> 16 & 0xff),
            UInt8(iterations >> 8 & 0xff), UInt8(iterations & 0xff)
        ])
        header.append(salt)
        header.append(nonce)
        return header
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphrase, passphrase.utf8.count,
                saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count)
        }
        guard status == kCCSuccess else { throw FormatError.keyDerivationFailed }
        return SymmetricKey(data: Data(derived))
    }
}
