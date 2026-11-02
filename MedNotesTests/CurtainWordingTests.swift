import XCTest
@testable import MedNotes

/// What the privacy curtain says. When the session is really locked it says
/// "locked" and offers "Unlock"; when the app is only in the background and the
/// store is still open it says "hidden" and offers "Show". What the button does
/// is unchanged (`SecurityTests.testUnlockWhileOnlyObscuredKeepsTheOpenStore`).
///
/// The words are tested where they are chosen (`CurtainWording`), which both
/// curtain views use. The drawn views cannot be read in the test host: SwiftUI's
/// text is not an AppKit view, the accessibility tree of an off-screen window is
/// empty (and must not be walked in-process), and a pixel read does not see the
/// overlay of a window that is not on screen.
@MainActor
final class CurtainWordingTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.CurtainWording"
    private var roots: [DataRoot] = []

    override func setUp() {
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDown() {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    // MARK: - The wording

    func testALockedSessionSaysLockedAndOffersUnlock() {
        let wording = CurtainWording.wording(isLocked: true)
        XCTAssertEqual(wording.situation, .locked)
        XCTAssertEqual(wording.title, String(localized: "MedNotes is locked"))
        XCTAssertEqual(wording.button, String(localized: "Unlock"))
        XCTAssertEqual(wording.message, String(localized: "Touch ID or your account password unlocks MedNotes."))
    }

    func testAnAppOnlyInTheBackgroundSaysHiddenAndOffersShow() {
        let wording = CurtainWording.wording(isLocked: false)
        XCTAssertEqual(wording.situation, .hidden)
        XCTAssertEqual(wording.title, String(localized: "MedNotes is hidden"))
        XCTAssertEqual(wording.button, String(localized: "Show"))
        XCTAssertFalse(wording.title.localizedCaseInsensitiveContains("locked"))
        XCTAssertFalse(wording.message.localizedCaseInsensitiveContains("unlock"))
        XCTAssertFalse(wording.message.localizedCaseInsensitiveContains("touch id"),
                       "showing a hidden app asks for nothing")
        XCTAssertNotEqual(wording.symbol, CurtainWording.wording(isLocked: true).symbol)
    }

    /// Nothing but the background case changed: recovery and migration keep their
    /// own text, and win over a lock.
    func testRecoveryAndMigrationKeepTheirOwnText() {
        let recovery = CurtainWording.wording(isLocked: true, isMigrating: true, needsRecovery: true)
        XCTAssertEqual(recovery.situation, .recovery)
        XCTAssertEqual(recovery.title, String(localized: "The device key is missing"))
        XCTAssertNil(recovery.button)
        let migrating = CurtainWording.wording(isLocked: false, isMigrating: true)
        XCTAssertEqual(migrating.situation, .migrating)
        XCTAssertEqual(migrating.title, String(localized: "Encrypting MedNotes"))
        XCTAssertNil(migrating.button)
    }

    /// The curtain over Settings, Activity and sheets keeps saying "locked" while
    /// a migration or a key recovery is under way (a store that is not open is
    /// not "hidden").
    func testTheCoverSaysLockedDuringMigrationAndRecoveryAndHiddenOtherwise() {
        func cover(locked: Bool, migrating: Bool = false, recovery: Bool = false) -> CurtainWording.Situation {
            CurtainWording.coverWording(isLocked: locked, isMigrating: migrating, needsRecovery: recovery).situation
        }
        XCTAssertEqual(cover(locked: false), .hidden)
        XCTAssertEqual(cover(locked: true), .locked)
        XCTAssertEqual(cover(locked: false, migrating: true), .locked)
        XCTAssertEqual(cover(locked: false, recovery: true), .locked)
        XCTAssertNotNil(CurtainWording.coverWording(isLocked: false, isMigrating: true, needsRecovery: false).button)
    }

    // MARK: - The session

    func testTheSessionIsHiddenInTheBackgroundAndLockedWhenLocked() async throws {
        let session = try await makeSession()
        XCTAssertEqual(CurtainWording.wording(for: session).situation, .hidden, "an open store, no lock")

        session.appDidResignActive()
        XCTAssertTrue(session.isObscured)
        XCTAssertFalse(session.isLocked)
        XCTAssertEqual(CurtainWording.wording(for: session).title, String(localized: "MedNotes is hidden"))
        XCTAssertEqual(CurtainWording.wording(for: session).button, String(localized: "Show"))

        await session.lockNow(reason: "screen")
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(CurtainWording.wording(for: session).title, String(localized: "MedNotes is locked"))
        XCTAssertEqual(CurtainWording.wording(for: session).button, String(localized: "Unlock"))
    }

    // MARK: - The behaviour

    /// Showing a hidden app does what it did: it lifts the curtain without
    /// asking for Touch ID, and the store stays open and unlocked.
    func testShowLiftsTheCurtainWithoutLockingOrReopeningTheStore() async throws {
        let session = try await makeSession()
        let open = try XCTUnwrap(session.store)
        session.appDidResignActive()

        await session.unlock()

        XCTAssertFalse(session.isObscured)
        XCTAssertFalse(session.isLocked)
        XCTAssertTrue(session.store === open)
    }
}
