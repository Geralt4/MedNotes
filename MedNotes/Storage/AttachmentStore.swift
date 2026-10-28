import Foundation

/// Attachment storage abstraction so the service layer does not depend on a
/// crypto module. The production implementation is `EncryptedFileStore`.
protocol AttachmentStore: Sendable {
    /// Encrypts and writes `plaintext`, returning its opaque storage ID.
    /// When `storageID` is supplied, the existing file is replaced.
    func store(_ plaintext: Data, storageID: String?) async throws -> String
    /// Decrypts the whole attachment into memory.
    func read(storageID: String) async throws -> Data
    /// Removes an attachment by storage ID.
    func remove(storageID: String) async throws
    /// Digest of plaintext bytes, as recorded in `patient_files.content_digest`.
    func digest(of plaintext: Data) -> String
    /// Writes a decrypted 0600 temporary copy for the one deliberate
    /// "Open Externally" disclosure. Callers must show the disclosure first.
    func openExternally(storageID: String, preferredName: String) async throws -> URL
    /// Removes every plaintext temporary this store produced.
    func clearExternalTemporaries() async
}
