import Foundation
import NIOCore
import Vapor

struct PadelGldaniProvider: AvailabilityProvider {
    let id = "padel-gldani"

    private let name = "Padel Gldani"
    private let website = "https://padelgldani.ge/en/booking/"
    private let logo = "/logos/padel-gldani.png"
    private let coverImage = "https://padelgldani.ge/wp-content/uploads/2025/02/1.png"
    private let address = "56 Ilia Vekua St"
    private let startHour = 8
    private let client: any Client
    private let ajaxURL: URI
    private let courts: [PadelGldaniCourt]

    init(
        client: any Client,
        ajaxURL: URI = URI(string: "https://padelgldani.ge/wp-admin/admin-ajax.php"),
        courts: [PadelGldaniCourt] = PadelGldaniCourt.defaultCourts
    ) {
        self.client = client
        self.ajaxURL = ajaxURL
        self.courts = courts
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        guard let nextDate = PadelGldaniDate.addDays(1, to: date) else {
            throw PadelGldaniError.invalidDate(date)
        }

        var sameDayTimesByProductID: [Int: Set<String>] = [:]
        var nextDayTimesByProductID: [Int: Set<String>] = [:]

        try await withThrowingTaskGroup(of: PadelGldaniBlockFetchResult.self) { group in
            for court in courts {
                group.addTask {
                    let html = try await fetchBlocks(productID: court.productID, date: date)
                    return PadelGldaniBlockFetchResult(productID: court.productID, window: .sameDay, times: PadelGldaniBlocksParser.availableTimes(from: html))
                }
                group.addTask {
                    let html = try await fetchBlocks(productID: court.productID, date: nextDate)
                    return PadelGldaniBlockFetchResult(productID: court.productID, window: .nextDay, times: PadelGldaniBlocksParser.availableTimes(from: html))
                }
            }

            for try await result in group {
                switch result.window {
                case .sameDay:
                    sameDayTimesByProductID[result.productID] = result.times
                case .nextDay:
                    nextDayTimesByProductID[result.productID] = result.times
                }
            }
        }

        var availableTimesByProductID: [Int: Set<String>] = [:]
        for court in courts {
            availableTimesByProductID[court.productID] = PadelGldaniMapper.businessDayAvailableTimes(
                sameDayTimes: sameDayTimesByProductID[court.productID] ?? [],
                nextDayTimes: nextDayTimesByProductID[court.productID] ?? [],
                startHour: startHour
            )
        }

        let courtAvailability = PadelGldaniMapper.map(
            courts: courts,
            availableTimesByProductID: availableTimesByProductID,
            date: date,
            address: address
        )

        guard !courtAvailability.isEmpty else {
            return []
        }

        return [
            PadelCompanyAvailability(
                id: id,
                name: name,
                website: website,
                logo: logo,
                coverImage: coverImage,
                courts: courtAvailability
            )
        ]
    }

    private func fetchBlocks(productID: Int, date: String) async throws -> String {
        guard let dateComponents = PadelGldaniDate.components(from: date) else {
            throw PadelGldaniError.invalidDate(date)
        }

        let form = formURLEncoded([
            ("wc_bookings_field_start_date_month", dateComponents.month),
            ("wc_bookings_field_start_date_day", dateComponents.day),
            ("wc_bookings_field_start_date_year", dateComponents.year),
            ("wc_bookings_field_duration", "1"),
            ("wc_bookings_field_start_date_time", ""),
            ("wc_bookings_field_start_date_local_timezone", ""),
            ("add-to-cart", String(productID)),
            ("min_date", date),
            ("max_date", date),
            ("timezone_offset", "0")
        ])

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded; charset=UTF-8")
        headers.add(name: "Origin", value: "https://padelgldani.ge")
        headers.add(name: "Referer", value: "https://padelgldani.ge/en/booking/")
        headers.add(name: "X-Requested-With", value: "XMLHttpRequest")
        headers.add(name: "Cookie", value: "hc_js_gate=1")

        let response = try await client.post(ajaxURL, headers: headers) { request in
            request.body = ByteBuffer(string: formURLEncoded([
                ("action", "wc_bookings_get_blocks"),
                ("form", form)
            ]))
        }

        guard response.status == .ok else {
            throw PadelGldaniError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let bytes = body.readBytes(length: body.readableBytes) else {
            throw PadelGldaniError.emptyBody
        }

        let html = String(decoding: bytes, as: UTF8.self)
        guard !html.contains("Checking your browser") else {
            throw PadelGldaniError.browserGate
        }

        return html
    }

    private func formURLEncoded(_ parameters: [(String, String)]) -> String {
        parameters
            .map { key, value in
                "\(formEncode(key))=\(formEncode(value))"
            }
            .joined(separator: "&")
    }

    private func formEncode(_ value: String) -> String {
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: ":#[]@!$&'()*+,;=")

        return value
            .addingPercentEncoding(withAllowedCharacters: allowedCharacters)?
            .replacingOccurrences(of: " ", with: "+") ?? value
    }
}

