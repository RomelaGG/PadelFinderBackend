import Foundation

enum TbilisiDate {
    private static let timeZone = TimeZone(identifier: "Asia/Tbilisi")!

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    static func todayString(now: Date = Date()) -> String {
        formatter().string(from: now)
    }

    /// Returns `today ... today + daysAhead` as `YYYY-MM-DD` strings in Tbilisi
    /// time, used to decide which days the Kus Tba refresher keeps warm.
    static func upcomingDateStrings(daysAhead: Int, now: Date = Date()) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let formatter = formatter()
        let today = calendar.startOfDay(for: now)

        return (0...max(0, daysAhead)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map(formatter.string(from:))
        }
    }

    /// Whether `value` falls inside `today ... today + daysAhead` in Tbilisi time.
    ///
    /// The request path uses this to reject dates nobody can play on. Without it
    /// every distinct date is a new `AvailabilityCache` key and, on a miss, a
    /// fresh ~20-request fan-out at Kus Tba's site.
    static func isWithinWindow(_ value: String, daysAhead: Int, now: Date = Date()) -> Bool {
        upcomingDateStrings(daysAhead: daysAhead, now: now).contains(value)
    }

    static func validatedDateString(_ value: String) -> String? {
        guard value.count == 10 else {
            return nil
        }

        let formatter = formatter()
        guard let date = formatter.date(from: value) else {
            return nil
        }

        guard formatter.string(from: date) == value else {
            return nil
        }

        return value
    }
}
