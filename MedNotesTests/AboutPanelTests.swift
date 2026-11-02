import XCTest
@testable import MedNotes

/// The About panel carries the licenses of what the app ships (and the build
/// number beside the version). The text is `MedNotes/Licenses.txt`, made from
/// the pinned package versions and checked by `scripts/check_licenses.py`.
final class AboutPanelTests: XCTestCase {
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

    /// The app carries the file, with the pinned versions named in it. (That it
    /// is the file in the repository, and that the repository's file is what the
    /// pinned packages yield, is `scripts/check_licenses.py`'s job: a sandboxed
    /// test cannot read the repository without a minutes-long permission stall.)
    func testTheAppCarriesTheLicenseFileWithThePinnedVersions() throws {
        let shipped = try XCTUnwrap(AboutPanel.licenseText(), "Licenses.txt is not in the app bundle")
        XCTAssertTrue(shipped.contains("SQLCipher.swift 4.19.0 (revision 39f212458aeb88e33bdac2200a793a3f0d55d32b)"))
        XCTAssertTrue(shipped.contains("swift-sodium 0.11.0 (revision cfd195c76882aa9b997560ca7cb95d72fbf5db00)"))
        XCTAssertTrue(shipped.contains("Frank Denis"))
        XCTAssertTrue(shipped.contains("ZETETIC LLC"))
    }

    func testABundleWithoutTheFileGivesNoLicenseText() {
        XCTAssertNil(AboutPanel.licenseText(bundle: Bundle(for: AboutPanelTests.self)))
    }

    // MARK: - The build number beside the version

    /// A bundle with a known version and build, as the release script makes one.
    private func bundle(version: String, build: String) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-about-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.about", "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try XCTUnwrap(Bundle(url: root))
    }

    func testThePanelIsGivenTheVersionAndTheBuildNumberFromTheBundle() throws {
        let options = AboutPanel.options(bundle: try bundle(version: "2.5.1", build: "987"))
        XCTAssertEqual(options[.applicationVersion] as? String, "2.5.1")
        XCTAssertEqual(options[.version] as? String, "987", "the build number shows next to the version")
    }

    func testTheRunningAppHasABuildNumber() {
        let options = AboutPanel.options()
        XCTAssertEqual(options[.version] as? String,
                       Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertFalse((options[.version] as? String ?? "").isEmpty)
        XCTAssertFalse((options[.applicationVersion] as? String ?? "").isEmpty)
    }

    func testABundleWithoutAVersionGivesNoneRatherThanAWrongOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-about-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.none"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let options = AboutPanel.options(bundle: try XCTUnwrap(Bundle(url: root)))
        XCTAssertNil(options[.version])
        XCTAssertNil(options[.applicationVersion])
    }
}
