import XCTest
@testable import MedNotes

/// How the event record view words an event's time.
final class EventSummaryTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")
    private lazy var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Athens")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func summary(_ event: CalendarEvent, now: Date) -> EventSummary {
        EventSummary(event, now: now, calendar: calendar, locale: locale)
    }

    func testSameDayTimedEvent() {
        let event = CalendarEvent(startDate: date(27, 20, 51), endDate: date(27, 21, 21))
        let s = summary(event, now: date(24, 12))
        XCTAssertTrue(s.when.hasPrefix("Tuesday, 27 October 2026"), s.when)
        XCTAssertTrue(s.when.contains("20:51 – 21:21"), s.when)
        XCTAssertEqual(s.duration, "30 min")
        XCTAssertEqual(s.relative, "in 3 days")
    }

    func testLongerDurationUsesTwoUnits() {
        let event = CalendarEvent(startDate: date(27, 9), endDate: date(27, 10, 30))
        XCTAssertEqual(summary(event, now: date(24)).duration, "1 hr, 30 min")
    }

    func testAllDayOneDay() {
        let event = CalendarEvent(startDate: date(2, month: 11), endDate: date(2, month: 11), isAllDay: true)
        let s = summary(event, now: date(24, 12))
        XCTAssertEqual(s.when, "Monday, 2 November 2026 · \(String(localized: "All-day"))")
        XCTAssertNil(s.duration)
    }

    func testAllDaySeveralDays() {
        let event = CalendarEvent(startDate: date(27), endDate: date(29), isAllDay: true)
        XCTAssertEqual(summary(event, now: date(24)).when, "27 Oct – 29 Oct 2026 · \(String(localized: "All-day"))")
    }

    func testEventCrossingMidnightNamesBothDays() {
        let event = CalendarEvent(startDate: date(27, 22), endDate: date(28, 6))
        let s = summary(event, now: date(24))
        XCTAssertEqual(s.when, "27 Oct, 22:00 – 28 Oct, 06:00")
        XCTAssertEqual(s.duration, "8 hrs")
    }

    func testRelativeTimes() {
        let event = CalendarEvent(startDate: date(24, 14), endDate: date(24, 15))
        XCTAssertEqual(summary(event, now: date(24, 14, 30)).relative, String(localized: "Now"))
        XCTAssertEqual(summary(event, now: date(25, 14)).relative, "yesterday")
        XCTAssertEqual(summary(event, now: date(24, 12)).relative, "in 2 hours")
    }

    func testAnAllDayEventIsWordedInDaysNotHoursFromMidnight() {
        let tomorrow = CalendarEvent(startDate: date(25), endDate: date(25), isAllDay: true)
        XCTAssertEqual(summary(tomorrow, now: date(24, 22)).relative, "tomorrow")
        let inThree = CalendarEvent(startDate: date(27), endDate: date(27), isAllDay: true)
        XCTAssertEqual(summary(inThree, now: date(24, 23)).relative, "in 3 days")
        let yesterday = CalendarEvent(startDate: date(23), endDate: date(23), isAllDay: true)
        XCTAssertEqual(summary(yesterday, now: date(24, 1)).relative, "yesterday")
    }

    func testMovingTheStartKeepsTheLengthOfTheEvent() {
        var event = CalendarEvent(startDate: date(5, 10, 0, month: 11), endDate: date(5, 10, 30, month: 11))
        event.moveStart(to: date(3, 10, 0, month: 11), calendar: calendar)
        XCTAssertEqual(event.startDate, date(3, 10, 0, month: 11))
        XCTAssertEqual(event.endDate, date(3, 10, 30, month: 11), "a half-hour appointment stays one")

        var allDay = CalendarEvent(startDate: date(5, month: 11), endDate: date(6, month: 11), isAllDay: true)
        allDay.moveStart(to: date(3, month: 11), calendar: calendar)
        XCTAssertEqual(allDay.endDate, date(4, month: 11), "two days stay two days")
    }

    func testAllDayEventIsOnAllDay() {
        let event = CalendarEvent(startDate: date(24), endDate: date(24), isAllDay: true)
        XCTAssertEqual(summary(event, now: date(24, 23, 30)).relative, String(localized: "Now"))
    }
}
