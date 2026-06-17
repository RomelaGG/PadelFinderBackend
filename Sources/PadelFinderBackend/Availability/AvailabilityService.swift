import Foundation
import Vapor

protocol AvailabilityProvider: Sendable {
    var id: String { get }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability]
}

protocol AvailabilityServiceProtocol: Sendable {
    func availability(for date: String, logger: Logger) async -> AvailabilityResponse
    func companyAvailability(forCompany companyId: String, date: String, logger: Logger) async -> PadelCompanyAvailability?
}

protocol DateProviding: Sendable {
    func now() async -> Date
}

struct SystemDateProvider: DateProviding {
    func now() async -> Date {
        Date()
    }
}

final class AvailabilityService: AvailabilityServiceProtocol, Sendable {
    private struct ProviderFetchResult: Sendable {
        let companies: [PadelCompanyAvailability]
        let succeeded: Bool
    }

    private let providers: [any AvailabilityProvider]
    private let cache: AvailabilityCache
    private let dateProvider: any DateProviding

    init(
        providers: [any AvailabilityProvider],
        cache: AvailabilityCache = AvailabilityCache(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.providers = providers
        self.cache = cache
        self.dateProvider = dateProvider
    }

    static func live(client: Client) -> AvailabilityService {
        AvailabilityService(
            providers: [
                TbilisiPadelProvider(client: client),
                PadelIslandProvider(client: client),
                LemansPadelProvider(client: client),
                KustbaPadelProvider(client: client)
            ],
            cache: AvailabilityCache(ttlSeconds: 120)
        )
    }

    func availability(for date: String, logger: Logger) async -> AvailabilityResponse {
        let companies = await companies(for: date, logger: logger)
        return AvailabilityResponse(date: date, companies: companies)
    }

    func companyAvailability(forCompany companyId: String, date: String, logger: Logger) async -> PadelCompanyAvailability? {
        let companies = await companies(for: date, logger: logger)
        return companies.first { $0.id == companyId }
    }

    /// Returns every company for `date`, serving a fresh cache entry when present
    /// and otherwise refreshing (and re-caching) the whole day from the providers.
    private func companies(for date: String, logger: Logger) async -> [PadelCompanyAvailability] {
        let now = await dateProvider.now()

        if let cachedCompanies = await cache.freshValue(for: date, now: now) {
            return cachedCompanies
        }

        var companies: [PadelCompanyAvailability] = []
        var hasSuccessfulRefresh = false

        await withTaskGroup(of: ProviderFetchResult.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let providerCompanies = try await provider.fetchAvailability(on: date, logger: logger)
                        return ProviderFetchResult(companies: providerCompanies, succeeded: true)
                    } catch {
                        logger.warning(
                            "Availability provider failed",
                            metadata: [
                                "provider": .string(provider.id),
                                "date": .string(date),
                                "error": .string(String(describing: error))
                            ]
                        )
                        return ProviderFetchResult(companies: [], succeeded: false)
                    }
                }
            }

            for await result in group {
                hasSuccessfulRefresh = hasSuccessfulRefresh || result.succeeded
                companies.append(contentsOf: result.companies)
            }
        }

        companies.sort { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.id < rhs.id
            }
            return lhs.name < rhs.name
        }

        if hasSuccessfulRefresh {
            await cache.store(companies, for: date, now: now)
        }

        return companies
    }
}
