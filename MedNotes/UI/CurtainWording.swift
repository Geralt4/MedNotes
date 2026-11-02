import Foundation

/// What the privacy curtain says.
///
/// The curtain covers the window in two different situations, and says which:
///
/// - **Locked.** The session is really locked: the store is closed and the keys
///   are gone. "Unlock" asks for Touch ID or the account password.
/// - **Hidden.** The app is only in the background and the store is still open.
///   The curtain hides the records, "Show" lifts it, and nothing is asked: it is
///   the same session, which has not been locked.
///
/// The button does the same thing in both (`AppSession.unlock()`, which lifts a
/// curtain over an open store without authenticating and unlocks a locked one);
/// only the words differ. The migration and the key recovery screens keep their
/// own text.
struct CurtainWording: Equatable {
    enum Situation: Equatable {
        case recovery, migrating, locked, hidden
    }

    let situation: Situation
    let title: String
    /// The line under the title. The curtain over Settings and sheets has none.
    let message: String
    /// The button's label; nil where the screen has its own controls instead.
    let button: String?
    let symbol: String

    /// Recovery and migration come first (they have their own screens), then a
    /// real lock; a curtain over an open store is the hidden app.
    static func situation(isLocked: Bool, isMigrating: Bool, needsRecovery: Bool) -> Situation {
        if needsRecovery { return .recovery }
        if isMigrating { return .migrating }
        return isLocked ? .locked : .hidden
    }

    static func wording(isLocked: Bool, isMigrating: Bool = false, needsRecovery: Bool = false) -> CurtainWording {
        switch situation(isLocked: isLocked, isMigrating: isMigrating, needsRecovery: needsRecovery) {
        case .recovery:
            return CurtainWording(
                situation: .recovery,
                title: String(localized: "The device key is missing"),
                message: String(localized: "Encrypted data exists, but the Keychain item that holds its key is gone. Restore a portable backup to recover. MedNotes will not start an empty database over this data."),
                button: nil, symbol: "exclamationmark.triangle.fill")
        case .migrating:
            return CurtainWording(
                situation: .migrating,
                title: String(localized: "Encrypting MedNotes"),
                message: String(localized: "MedNotes is converting this store to an encrypted one. Make and verify a backup first; the wizard will not touch your data until it has."),
                button: nil, symbol: "lock.fill")
        case .locked:
            return CurtainWording(
                situation: .locked,
                title: String(localized: "MedNotes is locked"),
                message: String(localized: "Touch ID or your account password unlocks MedNotes."),
                button: String(localized: "Unlock"), symbol: "lock.fill")
        case .hidden:
            return CurtainWording(
                situation: .hidden,
                title: String(localized: "MedNotes is hidden"),
                message: String(localized: "MedNotes is hidden while it is in the background. Choose Show to bring it back."),
                button: String(localized: "Show"), symbol: "eye.slash.fill")
        }
    }

    /// The curtain over Settings, Activity and sheets. Migration and recovery
    /// run in the main window only; if one is under way, those windows are
    /// covered as they always were: locked, with Unlock.
    static func coverWording(isLocked: Bool, isMigrating: Bool, needsRecovery: Bool) -> CurtainWording {
        wording(isLocked: isLocked || isMigrating || needsRecovery)
    }

    @MainActor
    static func wording(for session: AppSession) -> CurtainWording {
        wording(isLocked: session.isLocked, isMigrating: session.isMigrating, needsRecovery: session.needsRecovery)
    }
}
