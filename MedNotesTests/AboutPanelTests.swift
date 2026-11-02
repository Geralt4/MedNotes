import XCTest
@testable import MedNotes

/// The About panel carries the licenses of what the app ships (and the build
/// number beside the version). The text is `MedNotes/Licenses.txt`, made from
/// the pinned package versions and checked by `scripts/check_licenses.py`.
final class AboutPanelTests: XCTestCase {
    private func repositoryLicenses() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("MedNotes/Licenses.txt"), encoding: .utf8)
    }

    func testTheCreditsHoldBothLicenseTexts() {
        let credits = AboutPanel.credits().string
        XCTAssertTrue(credits.contains("SQLCipher"), "SQLCipher's license is missing from the About panel")
        XCTAssertTrue(credits.contains("Community Edition Open Source License"))
        XCTAssertTrue(credits.contains("libsodium"), "libsodium's license is missing from the About panel")
        XCTAssertTrue(credits.contains("ISC License"))
        XCTAssertTrue(credits.contains("Frank Denis"))
        XCTAssertTrue(credits.contains("ZETETIC LLC"))
    }

    func testThePanelIsGivenTheCredits() throws {
        let options = AboutPanel.options()
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertTrue(credits.string.contains("ISC License"))
    }

    /// What the app ships is what the repository holds, and the pinned versions
    /// are named in it.
    func testTheAppCarriesTheRepositorysLicenseFile() throws {
        let shipped = try XCTUnwrap(AboutPanel.licenseText(), "Licenses.txt is not in the app bundle")
        XCTAssertEqual(shipped, try repositoryLicenses())
        XCTAssertTrue(shipped.contains("39f212458aeb88e33bdac2200a793a3f0d55d32b"), "SQLCipher.swift's pinned revision")
        XCTAssertTrue(shipped.contains("cfd195c76882aa9b997560ca7cb95d72fbf5db00"), "swift-sodium's pinned revision")
    }

    func testABundleWithoutTheFileGivesNoLicenseText() {
        XCTAssertNil(AboutPanel.licenseText(bundle: Bundle(for: AboutPanelTests.self)))
    }
}
