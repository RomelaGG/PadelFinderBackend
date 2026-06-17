import Foundation
import NIOCore
import Vapor

struct KustbaPadelProvider: AvailabilityProvider {
    let id = "kustba-padel"

    private let name = "Kus Tba Padel"
    private let website = "https://kustbapadel.ge/en/booking/"
    private let logo = "https://kustbapadel.ge/wp-content/uploads/2025/09/Asset-1CG.png"
    private let address = "Kus Tba, Tbilisi"
    private let client: Client
    private let bookingPageURL: URI
    private let ajaxURL: URI

    init(
        client: Client,
        bookingPageURL: URI = URI(string: "https://kustbapadel.ge/en/booking/"),
        ajaxURL: URI = URI(string: "https://kustbapadel.ge/wp-admin/admin-ajax.php")
    ) {
        self.client = client
        self.bookingPageURL = bookingPageURL
        self.ajaxURL = ajaxURL
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        let pageContext = try await fetchPageContext()
        let tabID = "padel-finder-\(UUID().uuidString)"
        let slots: KustbaAJAXResponse<[KustbaSlot]> = try await postForm(
            [
                ("action", "get_available_slots"),
                ("date", date),
                ("tab_id", tabID),
                ("nonce", pageContext.nonce)
            ],
            sessionCookie: pageContext.sessionCookie
        )

        let courtsBySlot = try await fetchCourtsBySlot(
            date: date,
            slots: slots.data,
            nonce: pageContext.nonce,
            startHour: pageContext.startHour,
            tabID: tabID,
            sessionCookie: pageContext.sessionCookie
        )

        let courts = KustbaPadelMapper.map(
            slots: slots.data,
            courtsBySlot: courtsBySlot,
            address: address
        )

        guard !courts.isEmpty else {
            return []
        }

        return [
            PadelCompanyAvailability(
                id: id,
                name: name,
                website: website,
                logo: logo,
                courts: courts
            )
        ]
    }

