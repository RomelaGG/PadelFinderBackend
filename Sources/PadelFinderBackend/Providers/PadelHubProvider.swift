import Foundation
import NIOCore
import Vapor

struct PadelHubProvider: AvailabilityProvider {
    let id = "padel-hub"

    private let name = "Padel Hub"
    private let website = "https://www.padelhub.ge/booking"
    private let logo = "/logos/padel-hub.png"
    private let coverImage = "https://www.padelhub.ge/og-image.jpg"
    private let address = "39 Petre Kavtaradze St, Tbilisi"
    private let client: any Client
    private let apiBaseURL: String
    private let apiKey: String

    init(
        client: any Client,
        apiBaseURL: String = "https://gpypwkyuangjzgabagyi.supabase.co",
        apiKey: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdweXB3a3l1YW5nanpnYWJhZ3lpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDczMTMsImV4cCI6MjA5NDI4MzMxM30.s_s7BS2fS_qir43c-m8URuT-3cZnlZ8xdBHG6a7Jazs"
    ) {
        self.client = client
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        let courts = try await fetchPadelCourts()
        guard !courts.isEmpty else {
            return []
        }

        var unavailableBookingsByCourtID: [String: [PadelHubBookingAvailability]] = [:]
        try await withThrowingTaskGroup(of: (String, [PadelHubBookingAvailability]).self) { group in
            for court in courts {
                group.addTask {
                    let bookings = try await fetchUnavailableBookings(courtID: court.id, date: date)
                    return (court.id, bookings)
                }
            }

            for try await result in group {
                unavailableBookingsByCourtID[result.0] = result.1
            }
        }

        let courtAvailability = PadelHubMapper.map(
            courts: courts,
            unavailableBookingsByCourtID: unavailableBookingsByCourtID,
            selectedDate: date,
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

    private func fetchPadelCourts() async throws -> [PadelHubCourt] {
        try await getJSON(
            path: "/rest/v1/courts",
            queryItems: [
                ("select", "id,name,description,sport_type,image_url,is_active,created_at"),
                ("is_active", "eq.true"),
                ("sport_type", "eq.padel")
            ]
        )
    }

    private func fetchUnavailableBookings(courtID: String, date: String) async throws -> [PadelHubBookingAvailability] {
        try await postJSON(
            path: "/rest/v1/rpc/get_booking_availability",
            body: """
            {"p_booking_date":"\(date)","p_court_id":"\(courtID)"}
            """
        )
    }

    private func getJSON<Response: Decodable>(
        path: String,
        queryItems: [(String, String)] = []
    ) async throws -> Response {
        let response = try await client.get(url(path: path, queryItems: queryItems), headers: headers())
        return try decode(response)
    }

    private func postJSON<Response: Decodable>(
        path: String,
        body: String
    ) async throws -> Response {
        var requestHeaders = headers()
        requestHeaders.add(name: .contentType, value: "application/json")

        let response = try await client.post(url(path: path, queryItems: []), headers: requestHeaders) { request in
            request.body = ByteBuffer(string: body)
        }
        return try decode(response)
    }

    private func decode<Response: Decodable>(_ response: ClientResponse) throws -> Response {
        guard response.status == .ok else {
            throw PadelHubError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let bytes = body.readBytes(length: body.readableBytes) else {
            throw PadelHubError.emptyBody
        }

        return try JSONDecoder().decode(Response.self, from: Data(bytes))
    }

    private func headers() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "apikey", value: apiKey)
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        headers.add(name: .accept, value: "application/json")
        return headers
    }

    private func url(path: String, queryItems: [(String, String)]) -> URI {
        var string = apiBaseURL + path

        if !queryItems.isEmpty {
            let query = queryItems
                .map { key, value in
                    "\(queryEncode(key))=\(queryEncode(value))"
                }
                .joined(separator: "&")
            string += "?\(query)"
        }

        return URI(string: string)
    }

    private func queryEncode(_ value: String) -> String {
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: ":#[]@!$&'()*+,;=")

        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }
}

