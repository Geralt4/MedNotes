import XCTest
@testable import MedNotes

/// The test run is pinned to English (the scheme's Test action: language
/// English, region United States). About thirty tests compare what the app
/// shows with English text; without the pin they fail on a Mac whose first
/// language is Greek. If this fails, the pin is gone from the scheme or the
/// run overrode it (`-testLanguage`).
final class TestLanguageTests: XCTestCase {
    func testTheTestRunIsPinnedToEnglish() {
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "en",
                       "the app resolved its strings in \(Bundle.main.preferredLocalizations)")
        XCTAssertEqual(Locale.current.language.languageCode?.identifier, "en")
        XCTAssertEqual(Locale.current.region?.identifier, "US")
        XCTAssertEqual(String(localized: "Cancel"), "Cancel")
    }
}
