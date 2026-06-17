import Foundation
import NIOCore
import Vapor

struct TbilisiPadelProvider: AvailabilityProvider {
    let id = "tbilisi-padel"
    private let name = "Tbilisi Padel"
    private let website = "https://tbilisipadel.ge"
    private let logo = "/logos/tbilisi-padel.png"

    private let client: Client
    private let publicPageURL: URI
    private let ajaxURL: URI
    private let courts: [TbilisiPadelCourt]

    init(
        client: Client,
        publicPageURL: URI = URI(string: "https://tbilisipadel.ge/"),
        ajaxURL: URI = URI(string: "https://tbilisipadel.ge/wp-admin/admin-ajax.php"),
        courts: [TbilisiPadelCourt] = TbilisiPadelCourt.defaultCourts
    ) {
        self.client = client
        self.publicPageURL = publicPageURL
        self.ajaxURL = ajaxURL
        self.courts = courts
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        let nonce = try await fetchNonce()
        var courtResults: [CourtAvailability] = []
        var failureCount = 0

        await withTaskGroup(of: CourtFetchResult.self) { group in
            for court in courts {
                group.addTask {
                    do {
                        let availability = try await fetchAvailability(for: court, on: date, nonce: nonce)
                        return CourtFetchResult(court: availability, errorDescription: nil)
                    } catch {
                        return CourtFetchResult(court: nil, errorDescription: String(describing: error))
                    }
                }
            }

            for await result in group {
                if let court = result.court {
                    courtResults.append(court)
                } else {
                    failureCount += 1
                    if let error = result.errorDescription {
                        logger.warning(
                            "Tbilisi Padel court refresh failed",
                            metadata: ["error": .string(error)]
                        )
                    }
                }
            }
        }

        guard !courtResults.isEmpty || failureCount == 0 else {
            throw TbilisiPadelError.allCourtsFailed
        }

        return [
            PadelCompanyAvailability(
                id: id,
                name: name,
                website: website,
                logo: logo,
                courts: courtResults.sorted { $0.id < $1.id }
            )
        ]
    }

    private func fetchNonce() async throws -> String {
        let response = try await client.get(publicPageURL)
        guard response.status == .ok else {
            throw TbilisiPadelError.unexpectedStatus(response.status)
        }

        guard let html = response.body?.string else {
            throw TbilisiPadelError.emptyBody
        }

        guard let nonce = TbilisiPadelNonceExtractor.extractNonce(from: html) else {
            throw TbilisiPadelError.missingNonce
        }

        return nonce
    }