    private func fetchPageContext() async throws -> KustbaPageContext {
        let response = try await client.get(bookingPageURL)
        guard response.status == .ok else {
            throw KustbaPadelError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let htmlBytes = body.readBytes(length: body.readableBytes) else {
            throw KustbaPadelError.emptyBody
        }
        let html = String(decoding: htmlBytes, as: UTF8.self)

        guard let nonce = KustbaPageContextExtractor.extractNonce(from: html) else {
            throw KustbaPadelError.missingNonce
        }

        return KustbaPageContext(
            nonce: nonce,
            startHour: KustbaPageContextExtractor.extractStartHour(from: html) ?? 9,
            sessionCookie: KustbaPageContextExtractor.extractSessionCookie(from: response.headers)
        )
    }

    private func fetchCourtsBySlot(
        date: String,
        slots: [KustbaSlot],
        nonce: String,
        startHour: Int,
        tabID: String,
        sessionCookie: String?
    ) async throws -> [String: [KustbaCourt]] {
        var courtsBySlot: [String: [KustbaCourt]] = [:]

        try await withThrowingTaskGroup(of: (String, [KustbaCourt]).self) { group in
            for slot in slots {
                group.addTask {
                    let response: KustbaAJAXResponse<KustbaCourtsData> = try await postForm(
                        [
                            ("action", "get_available_courts"),
                            ("date", KustbaBookingDateResolver.bookingDate(for: date, time: slot.time, startHour: startHour)),
                            ("time", slot.time),
                            ("tab_id", tabID),
                            ("nonce", nonce)
                        ],
                        sessionCookie: sessionCookie
                    )

                    return (slot.time, response.data.courts)
                }
            }

            for try await result in group {
                courtsBySlot[result.0] = result.1
            }
        }

        return courtsBySlot
    }

    private func postForm<Response: Decodable>(
        _ parameters: [(String, String)],
        sessionCookie: String?
    ) async throws -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded; charset=UTF-8")
        headers.add(name: "Origin", value: "https://kustbapadel.ge")
        headers.add(name: "Referer", value: "https://kustbapadel.ge/en/booking/")
        headers.add(name: "X-Requested-With", value: "XMLHttpRequest")
        if let sessionCookie {
            headers.add(name: "Cookie", value: sessionCookie)
        }

        let response = try await client.post(ajaxURL, headers: headers) { request in
            request.body = ByteBuffer(string: formURLEncoded(parameters))
        }

        guard response.status == .ok else {
            throw KustbaPadelError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let bytes = body.readBytes(length: body.readableBytes) else {
            throw KustbaPadelError.emptyBody
        }

        return try JSONDecoder().decode(Response.self, from: Data(bytes))
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

enum KustbaPadelMapper {
    static func map(
        slots: [KustbaSlot],
        courtsBySlot: [String: [KustbaCourt]],
        address: String?
    ) -> [CourtAvailability] {
        let courts = uniqueCourts(from: courtsBySlot)

        return courts.map { court in
            CourtAvailability(
                id: "kustba-padel-\(court.id)",
                name: court.title,
                address: address,
                pricePerHour: court.price,
                rating: nil,
                imageUrl: court.imageURL,
                totalCourts: 1,
                timeSlots: slots.map { slot in
                    let matchingCourt = courtsBySlot[slot.time]?.first { $0.id == court.id }
                    let isBookable = slot.status == "available" && matchingCourt?.status == "active"

                    return TimeSlot(
                        time: slot.time,
                        status: isBookable ? .available : .booked,
                        isBookable: isBookable
                    )
                }
            )
        }
    }

    private static func uniqueCourts(from courtsBySlot: [String: [KustbaCourt]]) -> [KustbaCourt] {
        var courtsByID: [Int: KustbaCourt] = [:]

        for courts in courtsBySlot.values {
            for court in courts {
                courtsByID[court.id] = court
            }
        }

        return courtsByID.values.sorted { lhs, rhs in
            if lhs.courtNumber == rhs.courtNumber {
                return lhs.id < rhs.id
            }
            return lhs.courtNumber < rhs.courtNumber
        }
    }
}

struct KustbaPageContextExtractor {
    static func extractNonce(from html: String) -> String? {
        firstCapture(pattern: #""nonce"\s*:\s*"([^"]+)""#, in: html)
    }

    static func extractStartHour(from html: String) -> Int? {
        if let stringValue = firstCapture(pattern: #""start_hour"\s*:\s*"(\d+)""#, in: html) {
            return Int(stringValue)
        }

        if let numberValue = firstCapture(pattern: #""start_hour"\s*:\s*(\d+)"#, in: html) {
            return Int(numberValue)
        }

        return nil
    }

    static func extractSessionCookie(from headers: HTTPHeaders) -> String? {
        for setCookie in headers["Set-Cookie"] {
            let cookie = setCookie.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            if cookie.hasPrefix("PHPSESSID=") {
                return cookie
            }
        }

        return nil
    }

    private static func firstCapture(pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: string) else {
            return nil
        }

        return String(string[captureRange])
    }
}

enum KustbaBookingDateResolver {
    static func bookingDate(for date: String, time: String, startHour: Int) -> String {
        guard let hour = hour(from: time), hour < startHour else {
            return date
        }

        return addDays(1, to: date) ?? date
    }

    private static func hour(from time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard let hourPart = parts.first else {
            return nil
        }

        return Int(hourPart)
    }

    private static func addDays(_ days: Int, to date: String) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false

        guard let parsedDate = formatter.date(from: date),
              let adjustedDate = calendar.date(byAdding: .day, value: days, to: parsedDate) else {
            return nil
        }

        return formatter.string(from: adjustedDate)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tbilisi") ?? .current
        return calendar
    }
}

struct KustbaAJAXResponse<Value: Decodable>: Decodable {
    let success: Bool
    let data: Value
}

struct KustbaSlot: Decodable, Sendable {
    let time: String
    let status: String
}

struct KustbaCourtsData: Decodable, Sendable {
    let courts: [KustbaCourt]
}

struct KustbaCourt: Decodable, Sendable {
    let id: Int
    let title: String
    let price: Int?
    let courtNumber: Int
    let image: String?
    let status: String
    let reason: String?

    var imageURL: String? {
        guard let image,
              !image.contains("via.placeholder.com") else {
            return nil
        }

        return image
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case price
        case courtNumber = "court_number"
        case image
        case status
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(KustbaFlexibleInt.self, forKey: .id).value ?? 0

        id = decodedID
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Court #\(decodedID)"
        price = try container.decodeIfPresent(KustbaFlexibleInt.self, forKey: .price)?.value
        courtNumber = try container.decodeIfPresent(KustbaFlexibleInt.self, forKey: .courtNumber)?.value ?? decodedID
        image = try container.decodeIfPresent(String.self, forKey: .image)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

private struct KustbaPageContext: Sendable {
    let nonce: String
    let startHour: Int
    let sessionCookie: String?
}

private struct KustbaFlexibleInt: Decodable, Sendable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = nil
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = Int(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            value = Int(stringValue)
        } else {
            value = nil
        }
    }
}

private enum KustbaPadelError: Error, CustomStringConvertible {
    case emptyBody
    case missingNonce
    case unexpectedStatus(HTTPResponseStatus)

    var description: String {
        switch self {
        case .emptyBody:
            return "empty response body"
        case .missingNonce:
            return "could not find Kustba booking nonce"
        case .unexpectedStatus(let status):
            return "unexpected upstream status \(status)"
        }
    }
}
