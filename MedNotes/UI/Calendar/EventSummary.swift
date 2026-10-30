import Foundation

/// The words an event's record view uses for when it happens: the full date
/// and times, how long it lasts, and how far off it is. Pure, with the clock,
/// calendar and locale passed in, so the wording is testable.
struct EventSummary: Equatable {
    /// "Tuesday 27 October 2026 · 8:51 – 9:21 PM", or the range of days.
    let when: String
    /// "30 min"; `nil` for an all-day event.
    let duration: String?
    /// "in 3 days", "yesterday", or "Now" while it is on.
    let relative: String

    init(_ event: CalendarEvent, now: Date = Date(),
         calendar: Calendar = .current, locale: Locale = .current) {
        var calendar = calendar
        calendar.locale = locale
        let tz = calendar.timeZone
        func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
            var s = base
            s.locale = locale
            s.timeZone = tz
            s.calendar = calendar
            return s
        }
        let fullDay = style(.dateTime.weekday(.wide).day().month(.wide).year())
        let shortDay = style(.dateTime.day().month(.abbreviated))
        let shortDayYear = style(.dateTime.day().month(.abbreviated).year())
        let time = style(.dateTime.hour().minute())

        let sameDay = calendar.isDate(event.startDate, inSameDayAs: event.endDate)
        let allDay = String(localized: "All-day")
        if event.isAllDay {
            when = sameDay
                ? "\(event.startDate.formatted(fullDay)) · \(allDay)"
                : "\(event.startDate.formatted(shortDay)) – \(event.endDate.formatted(shortDayYear)) · \(allDay)"
            duration = nil
        } else {
            when = sameDay
                ? "\(event.startDate.formatted(fullDay)) · \(event.startDate.formatted(time)) – \(event.endDate.formatted(time))"
                : "\(event.startDate.formatted(shortDay)), \(event.startDate.formatted(time)) – \(event.endDate.formatted(shortDay)), \(event.endDate.formatted(time))"
            let formatter = DateComponentsFormatter()
            formatter.calendar = calendar
            formatter.unitsStyle = .short
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.maximumUnitCount = 2
            let seconds = event.endDate.timeIntervalSince(event.startDate)
            duration = seconds > 0 ? formatter.string(from: seconds) : nil
        }

        // An all-day event runs through the end of its last day.
        let end = event.isAllDay
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.endDate)) ?? event.endDate
            : event.endDate
        if event.startDate <= now, now < end {
            relative = String(localized: "Now")
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            if event.isAllDay {
                // Whole days from today, not hours from midnight: at 22:00 an
                // all-day event tomorrow is "tomorrow", not "in 2 hours".
                let days = calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: now),
                    to: calendar.startOfDay(for: event.startDate)).day ?? 0
                relative = formatter.localizedString(from: DateComponents(day: days))
            } else {
                relative = formatter.localizedString(for: event.startDate, relativeTo: now)
            }
        }
    }
}
