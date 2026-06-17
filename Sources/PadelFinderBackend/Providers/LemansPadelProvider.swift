import Foundation
import NIOCore
import Vapor

struct LemansPadelProvider: AvailabilityProvider {
    let id = "lemans-padel"

    private let name = "Lemans Padel"
    private let website = "https://lemanspadel.ge/"
    private let logo = "https://lemanspadel.ge/wp-content/uploads/2024/11/Lemans-Logo-scaled.png"
    private let client: Client
    private let apiBaseURL: String
    private let durationMinutes: Int

    init(
        client: Client,
        apiBaseURL: String = "https://booking.lemanspadel.ge",
        durationMinutes: Int = 60
    ) {
        self.client = client
        self.apiBaseURL = apiBaseURL
        self.durationMinutes = durationMinutes
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        let courtsResponse: LemansCourtsResponse = try await getJSON(path: "/api/courts")
        let slotsResponse: LemansAvailabilityResponse = try await getJSON(
            path: "/api/availability",
            queryItems: [
                ("date", date),
                ("duration", String(durationMinutes))
            ]
        )

        let availableSlots = slotsResponse.slots.filter(\.available)
        let availableCourtsBySlot = try await fetchAvailableCourtsBySlot(
            date: date,
            slots: availableSlots
        )

        let courts = LemansPadelMapper.map(
            courts: courtsResponse.courts,
            slots: slotsResponse.slots,
            availableCourtsBySlot: availableCourtsBySlot
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

    private func fetchAvailableCourtsBySlot(
        date: String,
        slots: [LemansAvailabilitySlot]
    ) async throws -> [String: Set<Int>] {
        var courtsBySlot: [String: Set<Int>] = [:]

        try await withThrowingTaskGroup(of: (String, Set<Int>).self) { group in
            for slot in slots {
                group.addTask {
                    let response: LemansAvailableCourtsResponse = try await getJSON(
                        path: "/api/availability/courts",
                        queryItems: [
                            ("date", date),
                            ("start_time", slot.start),
                            ("duration", String(durationMinutes))
                        ]
                    )

                    return (slot.start, Set(response.courts.map(\.id)))
                }
            }

            for try await result in group {
                courtsBySlot[result.0] = result.1
            }
        }

        return courtsBySlot
    }

    private func getJSON<Response: Decodable>(
        path: String,
        queryItems: [(String, String)] = []
    ) async throws -> Response {
        let response = try await client.get(url(path: path, queryItems: queryItems))

        guard response.status == .ok else {
            throw LemansPadelError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let bytes = body.readBytes(length: body.readableBytes) else {
            throw LemansPadelError.emptyBody
        }

        return try JSONDecoder().decode(Response.self, from: Data(bytes))
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

enum LemansPadelMapper {
    static func map(
        courts: [LemansCourt],
        slots: [LemansAvailabilitySlot],
        availableCourtsBySlot: [String: Set<Int>]
    ) -> [CourtAvailability] {
        courts
            .sorted { lhs, rhs in
                if lhs.displayOrder == rhs.displayOrder {
                    return lhs.id < rhs.id
                }
                return lhs.displayOrder < rhs.displayOrder
            }
            .map { court in
                CourtAvailability(
                    id: "lemans-padel-\(court.id)",
                    name: court.displayName,
                    address: nil,
                    pricePerHour: court.durationPrices["60"],
                    rating: nil,
                    imageUrl: court.photo,
                    totalCourts: 1,
                    timeSlots: slots.map { slot in
                        let availableCourtIDs = availableCourtsBySlot[slot.start] ?? []
                        let isBookable = slot.available && availableCourtIDs.contains(court.id)

                        return TimeSlot(
                            time: slot.start,
                            status: isBookable ? .available : .booked,
                            isBookable: isBookable
                        )
                    }
                )
            }
    }
}

struct LemansCourtsResponse: Decodable, Sendable {
    let courts: [LemansCourt]
}

struct LemansCourt: Decodable, Sendable {
    let id: Int
    let courtNumber: Int?
    let name: String?
    let photo: String?
    let displayOrder: Int
    let durationPrices: [String: Int]

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        if let courtNumber {
            return "Court #\(courtNumber)"
        }

        return "Court #\(id)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case courtNumber = "court_number"
        case name
        case photo
        case displayOrder = "display_order"
        case durationPrices = "duration_prices"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int.self, forKey: .id)
        courtNumber = try container.decodeIfPresent(Int.self, forKey: .courtNumber)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        photo = try container.decodeIfPresent(String.self, forKey: .photo)
        displayOrder = try container.decodeIfPresent(Int.self, forKey: .displayOrder) ?? id
        durationPrices = try container.decodeIfPresent([String: Int].self, forKey: .durationPrices) ?? [:]
    }
}

struct LemansAvailabilityResponse: Decodable, Sendable {
    let date: String
    let duration: Int
    let slots: [LemansAvailabilitySlot]
}

struct LemansAvailabilitySlot: Decodable, Sendable {
    let start: String
    let end: String
    let available: Bool
    let availableCourts: Int

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case available
        case availableCourts = "available_courts"
    }
}

private struct LemansAvailableCourtsResponse: Decodable, Sendable {
    let courts: [LemansAvailableCourt]
}

private struct LemansAvailableCourt: Decodable, Sendable {
    let id: Int
}

private enum LemansPadelError: Error, CustomStringConvertible {
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
