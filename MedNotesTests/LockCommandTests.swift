import AppKit
import XCTest

/// The app menu's Lock MedNotes command, read from the running app's own menu
/// bar. The test host is the MedNotes process, so `NSApp.mainMenu` is the real
/// menu SwiftUI built for `MedNotesCommands`. This is the in-process
/// counterpart to an AX-driven menu read: the live check needs Accessibility,
/// which the suite's environment may not grant.
@MainActor
final class LockCommandTests: XCTestCase {
    /// The item, found by its localised title so a Greek run still finds it.
    private func lockItem() throws -> (menu: NSMenu, index: Int, item: NSMenuItem) {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "the app must have a menu bar")
        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu,
                                    "the first menu must be the app menu")
        let title = String(localized: "Lock MedNotes")
        for (index, item) in appMenu.items.enumerated() where item.title == title {
            return (appMenu, index, item)
        }
        XCTFail("the app menu must carry \(title.debugDescription), got \(appMenu.items.enumerated().map { "\($0.offset):\($0.element.title)" })")
        throw XCTSkip("no Lock MedNotes item")
    }

    func testLockCommandExistsWithControlCommandL() throws {
        let (_, _, item) = try lockItem()
        XCTAssertEqual(item.keyEquivalent, "l")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .control])
    }

    /// It sits just below Settings…, as the plan placed it, and Settings…
    /// itself keeps the app-menu position the AX review scripts use.
    func testLockCommandSitsDirectlyAfterSettings() throws {
        let (menu, lockIndex, _) = try lockItem()
        let settingsIndex = try XCTUnwrap(
            menu.items.firstIndex { $0.keyEquivalent == "," },
            "Settings… (⌘,) must be in the app menu; got \(menu.items.enumerated().map { "\($0.offset):\($0.element.title)" })")
        XCTAssertGreaterThan(lockIndex, settingsIndex,
                             "Lock MedNotes must come after Settings…; menu order is \(menu.items.enumerated().map { "\($0.offset):\($0.element.title)" })")
        let between = menu.items[(settingsIndex + 1)..<lockIndex]
        XCTAssertTrue(between.allSatisfy { $0.isSeparatorItem },
                      "only a separator may sit between Settings… and Lock MedNotes, got \(between.map(\.title))")
        XCTAssertEqual(menu.items[settingsIndex].title, String(localized: "Settings…"),
                       "Settings… must keep its menu title")
    }

    /// No other command claims ⌃⌘L, and the store commands' own shortcuts are
    /// untouched.
    func testControlCommandLIsUniqueInTheMenuBar() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        var holders: [String] = []
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items
            where item.keyEquivalent == "l" && item.keyEquivalentModifierMask == [.command, .control] {
                holders.append(item.title)
            }
        }
        XCTAssertEqual(holders, [String(localized: "Lock MedNotes")])
    }

    /// In the test host the session never opens its store, so the command must
    /// be disabled rather than lock a session with nothing behind it.
    func testLockCommandIsDisabledWithoutAnOpenStore() throws {
        let (_, _, item) = try lockItem()
        XCTAssertFalse(item.isEnabled,
                       "Lock MedNotes must be disabled when the store is not available")
    }
}
