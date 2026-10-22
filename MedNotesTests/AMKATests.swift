import XCTest
@testable import MedNotes

/// The AMKA helpers are advisory: they must be right when they warn, and they
/// must never be consulted on the save path. Reference date is fixed so the
/// century rule is deterministic.
final class AMKATests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!
    }

    func testNormalizationDropsSeparatorsOnly() {
        XCTAssertEqual(AMKA.normalized(" 12047 8123-47 "), "12047812347")
        XCTAssertEqual(AMKA.normalized("12047812347"), "12047812347")
        XCTAssertEqual(AMKA.normalized("1204781234a"), "1204781234a")
    }

    func testLuhn() {
        XCTAssertTrue(AMKA.luhnIsValid("79927398713"))   // the textbook vector
        XCTAssertFalse(AMKA.luhnIsValid("79927398710"))
        XCTAssertTrue(AMKA.luhnIsValid("12047812347"))
        XCTAssertFalse(AMKA.luhnIsValid("12047812345"))
        XCTAssertFalse(AMKA.luhnIsValid("1204781234x"))
    }

    func testCheckDigitCompletesTenDigits() {
        XCTAssertEqual(AMKA.checkDigit(for: "1204781234"), "7")
        XCTAssertEqual(AMKA.checkDigit(for: "7992739871"), "3")
        XCTAssertNil(AMKA.checkDigit(for: "120478123"))
        XCTAssertNil(AMKA.checkDigit(for: "12047812345"))
        XCTAssertNil(AMKA.checkDigit(for: "12047812a4"))
    }

    func testIssues() {
        XCTAssertNil(AMKA.issue(for: "", now: now))
        XCTAssertNil(AMKA.issue(for: "   ", now: now))
        XCTAssertNil(AMKA.issue(for: "12047812347", now: now))
        XCTAssertNil(AMKA.issue(for: "120478 12347", now: now), "spaces between groups are fine")
        XCTAssertEqual(AMKA.issue(for: "1204", now: now), .length(4))
        XCTAssertEqual(AMKA.issue(for: "120478123471", now: now), .length(12))
        XCTAssertEqual(AMKA.issue(for: "1204781234a", now: now), .nonDigits)
        XCTAssertEqual(AMKA.issue(for: "32047812345", now: now), .impossibleDate)   // day 32
        XCTAssertEqual(AMKA.issue(for: "31047812345", now: now), .impossibleDate)   // 31 April
        XCTAssertEqual(AMKA.issue(for: "12137812345", now: now), .impossibleDate)   // month 13
        XCTAssertEqual(AMKA.issue(for: "12047812345", now: now), .checkDigit)
    }

    func testBirthDateResolvesTheCentury() {
        let born1978 = AMKA.birthDate(from: "12047812347", now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: born1978!),
                       DateComponents(year: 1978, month: 4, day: 12))

        // "30" cannot mean 2030 on 2026-09-08, so it is 1930.
        let born1930 = AMKA.birthDate(from: "01013000011", now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.year, from: born1930!), 1930)

        // "00" is 2000 — a 26-year-old, not a 126-year-old.
        let born2000 = AMKA.birthDate(from: "29020000013", now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: born2000!),
                       DateComponents(year: 2000, month: 2, day: 29))

        // Born later this year than today: still this century, not 1926.
        let bornDecember = AMKA.birthDate(from: "25122612345", now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.year, from: bornDecember!), 1926)
    }

    func testBirthDateRejectsNonDates() {
        XCTAssertNil(AMKA.birthDate(from: "31041978", now: now, calendar: calendar))
        XCTAssertNil(AMKA.birthDate(from: "29022300011", now: now, calendar: calendar), "2023 is not a leap year")
        XCTAssertNil(AMKA.birthDate(from: "1204", now: now, calendar: calendar))
        XCTAssertNil(AMKA.birthDate(from: "ab0478", now: now, calendar: calendar))
    }
}