    private func fetchAvailability(
        for court: TbilisiPadelCourt,
        on date: String,
        nonce: String
    ) async throws -> CourtAvailability {
        let body = formURLEncoded([
            ("action", "bookingpress_fetch_timeslot_data"),
            ("service_id", court.serviceID),
            ("selected_service", court.serviceID),
            ("selected_date", date),
            ("is_preselect", "false"),
            ("_wpnonce", nonce)
        ])

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded; charset=UTF-8")
        headers.add(name: "Origin", value: "https://tbilisipadel.ge")
        headers.add(name: "Referer", value: "https://tbilisipadel.ge/")
        headers.add(name: "X-Requested-With", value: "XMLHttpRequest")

        let response = try await client.post(ajaxURL, headers: headers) { request in
            request.body = ByteBuffer(string: body)
        }

        guard response.status == .ok else {
            throw TbilisiPadelError.unexpectedStatus(response.status)
        }

        guard let responseBody = response.body else {
            throw TbilisiPadelError.emptyBody
        }

        return try TbilisiPadelMapper.map(data: responseBody, date: date, court: court)
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

struct TbilisiPadelCourt: Sendable, Equatable {
    let serviceID: String
    let id: String
    let name: String
    let address: String?
    let pricePerHour: Int?
    let rating: Double?
    let imageUrl: String?
    let totalCourts: Int

    static let defaultCourts: [TbilisiPadelCourt] = [
        TbilisiPadelCourt(
            serviceID: "1",
            id: "tbilisi-padel-ilia",
            name: "ილიას ბაღი",
            address: nil,
            pricePerHour: 60,
            rating: nil,
            imageUrl: "https://tbilisipadel.ge/wp-content/uploads/bookingpress/1719499912_1719499910_ilias-bagi-padel-17.jpg",
            totalCourts: 1
        ),
        TbilisiPadelCourt(
            serviceID: "4",
            id: "tbilisi-padel-mtatsminda",
            name: "მთაწმინდის პარკი",
            address: nil,
            pricePerHour: 60,
            rating: nil,
            imageUrl: "https://tbilisipadel.ge/wp-content/uploads/bookingpress/1724117662_1724117643_mtatmindis-parki-tbilisi-padel.jpg",
            totalCourts: 1
        )
    ]
}

enum TbilisiPadelMapper {
    private static let expectedSlotTimes = [
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
        "23:00"
    ]

    static func map(data: ByteBuffer, date: String, court: TbilisiPadelCourt) throws -> CourtAvailability {
        var body = data
        guard let bytes = body.readBytes(length: body.readableBytes) else {
            throw TbilisiPadelError.emptyBody
        }

        return try map(data: Data(bytes), date: date, court: court)
    }

    static func map(data: Data, date: String, court: TbilisiPadelCourt) throws -> CourtAvailability {
        let response = try JSONDecoder().decode(TbilisiPadelTimeslotResponse.self, from: data)
        let slots = response.workingDetails[date, default: []]
            .map(mapSlot)

        return CourtAvailability(
            id: court.id,
            name: court.name,
            address: court.address,
            pricePerHour: court.pricePerHour,
            rating: court.rating,
            imageUrl: court.imageUrl,
            totalCourts: court.totalCourts,
            timeSlots: fillUnavailableSlots(slots)
        )
    }

    private static func mapSlot(_ slot: TbilisiPadelSlot) -> TimeSlot {
        let isBooked = (slot.isBooked.value ?? 0) != 0
        let capacity = slot.maxCapacity.value ?? slot.maxTotalCapacity.value ?? 0
        let isBookable = !isBooked && slot.disableFlagTimeslot != true && capacity > 0

        return TimeSlot(
            time: slot.startTime,
            status: isBookable ? .available : .booked,
            isBookable: isBookable
        )
    }

    private static func fillUnavailableSlots(_ slots: [TimeSlot]) -> [TimeSlot] {
        let slotsByTime = Dictionary(slots.map { ($0.time, $0) }, uniquingKeysWith: { first, _ in first })
        let expectedSlots = expectedSlotTimes.map { time in
            slotsByTime[time] ?? TimeSlot(time: time, status: .booked, isBookable: false)
        }
        let extraSlots = slots
            .filter { !expectedSlotTimes.contains($0.time) }
            .sorted { slotSortKey($0.time) < slotSortKey($1.time) }

        return expectedSlots + extraSlots
    }

    private static func slotSortKey(_ time: String) -> Int {
        guard let minutes = minutes(from: time) else {
            return Int.max
        }

        return minutes < 9 * 60 ? minutes + 24 * 60 : minutes
    }

    private static func minutes(from time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }

        return hour * 60 + minute
    }
}

enum TbilisiPadelNonceExtractor {
    static func extractNonce(from html: String) -> String? {
        guard let inputTag = firstMatch(
            pattern: #"<input\b[^>]*\bid=["']_wpnonce["'][^>]*>"#,
            in: html
        ) else {
            return nil
        }

        return firstCapture(pattern: #"\bvalue=["']([^"']+)["']"#, in: inputTag)
    }

    private static func firstMatch(pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let matchRange = Range(match.range, in: string) else {
            return nil
        }

        return String(string[matchRange])
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

private struct CourtFetchResult: Sendable {
    let court: CourtAvailability?
    let errorDescription: String?
}

private struct TbilisiPadelTimeslotResponse: Decodable {
    let workingDetails: [String: [TbilisiPadelSlot]]

    private enum CodingKeys: String, CodingKey {
        case workingDetails = "working_details"
    }
}

private struct TbilisiPadelSlot: Decodable {
    let startTime: String
    let isBooked: FlexibleInt
    let disableFlagTimeslot: Bool?
    let maxCapacity: FlexibleInt
    let maxTotalCapacity: FlexibleInt

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case isBooked = "is_booked"
        case disableFlagTimeslot = "disable_flag_timeslot"
        case maxCapacity = "max_capacity"
        case maxTotalCapacity = "max_total_capacity"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try container.decode(String.self, forKey: .startTime)
        isBooked = try container.decodeIfPresent(FlexibleInt.self, forKey: .isBooked) ?? FlexibleInt(nil)
        disableFlagTimeslot = try container.decodeIfPresent(Bool.self, forKey: .disableFlagTimeslot)
        maxCapacity = try container.decodeIfPresent(FlexibleInt.self, forKey: .maxCapacity) ?? FlexibleInt(nil)
        maxTotalCapacity = try container.decodeIfPresent(FlexibleInt.self, forKey: .maxTotalCapacity) ?? FlexibleInt(nil)
    }
}

private struct FlexibleInt: Decodable, Sendable {
    let value: Int?

    init(_ value: Int?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = nil
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self) {
            value = Int(stringValue)
        } else {
            value = nil
        }
    }
}

private enum TbilisiPadelError: Error, CustomStringConvertible {
    case allCourtsFailed
    case emptyBody
    case missingNonce
    case unexpectedStatus(HTTPResponseStatus)

    var description: String {
        switch self {
        case .allCourtsFailed:
            return "all Tbilisi Padel court requests failed"
        case .emptyBody:
            return "empty response body"
        case .missingNonce:
            return "could not find _wpnonce on Tbilisi Padel page"
        case .unexpectedStatus(let status):
            return "unexpected upstream status \(status)"
        }
    }
}

private extension ByteBuffer {
    var string: String? {
        getString(at: readerIndex, length: readableBytes)
    }
}
