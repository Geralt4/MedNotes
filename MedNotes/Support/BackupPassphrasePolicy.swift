import AppKit
import Foundation
import Security

/// Rules for backup passphrases, enforced below the UI (the backup service
/// calls this too, so a UI regression cannot weaken the policy).
///
/// A generated passphrase is 28 characters from a 30-character alphabet
/// (about 137 bits), in seven groups of four, drawn from the system's secure
/// random source. The alphabet leaves out every character that is easy to
/// confuse when it is written down: no 0 or O, no 1, I or l. Custom
/// passphrases must be Unicode NFC normalized and at least 16 characters.
enum BackupPassphrasePolicy {
    static let generatedGroups = 7
    static let generatedGroupLength = 4
    static var generatedLength: Int { generatedGroups * generatedGroupLength }
    static let minimumCustomLength = 16
    /// Crockford's Base32 (which already leaves out I, L, O and U) without
    /// the digits 0 and 1, so nothing in it looks like another character.
    static let generatedAlphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The strength of a generated passphrase, in bits.
    static var generatedBits: Double {
        Double(generatedLength) * log2(Double(generatedAlphabet.count))
    }

    /// Applies Unicode NFC, the same normalization used when deriving the key.
    static func normalized(_ passphrase: String) -> String {
        passphrase.precomposedStringWithCanonicalMapping
    }

    enum GenerateError: Error {
        /// The system's random source failed. Nothing weaker is used instead.
        case randomUnavailable
    }

    /// Random bytes from the system's secure random source.
    static func systemRandomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw GenerateError.randomUnavailable
        }
        return bytes
    }

    /// A new passphrase, `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`. `randomBytes` is
    /// the source of randomness; only a test passes another.
    static func generate(randomBytes: (Int) throws -> [UInt8] = systemRandomBytes) throws -> String {
        let alphabetSize = generatedAlphabet.count
        // Rejection sampling keeps every character equally likely: only bytes
        // below the largest multiple of the alphabet size are used.
        let usable = 256 - (256 % alphabetSize)
        var characters: [Character] = []
        var draws = 0
        while characters.count < generatedLength {
            draws += 1
            // Practically unreachable (the odds of rejecting this many bytes in
            // a row are nil); it stops a broken source from looping forever.
            guard draws <= 64 else { throw GenerateError.randomUnavailable }
            for byte in try randomBytes(64) where Int(byte) < usable {
                characters.append(generatedAlphabet[Int(byte) % alphabetSize])
                if characters.count == generatedLength { break }
            }
        }
        return stride(from: 0, to: generatedLength, by: generatedGroupLength).map { start in
            String(characters[start..<start + generatedGroupLength])
        }.joined(separator: "-")
    }

    /// Returns nil when acceptable, otherwise a localized reason. Validation
    /// runs on the normalized form.
    static func validate(_ passphrase: String) -> String? {
        let normalized = normalized(passphrase)
        if normalized.count < minimumCustomLength {
            return String(localized: "The passphrase must be at least 16 characters.")
        }
        return nil
    }

    static func isAcceptable(_ passphrase: String) -> Bool {
        validate(passphrase) == nil
    }
}

/// Clipboard hygiene for generated passphrases: a copied passphrase is cleared
/// after 60 seconds, or when the app quits, if the clipboard still holds
/// exactly that string.
@MainActor
final class PassphraseClipboard {
    static let shared = PassphraseClipboard()
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private var clearTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var lastCopied: String?
    private let pasteboard: NSPasteboard
    private let notificationCenter: NotificationCenter

    init(pasteboard: NSPasteboard = .general, notificationCenter: NotificationCenter = .default) {
        self.pasteboard = pasteboard
        self.notificationCenter = notificationCenter
    }

    deinit {
        if let terminationObserver { notificationCenter.removeObserver(terminationObserver) }
    }

    func copy(_ passphrase: String, after seconds: TimeInterval = 60) {
        pasteboard.clearContents()
        pasteboard.setString(passphrase, forType: .string)
        // Clipboard history tools honour these markers: the passphrase is
        // confidential, and it is about to be replaced by the clear task.
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)
        lastCopied = passphrase
        // The minute below runs in this process: quitting inside it would leave
        // the passphrase on the clipboard, so quitting clears it too.
        if terminationObserver == nil {
            terminationObserver = notificationCenter.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearIfStillHeld() }
            }
        }
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearIfStillHeld()
        }
    }

    /// Clears the clipboard if it still holds the passphrase that was copied:
    /// whatever the user copied since is theirs.
    private func clearIfStillHeld() {
        defer { lastCopied = nil }
        guard let lastCopied, pasteboard.string(forType: .string) == lastCopied else { return }
        pasteboard.clearContents()
    }
}
