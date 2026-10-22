import Foundation

/// The Greek social security number (ΑΜΚΑ): eleven digits — the birth date as
/// DDMMYY, a four-digit serial, and a Luhn check digit.
///
/// Advisory helpers only. The store accepts any string, because legacy data
/// holds malformed values and an import must never fail on one; the editor
/// uses these to warn, to offer the encoded birth date, and nothing more.
enum AMKA {
    enum Issue: Equatable {
        /// Digits found, when not eleven.
        case length(Int)
        case nonDigits
        /// The first six digits do not form a calendar date.
        case impossibleDate
        case checkDigit
    }

    static let digitCount = 11

    /// ASCII digits only; the spaces and dashes people type between groups
    /// are dropped, anything else is kept so it can be reported.
    static func normalized(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace && $0 != "-" }
    }

    /// `nil` for an empty value or a well-formed one.
    static func issue(for raw: String, now: Date = Date()) -> Issue? {
        let digits = normalized(raw)
        guard !digits.isEmpty else { return nil }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .nonDigits }
        guard digits.count == digitCount else { return .length(digits.count) }
        guard birthDate(from: digits, now: now) != nil else { return .impossibleDate }
        guard luhnIsValid(digits) else { return .checkDigit }
        return nil
    }

    /// The birth date the leading six digits encode, resolved to the century
    /// that does not place the birth in the future as of `now`. `nil` when
    /// they are not a real calendar date (31 April, 29 February off a leap
    /// year, month 13, …).
    static func birthDate(from raw: String, now: Date = Date(),
                          calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        let digits = normalized(raw)
        guard digits.count >= 6, digits.prefix(6).allSatisfy({ $0.isASCII && $0.isNumber }),
              let day = Int(digits.prefix(2)),
              let month = Int(digits.dropFirst(2).prefix(2)),
              let yearInCentury = Int(digits.dropFirst(4).prefix(2)) else { return nil }
        let thisYear = calendar.component(.year, from: now)
        var year = (thisYear / 100) * 100 + yearInCentury
        if year > thisYear { year -= 100 }
        for candidate in [year, year - 100] {
            let components = DateComponents(year: candidate, month: month, day: day)
            guard let date = calendar.date(from: components) else { continue }
            // `date(from:)` normalises 31 April into 1 May; only an exact
            // round trip is a real date.
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == candidate, back.month == month, back.day == day else { continue }
            if date <= now { return date }
        }
        return nil
    }

    /// The digit that completes ten digits into a valid number; `nil` unless
    /// given exactly ten ASCII digits.
    static func checkDigit(for tenDigits: String) -> Character? {
        guard tenDigits.count == digitCount - 1,
              tenDigits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "0123456789".first { luhnIsValid(tenDigits + String($0)) }
    }

    /// Standard Luhn (mod 10) over all eleven digits.
    static func luhnIsValid(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let value = character.wholeNumberValue, character.isASCII else { return false }
            if index % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return sum % 10 == 0
    }
}
