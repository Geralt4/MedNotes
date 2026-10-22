import AppKit
import Foundation
import Sodium

/// Rules for backup passphrases, enforced below the UI (the backup service
/// calls this too, so a UI regression cannot weaken the policy).
///
/// Generated passphrases are 24 Crockford Base32 characters (120 bits), grouped
/// for transcription. Custom passphrases must be Unicode NFC normalized and at
/// least 16 characters.
enum BackupPassphrasePolicy {
    static let generatedLength = 24
    static let minimumCustomLength = 16
    /// 32 characters, excluding I, L, O and U so a handwritten phrase is not
    /// ambiguous.
    private static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Applies Unicode NFC, the same normalization used when deriving the key.
    static func normalized(_ passphrase: String) -> String {
        passphrase.precomposedStringWithCanonicalMapping
    }

    /// Generates a 24-character Crockford Base32 passphrase, grouped as
    /// `XXXXX-XXXXX-XXXXX-XXXXX-X` for legibility.
    static func generate() -> String {
        let sodium = Sodium()
        var characters: [Character] = []
        while characters.count < generatedLength {
            guard let bytes = sodium.randomBytes.buf(length: 32) else { continue }
            for byte in bytes {
                // Rejection sampling keeps the distribution uniform: 224 is
                // 7 × 32, so every alphabet position gets the same count.
                guard byte < 224 else { continue }
                characters.append(crockfordAlphabet[Int(byte) % crockfordAlphabet.count])
                if characters.count == generatedLength { break }
            }
        }
        let raw = String(characters)
        return stride(from: 0, to: raw.count, by: 5).map { start in
            let startIndex = raw.index(raw.startIndex, offsetBy: start)
            let endIndex = raw.index(startIndex, offsetBy: min(5, raw.count - start))
            return String(raw[startIndex..<endIndex])
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
/// after 60 seconds if the clipboard still holds exactly that string.
@MainActor
final class PassphraseClipboard {
    static let shared = PassphraseClipboard()
    private var clearTask: Task<Void, Never>?
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func copy(_ passphrase: String, after seconds: TimeInterval = 60) {
        pasteboard.clearContents()
        pasteboard.setString(passphrase, forType: .string)
        clearTask?.cancel()
        clearTask = Task { [pasteboard] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if pasteboard.string(forType: .string) == passphrase {
                pasteboard.clearContents()
            }
        }
    }
}
