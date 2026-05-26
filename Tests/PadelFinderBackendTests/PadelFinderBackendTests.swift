@testable import PadelFinderBackend
import Foundation
import Logging
import VaporTesting
import Testing

@Suite("App Tests")
struct PadelFinderBackendTests {
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Availability route returns selected date")
    func availabilityRouteReturnsSelectedDate() async throws {
        let service = MockAvailabilityService(companies: [sampleCompany()])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability?date=2026-05-27", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(AvailabilityResponse.self)
                #expect(response.date == "2026-05-27")
                #expect(response.companies.count == 1)
                #expect(response.companies.first?.id == "company-a")
                #expect(response.companies.first?.courts.first?.id == "court-a")
            })
        }

        let requestedDates = await service.requestedDates()
        #expect(requestedDates == ["2026-05-27"])
    }

    @Test("Availability route defaults missing date to today in Tbilisi")
    func availabilityRouteDefaultsMissingDate() async throws {
        let service = MockAvailabilityService(companies: [])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(AvailabilityResponse.self)
                #expect(response.date == TbilisiDate.todayString())
            })
        }
    }

    @Test("Availability route rejects invalid date")
    func availabilityRouteRejectsInvalidDate() async throws {
        let service = MockAvailabilityService(companies: [])

        try await withApp(configure: { app async throws in
            try routes(app, availabilityService: service)
        }) { app in
            try await app.testing().test(.GET, "availability?date=2026-99-99", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }

        let requestedDates = await service.requestedDates()
        #expect(requestedDates.isEmpty)
    }

    @Test("Tbilisi Padel mapper maps free, booked, and overnight slots")
    func tbilisiPadelMapperMapsSlots() throws {
        let json = """
        {
          "working_details": {
            "2026-05-27": [
              {
                "start_time": "10:00",
                "is_booked": 1,
                "disable_flag_timeslot": true,
                "max_capacity": 0
              },
              {
                "start_time": "09:00",
                "is_booked": 0,
                "disable_flag_timeslot": false,
                "max_capacity": "1"
              },
              {
                "start_time": "23:00",
                "end_time": "00:00",
                "is_booked": 0,
                "disable_flag_timeslot": false,
                "max_capacity": "1"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let court = TbilisiPadelCourt.defaultCourts[0]
        let availability = try TbilisiPadelMapper.map(data: json, date: "2026-05-27", court: court)

        #expect(availability.timeSlots.count == 3)
        #expect(availability.timeSlots[0] == TimeSlot(time: "09:00", status: .available, isBookable: true))
        #expect(availability.timeSlots[1] == TimeSlot(time: "10:00", status: .booked, isBookable: false))
        #expect(availability.timeSlots[2] == TimeSlot(time: "23:00", status: .available, isBookable: true))
    }

    @Test("Fresh cache avoids provider fetch")
    func freshCacheAvoidsProviderFetch() async {
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        let first = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        await provider.setResult(.success([sampleCompany(courtID: "court-b")]))
        let second = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))

        #expect(first.companies.first?.courts.first?.id == "court-a")
        #expect(second.companies.first?.courts.first?.id == "court-a")

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 1)
    }

    @Test("Expired cache refreshes provider data")
    func expiredCacheRefreshesProviderData() async {
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        _ = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        await provider.setResult(.success([sampleCompany(courtID: "court-b")]))
        await dateProvider.set(Date(timeIntervalSince1970: 121))
        let refreshed = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))

        #expect(refreshed.companies.first?.courts.first?.id == "court-b")

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 2)
    }

    @Test("Provider failure after cache expiry returns empty companies")
    func providerFailureAfterCacheExpiryReturnsEmptyCompanies() async {
        let provider = MockAvailabilityProvider(result: .success([sampleCompany(courtID: "court-a")]))
        let dateProvider = TestDateProvider(Date(timeIntervalSince1970: 0))
        let service = AvailabilityService(
            providers: [provider],
            cache: AvailabilityCache(ttlSeconds: 120),
            dateProvider: dateProvider
        )

        _ = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))
        await provider.setResult(.failure)
        await dateProvider.set(Date(timeIntervalSince1970: 121))
        let failedRefresh = await service.availability(for: "2026-05-27", logger: Logger(label: "test"))

        #expect(failedRefresh.companies.isEmpty)

        let fetchCount = await provider.fetchCount()
        #expect(fetchCount == 2)
    }
}

private enum MockProviderResult: Sendable {
    case success([PadelCompanyAvailability])
    case failure
}

private enum MockProviderError: Error {
    case failed
}

private actor MockAvailabilityProvider: AvailabilityProvider {
    nonisolated let id = "mock-provider"

    private var result: MockProviderResult
    private var count = 0

    init(result: MockProviderResult) {
        self.result = result
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        count += 1

        switch result {
        case .success(let companies):
            return companies
        case .failure:
            throw MockProviderError.failed
        }
    }

    func setResult(_ result: MockProviderResult) {
        self.result = result
    }

    func fetchCount() -> Int {
        count
    }
}

private actor MockAvailabilityService: AvailabilityServiceProtocol {
    private let companies: [PadelCompanyAvailability]
    private var dates: [String]

    init(companies: [PadelCompanyAvailability]) {
        self.companies = companies
        self.dates = []
    }

    func availability(for date: String, logger: Logger) async -> AvailabilityResponse {
        dates.append(date)
        return AvailabilityResponse(date: date, companies: companies)
    }

    func requestedDates() -> [String] {
        dates
    }
}

private actor TestDateProvider: DateProviding {
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() async -> Date {
        current
    }

    func set(_ date: Date) {
        current = date
    }
}

private func sampleCompany(companyID: String = "company-a", courtID: String = "court-a") -> PadelCompanyAvailability {
    PadelCompanyAvailability(
        id: companyID,
        name: "Padel Company",
        website: "https://example.com",
        courts: [sampleCourt(id: courtID)]
    )
}

private func sampleCourt(id: String = "court-a") -> CourtAvailability {
    CourtAvailability(
        id: id,
        name: "Padel Club Vake",
        address: "123 Rustaveli Ave",
        pricePerHour: 60,
        rating: 4.8,
        imageUrl: "https://example.com/court.jpg",
        totalCourts: 6,
        timeSlots: [
            TimeSlot(time: "09:00", status: .available, isBookable: true)
        ]
    )
}
