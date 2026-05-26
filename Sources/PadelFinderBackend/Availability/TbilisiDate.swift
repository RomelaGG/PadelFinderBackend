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
