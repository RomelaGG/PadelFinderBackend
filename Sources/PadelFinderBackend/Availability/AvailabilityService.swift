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

    /// Builds the production provider set. Kus Tba is read through
    /// `kustbaStore` rather than fetched inline, because it is an order of
    /// magnitude slower than every other provider and would otherwise set the
    /// latency of the whole endpoint.
    /// Each provider is gated by its switch in `ProviderFeatureFlags`.
    static func live(
        client: Client,
        kustbaStore: KustbaAvailabilityStore,
        logger: Logger
    ) -> AvailabilityService {
        var providers: [any AvailabilityProvider] = []

        if ProviderFeatureFlags.tbilisiPadel {
            providers.append(TbilisiPadelProvider(client: client))
        }
        if ProviderFeatureFlags.padelIsland {
            providers.append(PadelIslandProvider(client: client))
        }
        if ProviderFeatureFlags.lemansPadel {
            providers.append(LemansPadelProvider(client: client))
        }
        if ProviderFeatureFlags.kustbaPadel {
            providers.append(
                CachedKustbaProvider(
                    underlying: KustbaPadelProvider(client: client),
                    store: kustbaStore
                )
            )
        }
        if ProviderFeatureFlags.padelGldani {
            providers.append(PadelGldaniProvider(client: client))
        }
        if ProviderFeatureFlags.padelHub {
            providers.append(PadelHubProvider(client: client))
        }
        if ProviderFeatureFlags.gymBreeze {
            providers.append(GymBreezeProvider(client: client))
        }

        logger.notice(
            "Availability providers registered",
            metadata: ["providers": .string(providers.map(\.id).joined(separator: ", "))]
        )

        return AvailabilityService(
            providers: providers,
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
