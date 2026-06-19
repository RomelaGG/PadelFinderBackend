import Foundation
import Vapor

struct GymBreezeProvider: AvailabilityProvider {
    let id = "gym-breeze"

    private let name = "Gym Breeze"
    private let website = "https://gymbreeze.ge/eng"
    private let logo = "/logos/gym-breeze.png"
    private let coverImage = "https://stgymwebappprod001.blob.core.windows.net/appfiles/uploads/main%20(3).png"
    private let client: any Client
    private let apiBaseURL: String

    init(
        client: any Client,
        apiBaseURL: String = "https://backend.whiteriver-4e0c4713.germanywestcentral.azurecontainerapps.io/api/v1"
    ) {
        self.client = client
        self.apiBaseURL = apiBaseURL
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        async let locations = fetchLocations()
        async let courts = fetchCourts()

        let fetchedLocations = try await locations
        let fetchedCourts = try await courts
        let activeCourts = fetchedCourts.filter { $0.isActive && $0.isPadel }

        let courtsByLocationID = Dictionary(grouping: activeCourts, by: \.location)
        let activeLocations = fetchedLocations
            .filter { $0.isActive && courtsByLocationID[$0.id]?.isEmpty == false }

        guard !activeLocations.isEmpty else {
            return []
        }

        var availabilityByLocationID: [String: GymBreezeAvailabilityResponse] = [:]
        try await withThrowingTaskGroup(of: (String, GymBreezeAvailabilityResponse).self) { group in
            for location in activeLocations {
                group.addTask {
                    let availability = try await fetchAvailability(locationID: location.id, date: date)
                    return (location.id, availability)
                }
            }

            for try await result in group {
                availabilityByLocationID[result.0] = result.1
            }
        }

        let courtAvailability = GymBreezeMapper.map(
            locations: activeLocations,
            courtsByLocationID: courtsByLocationID,
            availabilityByLocationID: availabilityByLocationID,
            selectedDate: date
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

    private func fetchLocations() async throws -> [GymBreezeLocation] {
        try await getJSON(path: "/facilities/locations/")
    }

    private func fetchCourts() async throws -> [GymBreezeCourt] {
        try await getJSON(path: "/facilities/courts/")
    }

    private func fetchAvailability(locationID: String, date: String) async throws -> GymBreezeAvailabilityResponse {
        try await getJSON(
            path: "/bookings/availability/",
            queryItems: [
                ("location_id", locationID),
                ("date", date)
            ]
        )
    }

    private func getJSON<Response: Decodable>(
        path: String,
        queryItems: [(String, String)] = []
    ) async throws -> Response {
        let response = try await client.get(url(path: path, queryItems: queryItems), headers: headers())
        return try decode(response)
    }

    private func decode<Response: Decodable>(_ response: ClientResponse) throws -> Response {
        guard response.status == .ok else {
            throw GymBreezeError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let bytes = body.readBytes(length: body.readableBytes) else {
            throw GymBreezeError.emptyBody
        }

        return try JSONDecoder().decode(Response.self, from: Data(bytes))
    }

    private func headers() -> HTTPHeaders {
        var headers = HTTPHeaders()
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

enum GymBreezeMapper {
    static func map(
        locations: [GymBreezeLocation],
        courtsByLocationID: [String: [GymBreezeCourt]],
        availabilityByLocationID: [String: GymBreezeAvailabilityResponse],
        selectedDate: String,
        now: Date = Date()
    ) -> [CourtAvailability] {
        locations
            .sorted { lhs, rhs in
                displayName(for: lhs) < displayName(for: rhs)
            }
            .flatMap { location -> [CourtAvailability] in
                let courtCount = courtsByLocationID[location.id]?.count ?? 0
                guard courtCount > 0 else {
                    return []
                }

                let availableTimes = Set(
                    (availabilityByLocationID[location.id]?.availableSlots ?? [])
                        .compactMap { GymBreezeDate.time(fromISODateTime: $0.start) }
                )
                let slotDefinitions = slots(for: location, selectedDate: selectedDate, now: now)
                let groups = groupedByContiguousPrice(slotDefinitions)
                let usesMultiplePriceWindows = groups.count > 1

                return groups.map { group in
                    let label = "\(group.startTime) - \(group.endTime)"
                    let baseName = displayName(for: location)
                    let name = usesMultiplePriceWindows ? "\(baseName) \(label)" : baseName

                    return CourtAvailability(
                        id: "gym-breeze-\(location.id)-\(idSuffix(start: group.startTime, end: group.endTime))",
                        name: name,
                        address: location.address.en,
                        pricePerHour: group.pricePerHour,
                        rating: nil,
                        totalCourts: courtCount,
                        timeSlots: group.slots.map { slot in
                            let isBookable = !slot.isPast && availableTimes.contains(slot.time)

                            return TimeSlot(
                                time: slot.time,
                                status: isBookable ? .available : .booked,
                                isBookable: isBookable
                            )
                        }
                    )
                }
            }
    }

    private static func slots(
        for location: GymBreezeLocation,
        selectedDate: String,
        now: Date
    ) -> [GymBreezeSlotDefinition] {
        guard let selectedDayOfWeek = GymBreezeDate.weekdayIndex(from: selectedDate),
              let workingHours = location.workingHours.first(where: { $0.dayOfWeek == selectedDayOfWeek }),
              !workingHours.isClosed,
              let openMinutes = GymBreezeDate.minutes(from: workingHours.openTime),
              var closeMinutes = GymBreezeDate.minutes(from: workingHours.closeTime) else {
            return []
        }

        if closeMinutes <= openMinutes {
            closeMinutes += 24 * 60
        }

        let isToday = GymBreezeDate.dateString(from: now) == selectedDate
        let currentMinutes = GymBreezeDate.minutesSinceStartOfDay(from: now)
        var slots: [GymBreezeSlotDefinition] = []
        var slotStart = openMinutes

        while slotStart + 60 <= closeMinutes {
            let time = GymBreezeDate.formattedTime(minutes: slotStart)
            let endTime = GymBreezeDate.formattedTime(minutes: slotStart + 60)
            let normalizedStart = slotStart % (24 * 60)
            let isNextDaySlot = slotStart >= 24 * 60
            let isPast = isToday && !isNextDaySlot && normalizedStart <= currentMinutes

            slots.append(
                GymBreezeSlotDefinition(
                    time: time,
                    endTime: endTime,
                    isPast: isPast,
                    pricePerHour: pricePerHour(
                        for: time,
                        selectedDate: selectedDate,
                        dayOfWeek: selectedDayOfWeek,
                        pricingRules: location.pricingRules,
                        specialPrices: location.specialPrices
                    )
                )
            )

            slotStart += 60
        }

        return slots
    }

    private static func pricePerHour(
        for time: String,
        selectedDate: String,
        dayOfWeek: Int,
        pricingRules: [GymBreezePricingRule],
        specialPrices: [GymBreezeSpecialPrice]
    ) -> Int? {
        guard let slotMinutes = GymBreezeDate.minutes(from: time) else {
            return nil
        }

        for specialPrice in specialPrices where specialPrice.isActive != false {
            guard let startTime = specialPrice.startTime,
                  let endTime = specialPrice.endTime,
                  GymBreezeDate.dateString(fromISODateTime: startTime) == selectedDate,
                  let startMinutes = GymBreezeDate.minutesFromISODateTime(startTime),
                  var endMinutes = GymBreezeDate.minutesFromISODateTime(endTime) else {
                continue
            }

            if endMinutes <= startMinutes {
                endMinutes += 24 * 60
            }

            let normalizedSlotMinutes = slotMinutes < startMinutes ? slotMinutes + 24 * 60 : slotMinutes
            if normalizedSlotMinutes >= startMinutes && normalizedSlotMinutes < endMinutes {
                return GymBreezeDate.price(from: specialPrice.hourlyRate)
            }
        }

        for rule in pricingRules where rule.isActive {
            let compatibilityDayOfWeek = (1...7).contains(rule.dayOfWeek) ? rule.dayOfWeek - 1 : rule.dayOfWeek
            guard rule.dayOfWeek == dayOfWeek || compatibilityDayOfWeek == dayOfWeek,
                  let startMinutes = GymBreezeDate.minutes(from: rule.startHour),
                  let endMinutes = GymBreezeDate.minutes(from: rule.endHour) else {
                continue
            }

            if endMinutes < startMinutes {
                if slotMinutes >= startMinutes || slotMinutes < endMinutes {
                    return GymBreezeDate.price(from: rule.hourlyRate)
                }
            } else if slotMinutes >= startMinutes && slotMinutes < endMinutes {
                return GymBreezeDate.price(from: rule.hourlyRate)
            }
        }

        return nil
    }

    private static func groupedByContiguousPrice(_ slots: [GymBreezeSlotDefinition]) -> [GymBreezeSlotGroup] {
        var groups: [GymBreezeSlotGroup] = []
        var currentSlots: [GymBreezeSlotDefinition] = []
        var currentPrice: Int?

        for slot in slots {
            if currentSlots.isEmpty || currentPrice == slot.pricePerHour {
                currentSlots.append(slot)
                currentPrice = slot.pricePerHour
                continue
            }

            if let group = GymBreezeSlotGroup(slots: currentSlots, pricePerHour: currentPrice) {
                groups.append(group)
            }

            currentSlots = [slot]
            currentPrice = slot.pricePerHour
        }

        if let group = GymBreezeSlotGroup(slots: currentSlots, pricePerHour: currentPrice) {
            groups.append(group)
        }

        return groups
    }

    private static func displayName(for location: GymBreezeLocation) -> String {
        location.name.en ?? location.id
    }

    private static func idSuffix(start: String, end: String) -> String {
        "\(start)-\(end)"
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

struct GymBreezeSlotDefinition: Sendable {
    let time: String
    let endTime: String
    let isPast: Bool
    let pricePerHour: Int?
}

struct GymBreezeSlotGroup: Sendable {
    let startTime: String
    let endTime: String
    let pricePerHour: Int?
    let slots: [GymBreezeSlotDefinition]

    init?(slots: [GymBreezeSlotDefinition], pricePerHour: Int?) {
        guard let first = slots.first,
              let last = slots.last else {
            return nil
        }

        self.startTime = first.time
        self.endTime = last.endTime
        self.pricePerHour = pricePerHour
        self.slots = slots
    }
}

enum GymBreezeDate {
    static func weekdayIndex(from date: String) -> Int? {
        guard let date = selectedDateFormatter().date(from: date) else {
            return nil
        }

        let weekday = calendar.component(.weekday, from: date)
        return (weekday + 5) % 7
    }

    static func dateString(from date: Date) -> String {
        selectedDateFormatter().string(from: date)
    }

    static func dateString(fromISODateTime value: String) -> String? {
        guard let date = isoFormatter().date(from: value) else {
            return nil
        }

        return dateString(from: date)
    }

    static func time(fromISODateTime value: String) -> String? {
        guard let date = isoFormatter().date(from: value) else {
            return nil
        }

        return timeFormatter().string(from: date)
    }

    static func minutesFromISODateTime(_ value: String) -> Int? {
        guard let date = isoFormatter().date(from: value) else {
            return nil
        }

        return minutesSinceStartOfDay(from: date)
    }

    static func minutesSinceStartOfDay(from date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func minutes(from time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }

        return hour * 60 + minute
    }

    static func formattedTime(minutes: Int) -> String {
        let normalizedMinutes = ((minutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let hour = normalizedMinutes / 60
        let minute = normalizedMinutes % 60

        return "\(pad(hour)):\(pad(minute))"
    }

    static func price(from value: String) -> Int? {
        guard let double = Double(value) else {
            return nil
        }

        return Int(double.rounded())
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func selectedDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func timeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        formatter.isLenient = false
        return formatter
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "Asia/Tbilisi")
        return formatter
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tbilisi") ?? .current
        return calendar
    }
}

struct GymBreezeLocation: Decodable, Sendable {
    let id: String
    let workingHours: [GymBreezeWorkingHour]
    let pricingRules: [GymBreezePricingRule]
    let specialPrices: [GymBreezeSpecialPrice]
    let name: GymBreezeLocalizedText
    let address: GymBreezeLocalizedText
    let isActive: Bool

    init(
        id: String,
        workingHours: [GymBreezeWorkingHour],
        pricingRules: [GymBreezePricingRule],
        specialPrices: [GymBreezeSpecialPrice],
        name: GymBreezeLocalizedText,
        address: GymBreezeLocalizedText,
        isActive: Bool
    ) {
        self.id = id
        self.workingHours = workingHours
        self.pricingRules = pricingRules
        self.specialPrices = specialPrices
        self.name = name
        self.address = address
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workingHours = "working_hours"
        case pricingRules = "pricing_rules"
        case specialPrices = "special_prices"
        case name
        case address
        case isActive = "is_active"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        workingHours = try container.decodeIfPresent([GymBreezeWorkingHour].self, forKey: .workingHours) ?? []
        pricingRules = try container.decodeIfPresent([GymBreezePricingRule].self, forKey: .pricingRules) ?? []
        specialPrices = try container.decodeIfPresent([GymBreezeSpecialPrice].self, forKey: .specialPrices) ?? []
        name = try container.decodeIfPresent(GymBreezeLocalizedText.self, forKey: .name) ?? GymBreezeLocalizedText(en: nil, ka: nil)
        address = try container.decodeIfPresent(GymBreezeLocalizedText.self, forKey: .address) ?? GymBreezeLocalizedText(en: nil, ka: nil)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }
}

struct GymBreezeWorkingHour: Decodable, Sendable {
    let dayOfWeek: Int
    let dayName: String?
    let openTime: String
    let closeTime: String
    let isClosed: Bool

    private enum CodingKeys: String, CodingKey {
        case dayOfWeek = "day_of_week"
        case dayName = "day_name"
        case openTime = "open_time"
        case closeTime = "close_time"
        case isClosed = "is_closed"
    }
}

struct GymBreezePricingRule: Decodable, Sendable {
    let id: String?
    let dayOfWeek: Int
    let startHour: String
    let endHour: String
    let hourlyRate: String
    let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case dayOfWeek = "day_of_week"
        case startHour = "start_hour"
        case endHour = "end_hour"
        case hourlyRate = "hourly_rate"
        case isActive = "is_active"
    }
}

struct GymBreezeSpecialPrice: Decodable, Sendable {
    let id: String?
    let startTime: String?
    let endTime: String?
    let hourlyRate: String
    let isActive: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case hourlyRate = "hourly_rate"
        case isActive = "is_active"
    }
}

struct GymBreezeLocalizedText: Decodable, Sendable {
    let en: String?
    let ka: String?
}

struct GymBreezeCourt: Decodable, Sendable {
    let id: String
    let sportTypeName: GymBreezeLocalizedText?
    let locationName: GymBreezeLocalizedText?
    let number: Int?
    let displayName: GymBreezeLocalizedText?
    let isActive: Bool
    let location: String
    let sportType: String?

    var isPadel: Bool {
        sportType == "00000000-0000-0000-0000-000000000000" || sportTypeName?.en == "Padel"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sportTypeName = "sport_type_name"
        case locationName = "location_name"
        case number
        case displayName = "display_name"
        case isActive = "is_active"
        case location
        case sportType = "sport_type"
    }
}

struct GymBreezeAvailabilityResponse: Decodable, Sendable {
    let locationID: String
    let date: String
    let availableSlots: [GymBreezeAvailableSlot]

    private enum CodingKeys: String, CodingKey {
        case locationID = "location_id"
        case date
        case availableSlots = "available_slots"
    }
}

struct GymBreezeAvailableSlot: Decodable, Sendable {
    let start: String
    let end: String
}

private enum GymBreezeError: Error, CustomStringConvertible {
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