enum PadelHubMapper {
    static let priceWindows = [
        PadelHubPriceWindow(
            idSuffix: "08-15",
            label: "08:00 - 15:00",
            pricePerHour: 40,
            slotTimes: [
                "08:00",
                "09:00",
                "10:00",
                "11:00",
                "12:00",
                "13:00",
                "14:00"
            ]
        ),
        PadelHubPriceWindow(
            idSuffix: "15-00",
            label: "15:00 - 00:00",
            pricePerHour: 60,
            slotTimes: [
                "15:00",
                "16:00",
                "17:00",
                "18:00",
                "19:00",
                "20:00",
                "21:00",
                "22:00",
                "23:00",
                "00:00"
            ]
        )
    ]

    static func map(
        courts: [PadelHubCourt],
        unavailableBookingsByCourtID: [String: [PadelHubBookingAvailability]],
        selectedDate: String,
        address: String?,
        now: Date = Date()
    ) -> [CourtAvailability] {
        courts
            .sorted { lhs, rhs in
                let lhsOrder = displayOrder(for: lhs)
                let rhsOrder = displayOrder(for: rhs)
                if lhsOrder == rhsOrder {
                    return lhs.id < rhs.id
                }
                return lhsOrder < rhsOrder
            }
            .flatMap { court in
                let unavailableTimes = Set(
                    (unavailableBookingsByCourtID[court.id] ?? [])
                        .filter { isUnavailable($0, selectedDate: selectedDate, now: now) }
                        .map(\.timeSlot)
                )

                return priceWindows.map { window in
                    CourtAvailability(
                        id: "padel-hub-\(court.id)-\(window.idSuffix)",
                        name: "\(displayName(for: court)) \(window.label)",
                        address: address,
                        pricePerHour: window.pricePerHour,
                        rating: nil,
                        totalCourts: 1,
                        timeSlots: window.slotTimes.map { time in
                            let isBookable = !unavailableTimes.contains(time)

                            return TimeSlot(
                                time: time,
                                status: isBookable ? .available : .booked,
                                isBookable: isBookable
                            )
                        }
                    )
                }
            }
    }

    private static func isUnavailable(
        _ booking: PadelHubBookingAvailability,
        selectedDate: String,
        now: Date
    ) -> Bool {
        if booking.status == "confirmed" {
            return true
        }

        guard booking.status == "cancelled",
              let slotDate = PadelHubDate.slotDate(selectedDate: selectedDate, time: booking.timeSlot) else {
            return false
        }

        let hoursUntilSlot = slotDate.timeIntervalSince(now) / 3600
        return hoursUntilSlot > 0 && hoursUntilSlot < 2
    }

    private static func displayOrder(for court: PadelHubCourt) -> Int {
        switch court.name {
        case "court_padel_open":
            return 1
        case "court_padel_closed":
            return 2
        default:
            return 100
        }
    }

    private static func displayName(for court: PadelHubCourt) -> String {
        switch court.name {
        case "court_padel_open":
            return "Open Padel Court"
        case "court_padel_closed":
            return "Indoor Padel Court"
        default:
            return court.name
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
}

struct PadelHubPriceWindow: Sendable {
    let idSuffix: String
    let label: String
    let pricePerHour: Int
    let slotTimes: [String]
}

enum PadelHubDate {
    static func slotDate(selectedDate: String, time: String) -> Date? {
        let formatter = formatter()
        guard let date = formatter.date(from: "\(selectedDate) \(time)") else {
            return nil
        }

        guard time == "00:00" else {
            return date
        }

        return calendar.date(byAdding: .day, value: 1, to: date)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tbilisi") ?? .current
        return calendar
    }
}

struct PadelHubCourt: Decodable, Sendable {
    let id: String
    let name: String
    let description: String?
    let sportType: String
    let imageURL: String?
    let isActive: Bool
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case sportType = "sport_type"
        case imageURL = "image_url"
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

struct PadelHubBookingAvailability: Decodable, Sendable {
    let timeSlot: String
    let bookingDate: String
    let status: String

    private enum CodingKeys: String, CodingKey {
        case timeSlot = "time_slot"
        case bookingDate = "booking_date"
        case status
    }
}

private enum PadelHubError: Error, CustomStringConvertible {
    case emptyBody
    case unexpectedStatus(HTTPResponseStatus)

    var description: String {
        switch self {
        case .emptyBody:
            return "empty response body"
        case .unexpectedStatus(let status):
            return "unexpected upstream status \(status)"
        }
    }
}