enum PadelGldaniMapper {
    static let businessDaySlotTimes = [
        "08:00",
        "09:00",
        "10:00",
        "11:00",
        "12:00",
        "13:00",
        "14:00",
        "15:00",
        "16:00",
        "17:00",
        "18:00",
        "19:00",
        "20:00",
        "21:00",
        "22:00",
        "23:00",
        "00:00",
        "01:00"
    ]

    static func map(
        courts: [PadelGldaniCourt],
        availableTimesByProductID: [Int: Set<String>],
        date: String,
        address: String?
    ) -> [CourtAvailability] {
        courts
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { court in
                let availableTimes = availableTimesByProductID[court.productID] ?? []

                return CourtAvailability(
                    id: "padel-gldani-\(court.productID)",
                    name: court.name,
                    address: address,
                    pricePerHour: PadelGldaniDate.pricePerHour(for: date),
                    rating: nil,
                    totalCourts: 1,
                    timeSlots: businessDaySlotTimes.map { time in
                        let isBookable = availableTimes.contains(time)

                        return TimeSlot(
                            time: time,
                            status: isBookable ? .available : .booked,
                            isBookable: isBookable
                        )
                    }
                )
            }
    }

    static func businessDayAvailableTimes(
        sameDayTimes: Set<String>,
        nextDayTimes: Set<String>,
        startHour: Int
    ) -> Set<String> {
        sameDayTimes.filter { hour(from: $0).map { $0 >= startHour } ?? false }
            .union(nextDayTimes.filter { hour(from: $0).map { $0 < startHour } ?? false })
    }

    private static func hour(from time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard let hour = parts.first else {
            return nil
        }

        return Int(hour)
    }
}

struct PadelGldaniBlocksParser {
    static func availableTimes(from html: String) -> Set<String> {
        var times = Set<String>()

        for match in captures(pattern: #"data-block="(\d{2})(\d{2})""#, in: html) {
            guard match.count == 2 else {
                continue
            }
            times.insert("\(match[0]):\(match[1])")
        }

        guard times.isEmpty else {
            return times
        }

        for match in captures(pattern: #"value="[^"]*T(\d{2}):(\d{2}):\d{2}[^"]*""#, in: html) {
            guard match.count == 2 else {
                continue
            }
            times.insert("\(match[0]):\(match[1])")
        }

        return times
    }

    private static func captures(pattern: String, in string: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else {
                return nil
            }

            var captures: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let captureRange = Range(match.range(at: index), in: string) else {
                    return nil
                }
                captures.append(String(string[captureRange]))
            }
            return captures
        }
    }
}

struct PadelGldaniCourt: Sendable {
    let productID: Int
    let name: String
    let displayOrder: Int

    static let defaultCourts = [
        PadelGldaniCourt(productID: 72, name: "Court I", displayOrder: 1),
        PadelGldaniCourt(productID: 70, name: "Court II", displayOrder: 2),
        PadelGldaniCourt(productID: 68, name: "Court III", displayOrder: 3)
    ]
}

enum PadelGldaniDate {
    static func components(from date: String) -> PadelGldaniDateComponents? {
        guard date.count == 10 else {
            return nil
        }

        let parts = date.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2 else {
            return nil
        }

        return PadelGldaniDateComponents(
            year: String(parts[0]),
            month: String(parts[1]),
            day: String(parts[2])
        )
    }

    static func addDays(_ days: Int, to date: String) -> String? {
        let formatter = formatter()
        guard let parsedDate = formatter.date(from: date),
              let adjustedDate = calendar.date(byAdding: .day, value: days, to: parsedDate) else {
            return nil
        }

        return formatter.string(from: adjustedDate)
    }

    static func pricePerHour(for date: String) -> Int? {
        let formatter = formatter()
        guard let parsedDate = formatter.date(from: date) else {
            return nil
        }

        let weekday = calendar.component(.weekday, from: parsedDate)
        return weekday == 1 || weekday == 7 ? 60 : 50
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tbilisi") ?? .current
        return calendar
    }
}

struct PadelGldaniDateComponents: Sendable {
    let year: String
    let month: String
    let day: String
}

private struct PadelGldaniBlockFetchResult: Sendable {
    let productID: Int
    let window: PadelGldaniBlockWindow
    let times: Set<String>
}

private enum PadelGldaniBlockWindow: Sendable {
    case sameDay
    case nextDay
}

private enum PadelGldaniError: Error, CustomStringConvertible {
    case browserGate
    case emptyBody
    case invalidDate(String)
    case unexpectedStatus(HTTPResponseStatus)

    var description: String {
        switch self {
        case .browserGate:
            return "Padel Gldani browser gate was returned instead of booking data"
        case .emptyBody:
            return "empty response body"
        case .invalidDate(let date):
            return "invalid booking date \(date)"
        case .unexpectedStatus(let status):
            return "unexpected upstream status \(status)"
        }
    }
}
