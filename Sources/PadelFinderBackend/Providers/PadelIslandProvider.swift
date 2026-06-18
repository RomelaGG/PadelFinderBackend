import Foundation
import NIOCore
import Vapor

struct PadelIslandProvider: AvailabilityProvider {
    let id = "padel-island"

    private let name = "Padel Island"
    private let website = "https://www.padelisland.ge/"
    private let logo = "/logos/padel-island.png"
    private let coverImage = "https://www.padelisland.ge/og-image.jpg"
    private let client: Client
    private let gridPageURL: URI
    private let calendarsURL: URI
    private let gridURL: URI

    init(
        client: Client,
        gridPageURL: URI = URI(string: "https://booking.padelisland.ge/Booking/Grid.aspx"),
        calendarsURL: URI = URI(string: "https://booking.padelisland.ge/booking/srvc.aspx/ObtenerCuadros"),
        gridURL: URI = URI(string: "https://booking.padelisland.ge/booking/srvc.aspx/ObtenerCuadro")
    ) {
        self.client = client
        self.gridPageURL = gridPageURL
        self.calendarsURL = calendarsURL
        self.gridURL = gridURL
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        guard let bookingDate = PadelIslandDateFormatter.bookingDate(fromISODate: date) else {
            throw PadelIslandError.invalidDate(date)
        }

        let context = try await fetchPageContext()
        let calendars: PadelIslandWebMethodResponse<[PadelIslandCalendar]> = try await postJSON(
            to: calendarsURL,
            payload: PadelIslandCalendarsRequest(key: context.key),
            sessionCookie: context.sessionCookie
        )

        var courts: [CourtAvailability] = []
        var failureCount = 0

        await withTaskGroup(of: PadelIslandCalendarFetchResult.self) { group in
            for calendar in calendars.d {
                group.addTask {
                    do {
                        let response: PadelIslandWebMethodResponse<PadelIslandGrid> = try await postJSON(
                            to: gridURL,
                            payload: PadelIslandGridRequest(
                                idCuadro: calendar.id,
                                fecha: bookingDate,
                                key: context.key
                            ),
                            sessionCookie: context.sessionCookie
                        )

                        return PadelIslandCalendarFetchResult(
                            courts: PadelIslandMapper.map(grid: response.d, date: date),
                            errorDescription: nil
                        )
                    } catch {
                        return PadelIslandCalendarFetchResult(
                            courts: [],
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }

            for await result in group {
                courts.append(contentsOf: result.courts)

                if let errorDescription = result.errorDescription {
                    failureCount += 1
                    logger.warning(
                        "Padel Island timetable refresh failed",
                        metadata: ["error": .string(errorDescription)]
                    )
                }
            }
        }

        guard !courts.isEmpty || failureCount == 0 else {
            throw PadelIslandError.allCalendarsFailed
        }

        guard !courts.isEmpty else {
            return []
        }

        return [
            PadelCompanyAvailability(
                id: id,
                name: name,
                website: website,
                logo: logo,
                coverImage: coverImage,
                courts: courts.sorted { lhs, rhs in
                    if lhs.name == rhs.name {
                        return lhs.id < rhs.id
                    }
                    return lhs.name < rhs.name
                }
            )
        ]
    }

    private func fetchPageContext() async throws -> PadelIslandPageContext {
        let response = try await client.get(gridPageURL)
        guard response.status == .ok else {
            throw PadelIslandError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let htmlBytes = body.readBytes(length: body.readableBytes) else {
            throw PadelIslandError.emptyBody
        }
        let html = String(decoding: htmlBytes, as: UTF8.self)

        guard let key = PadelIslandPageContextExtractor.extractKey(from: html) else {
            throw PadelIslandError.missingKey
        }

        guard let sessionCookie = PadelIslandPageContextExtractor.extractSessionCookie(from: response.headers) else {
            throw PadelIslandError.missingSessionCookie
        }

        return PadelIslandPageContext(key: key, sessionCookie: sessionCookie)
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        to url: URI,
        payload: Request,
        sessionCookie: String
    ) async throws -> Response {
        let bytes = try JSONEncoder().encode(payload)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json; charset=utf-8")
        headers.add(name: "Accept", value: "application/json, text/javascript, */*; q=0.01")
        headers.add(name: "Cookie", value: sessionCookie)
        headers.add(name: "Origin", value: "https://booking.padelisland.ge")
        headers.add(name: "Referer", value: "https://booking.padelisland.ge/Booking/Grid.aspx")
        headers.add(name: "X-Requested-With", value: "XMLHttpRequest")

        let response = try await client.post(url, headers: headers) { request in
            request.body = ByteBuffer(bytes: [UInt8](bytes))
        }

        guard response.status == .ok else {
            throw PadelIslandError.unexpectedStatus(response.status)
        }

        guard var body = response.body,
              let responseBytes = body.readBytes(length: body.readableBytes) else {
            throw PadelIslandError.emptyBody
        }

        return try JSONDecoder().decode(Response.self, from: Data(responseBytes))
    }
}

enum PadelIslandMapper {
    static func map(data: Data, date: String) throws -> [CourtAvailability] {
        let response = try JSONDecoder().decode(PadelIslandWebMethodResponse<PadelIslandGrid>.self, from: data)
        return map(grid: response.d, date: date)
    }

    static func map(grid: PadelIslandGrid, date: String) -> [CourtAvailability] {
        grid.columns.map { column in
            CourtAvailability(
                id: "padel-island-\(grid.id)-\(column.id)",
                name: column.text,
                address: nil,
                pricePerHour: nil,
                rating: nil,
                totalCourts: 1,
                timeSlots: mapSlots(grid: grid, column: column, date: date)
            )
        }
    }

    private static func mapSlots(grid: PadelIslandGrid, column: PadelIslandColumn, date: String) -> [TimeSlot] {
        if !column.fixedSchedules.isEmpty && column.combinesFixedAndFree != true {
            return mapFixedSchedules(grid: grid, column: column, date: date)
        }

        let range = tableRange(grid: grid)
        let interval = slotInterval(partsPerHour: grid.partsPerHour)
        let bookedRanges = column.occupations.compactMap {
            normalizedRange(
                start: $0.startTime,
                end: $0.endTime,
                tableStart: range.start,
                tableEnd: range.end
            )
        }

        return stride(from: range.start, to: range.end, by: interval).map { slotStart in
            let slotEnd = min(slotStart + interval, range.end)
            let isBooked = bookedRanges.contains { overlaps(lhsStart: slotStart, lhsEnd: slotEnd, rhs: $0) }
            let isInBookingWindow = isWithinBookingWindow(slotStart, grid: grid, date: date)
            let isBookable = !isBooked && isInBookingWindow

            return TimeSlot(
                time: formattedTime(minutes: slotStart),
                status: isBookable ? .available : .booked,
                isBookable: isBookable
            )
        }
    }

    private static func mapFixedSchedules(
        grid: PadelIslandGrid,
        column: PadelIslandColumn,
        date: String
    ) -> [TimeSlot] {
        let range = tableRange(grid: grid)
        let occupiedRanges = column.occupations.compactMap {
            normalizedRange(
                start: $0.startTime,
                end: $0.endTime,
                tableStart: range.start,
                tableEnd: range.end
            )
        }

        return column.fixedSchedules.compactMap { fixedSchedule in
            guard let fixedRange = normalizedRange(
                start: fixedSchedule.startTime,
                end: fixedSchedule.endTime,
                tableStart: range.start,
                tableEnd: range.end
            ) else {
                return nil
            }

            let isBooked = occupiedRanges.contains {
                overlaps(lhsStart: fixedRange.start, lhsEnd: fixedRange.end, rhs: $0)
            }
            let isInBookingWindow = isWithinBookingWindow(fixedRange.start, grid: grid, date: date)
            let isBookable = fixedSchedule.clickable != false && !isBooked && isInBookingWindow

            return TimeSlot(
                time: formattedTime(minutes: fixedRange.start),
                status: isBookable ? .available : .booked,
                isBookable: isBookable
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func tableRange(grid: PadelIslandGrid) -> (start: Int, end: Int) {
        let start = minutes(from: grid.startTime) ?? 0
        var end = minutes(from: grid.endTime) ?? 24 * 60

        if end <= start {
            end += 24 * 60
        }

        return (start, end)
    }

    private static func slotInterval(partsPerHour: Int) -> Int {
        guard partsPerHour > 0 else {
            return 60
        }

        return max(1, 60 / partsPerHour)
    }

    private static func normalizedRange(
        start: String,
        end: String,
        tableStart: Int,
        tableEnd: Int
    ) -> (start: Int, end: Int)? {
        guard var startMinute = minutes(from: start),
              var endMinute = minutes(from: end) else {
            return nil
        }

        if tableEnd > 24 * 60 {
            if startMinute < tableStart {
                startMinute += 24 * 60
            }

            if endMinute <= tableStart {
                endMinute += 24 * 60
            }
        }

        if endMinute <= startMinute {
            endMinute += 24 * 60
        }

        return (startMinute, endMinute)
    }

    private static func overlaps(lhsStart: Int, lhsEnd: Int, rhs: (start: Int, end: Int)) -> Bool {
        lhsStart < rhs.end && rhs.start < lhsEnd
    }

    private static func isWithinBookingWindow(_ slotStart: Int, grid: PadelIslandGrid, date: String) -> Bool {
        let startLimit = PadelIslandDateFormatter.relativeMinutes(
            fromBookingDateTime: grid.bookingStartDateTime,
            toISODate: date
        )
        let endLimit = PadelIslandDateFormatter.relativeMinutes(
            fromBookingDateTime: grid.bookingEndDateTime,
            toISODate: date
        )

        if let startLimit, slotStart < startLimit {
            return false
        }

        if let endLimit, slotStart >= endLimit {
            return false
        }

        return true
    }

    private static func minutes(from time: String?) -> Int? {
        guard let time else {
            return nil
        }

        let parts = time.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }

        return hour * 60 + minute
    }

    private static func formattedTime(minutes: Int) -> String {
        let normalizedMinutes = ((minutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let hour = normalizedMinutes / 60
        let minute = normalizedMinutes % 60

        return "\(pad(hour)):\(pad(minute))"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

struct PadelIslandPageContextExtractor {
    static func extractKey(from html: String) -> String? {
        firstCapture(pattern: #"hl90njda2b89k\s*=\s*'([^']+)'"#, in: html)
    }

    static func extractSessionCookie(from headers: HTTPHeaders) -> String? {
        for setCookie in headers["Set-Cookie"] {
            let cookie = setCookie.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            if cookie.hasPrefix("ASP.NET_SessionId=") {
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

enum PadelIslandDateFormatter {
    static func bookingDate(fromISODate isoDate: String) -> String? {
        guard let components = isoDateComponents(isoDate) else {
            return nil
        }

        return "\(pad(components.day))/\(pad(components.month))/\(components.year)"
    }

    static func relativeMinutes(fromBookingDateTime dateTime: String?, toISODate isoDate: String) -> Int? {
        guard let dateTime,
              let requestedDate = date(fromISODate: isoDate),
              let comparedDate = date(fromBookingDateTime: dateTime) else {
            return nil
        }

        return Int(comparedDate.timeIntervalSince(requestedDate) / 60)
    }

    private static func date(fromISODate isoDate: String) -> Date? {
        guard let components = isoDateComponents(isoDate) else {
            return nil
        }

        return calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 0,
                minute: 0
            )
        )
    }

    private static func date(fromBookingDateTime dateTime: String) -> Date? {
        let parts = dateTime.split(separator: " ")
        guard parts.count == 2 else {
            return nil
        }

        let dateParts = parts[0].split(separator: "/")
        let timeParts = parts[1].split(separator: ":")

        guard dateParts.count == 3,
              timeParts.count == 2,
              let day = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let year = Int(dateParts[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]) else {
            return nil
        }

        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )
    }

    private static func isoDateComponents(_ isoDate: String) -> (year: Int, month: Int, day: Int)? {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        return (year, month, day)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tbilisi") ?? .current
        return calendar
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

struct PadelIslandWebMethodResponse<Value: Decodable>: Decodable {
    let d: Value
}

private struct PadelIslandPageContext: Sendable {
    let key: String
    let sessionCookie: String
}

private struct PadelIslandCalendarFetchResult: Sendable {
    let courts: [CourtAvailability]
    let errorDescription: String?
}

private struct PadelIslandCalendarsRequest: Encodable {
    let key: String
}

private struct PadelIslandGridRequest: Encodable {
    let idCuadro: Int
    let fecha: String
    let key: String
}

private struct PadelIslandCalendar: Decodable, Sendable {
    let id: Int
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Nombre"
    }
}

struct PadelIslandGrid: Decodable, Sendable {
    let id: Int
    let name: String?
    let partsPerHour: Int
    let startTime: String?
    let endTime: String?
    let bookingStartDateTime: String?
    let bookingEndDateTime: String?
    let columns: [PadelIslandColumn]

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Nombre"
        case partsPerHour = "PartesPorHora"
        case startTime = "StrHoraInicio"
        case endTime = "StrHoraFin"
        case bookingStartDateTime = "StrFechaHoraInicioReservas"
        case bookingEndDateTime = "StrFechaHoraFinReservas"
        case columns = "Columnas"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        partsPerHour = try container.decodeIfPresent(Int.self, forKey: .partsPerHour) ?? 1
        startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(String.self, forKey: .endTime)
        bookingStartDateTime = try container.decodeIfPresent(String.self, forKey: .bookingStartDateTime)
        bookingEndDateTime = try container.decodeIfPresent(String.self, forKey: .bookingEndDateTime)
        columns = try container.decodeIfPresent([PadelIslandColumn].self, forKey: .columns) ?? []
    }
}

struct PadelIslandColumn: Decodable, Sendable {
    let id: String
    let text: String
    let combinesFixedAndFree: Bool?
    let fixedSchedules: [PadelIslandEvent]
    let occupations: [PadelIslandEvent]

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case primaryText = "TextoPrincipal"
        case secondaryText = "TextoSecundario"
        case combinesFixedAndFree = "CombinaHorariosFijosYLibres"
        case fixedSchedules = "HorariosFijos"
        case occupations = "Ocupaciones"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primaryText = try container.decodeIfPresent(String.self, forKey: .primaryText)
        let secondaryText = try container.decodeIfPresent(String.self, forKey: .secondaryText)

        id = try container.decode(FlexibleString.self, forKey: .id).value
        text = PadelIslandColumn.displayText(primaryText: primaryText, secondaryText: secondaryText)
        combinesFixedAndFree = try container.decodeIfPresent(Bool.self, forKey: .combinesFixedAndFree)
        fixedSchedules = try container.decodeIfPresent([PadelIslandEvent].self, forKey: .fixedSchedules) ?? []
        occupations = try container.decodeIfPresent([PadelIslandEvent].self, forKey: .occupations) ?? []
    }

    private static func displayText(primaryText: String?, secondaryText: String?) -> String {
        let primary = primaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secondary = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if primary.isEmpty {
            return secondary.isEmpty || secondary == "-" ? "Padel Island Court" : secondary
        }

        if secondary.isEmpty || secondary == "-" {
            return primary
        }

        return "\(primary) \(secondary)"
    }
}

struct PadelIslandEvent: Decodable, Sendable {
    let startTime: String
    let endTime: String
    let clickable: Bool?

    private enum CodingKeys: String, CodingKey {
        case startTime = "StrHoraInicio"
        case endTime = "StrHoraFin"
        case clickable = "Clickable"
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else {
            value = ""
        }
    }
}

private enum PadelIslandError: Error, CustomStringConvertible {
    case allCalendarsFailed
    case emptyBody
    case invalidDate(String)
    case missingKey
    case missingSessionCookie
    case unexpectedStatus(HTTPResponseStatus)

    var description: String {
        switch self {
        case .allCalendarsFailed:
            return "all Padel Island timetable requests failed"
        case .emptyBody:
            return "empty response body"
        case .invalidDate(let date):
            return "invalid date \(date)"
        case .missingKey:
            return "could not find Padel Island booking key"
        case .missingSessionCookie:
            return "could not find Padel Island session cookie"
        case .unexpectedStatus(let status):
            return "unexpected upstream status \(status)"
        }
    }
}
