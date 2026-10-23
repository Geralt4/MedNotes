import Foundation
import XCTest

/// The sandbox must allow the security-scoped bookmark the legacy importer
/// keeps, or the panel can never reopen at the last import folder on the next
/// launch. The release gate reads the same file, so this also keeps the source
/// entitlement list in step with what the app actually ships.
final class EntitlementsTests: XCTestCase {
    func testSandboxAllowsAppScopedBookmarksForTheImportFolder() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MedNotesTests
            .deletingLastPathComponent()   // repository root
        let url = repository.appendingPathComponent("MedNotes/MedNotes.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])

        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(
            plist["com.apple.security.files.user-selected.read-write"] as? Bool, true)
        XCTAssertEqual(
            plist["com.apple.security.files.bookmarks.app-scope"] as? Bool, true,
            "the import bookmark cannot be resolved after relaunch without this")
    }
}
