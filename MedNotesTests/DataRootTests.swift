import XCTest
@testable import MedNotes

final class DataRootTests: XCTestCase {

    /// The preview root is a literal sibling of the real one. This predicate is
    /// not what makes the reset safe — the compile-time path is — but it makes
    /// the isolation claim assertable instead of merely argued.
    func testIsPreviewRootDistinguishesTheRealStore() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)

        let preview = base.appendingPathComponent(DataRoot.previewDirectoryName, isDirectory: true)
        let real = base.appendingPathComponent("com.johnteam.MedNotes", isDirectory: true)

        XCTAssertTrue(DataRoot.isPreviewRoot(preview))
        XCTAssertFalse(DataRoot.isPreviewRoot(real))
    }

    /// Everything in `DataRoot` is built with `isDirectory: true`, so the
    /// predicate must not depend on whether a trailing slash survived.
    func testIsPreviewRootIgnoresTrailingSlash() {
        let withSlash = URL(fileURLWithPath: "/tmp/\(DataRoot.previewDirectoryName)", isDirectory: true)
        let withoutSlash = URL(fileURLWithPath: "/tmp/\(DataRoot.previewDirectoryName)", isDirectory: false)

        XCTAssertTrue(DataRoot.isPreviewRoot(withSlash))
        XCTAssertTrue(DataRoot.isPreviewRoot(withoutSlash))
    }

    func testPreviewRootNameIsNotTheRealRootName() {
        XCTAssertNotEqual(DataRoot.previewDirectoryName, "com.johnteam.MedNotes")
        XCTAssertFalse(DataRoot.isPreviewRoot(
            URL(fileURLWithPath: "/tmp/com.johnteam.MedNotes", isDirectory: true)))
    }

    /// Not launched with `--preview-seed`, so the app resolves the real store.
    func testPreviewSeedIsInactiveInTheTestHost() {
        XCTAssertFalse(PreviewSeed.isActive)
        XCTAssertFalse(PreviewSeed.wantsFreshData)
    }
}
