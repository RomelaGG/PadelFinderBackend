import Foundation
import Vapor

/// Serves Kus Tba availability from `KustbaAvailabilityStore` instead of hitting
/// the upstream site on the request path.
///
/// Falls back to a live fetch only when the store has nothing for the requested
/// date — a cold boot, or a date outside the refresh window. Returning no data
/// would silently drop the venue from `/availability`, so a slow first response
/// is preferred; the fetch is coalesced and cached, so it happens at most once
/// per date.
struct CachedKustbaProvider: AvailabilityProvider {
    let id: String

    private let underlying: any AvailabilityProvider
    private let store: KustbaAvailabilityStore
    private let dateProvider: any DateProviding

    init(
        underlying: any AvailabilityProvider,
        store: KustbaAvailabilityStore,
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.id = underlying.id
        self.underlying = underlying
        self.store = store
        self.dateProvider = dateProvider
    }

    func fetchAvailability(on date: String, logger: Logger) async throws -> [PadelCompanyAvailability] {
        let now = await dateProvider.now()

        if let cached = await store.cachedValue(for: date, now: now) {
            return cached
        }

        let underlying = self.underlying
        let id = self.id

        return try await store.loadValue(for: date, now: now) {
            // Logged inside the closure so this counts real upstream fetches:
            // callers that coalesce onto an in-flight request do not log a miss.
            logger.notice(
                "Kus Tba warm cache miss, fetching inline",
                metadata: ["provider": .string(id), "date": .string(date)]
            )

            return try await underlying.fetchAvailability(on: date, logger: logger)
        }
    }
}

/// Periodically refreshes `KustbaAvailabilityStore` so the request path always
/// finds a warm entry.
struct KustbaRefreshService: Sendable {
    struct Configuration: Sendable {
        /// Last day of the fast tier, counted from today. `1` means today and tomorrow.
        var nearDaysAhead: Int
        /// Last day kept warm at all, counted from today.
        var farDaysAhead: Int
        /// Refresh cadence for the near tier.
        var nearInterval: TimeInterval
        /// Refresh cadence for the far tier.
        var farInterval: TimeInterval
        /// How long a date outside the window stays warm after its last request.
        var idleTimeout: TimeInterval
        /// How often the scheduler re-checks what is due. Costs no upstream
        /// requests on its own, so it only bounds scheduling precision.
        var tickInterval: TimeInterval

        init(
            nearDaysAhead: Int = 1,
            farDaysAhead: Int = 6,
            nearInterval: TimeInterval = 300,
            farInterval: TimeInterval = 1800,
            idleTimeout: TimeInterval = 1800,
            tickInterval: TimeInterval = 30
        ) {
            self.nearDaysAhead = nearDaysAhead
            self.farDaysAhead = farDaysAhead
            self.nearInterval = nearInterval
            self.farInterval = farInterval
            self.idleTimeout = idleTimeout
            self.tickInterval = tickInterval
        }

        /// Reads overrides from the environment so the cadence can be tuned
        /// without a rebuild.
        static func fromEnvironment() -> Configuration {
            var configuration = Configuration()

            if let value = Environment.get("KUSTBA_NEAR_DAYS_AHEAD").flatMap(Int.init), value >= 0 {
                configuration.nearDaysAhead = value
            }

            if let value = Environment.get("KUSTBA_FAR_DAYS_AHEAD").flatMap(Int.init), value >= 0 {
                configuration.farDaysAhead = value
            }

            if let value = Environment.get("KUSTBA_NEAR_INTERVAL_SECONDS").flatMap(Double.init), value > 0 {
                configuration.nearInterval = value
            }

            if let value = Environment.get("KUSTBA_FAR_INTERVAL_SECONDS").flatMap(Double.init), value > 0 {
                configuration.farInterval = value
            }

            if let value = Environment.get("KUSTBA_REFRESH_IDLE_SECONDS").flatMap(Double.init), value > 0 {
                configuration.idleTimeout = value
            }

            return configuration
        }

        /// Splits the warm window into the fast and slow tiers for `now`.
        func tiers(now: Date) -> (near: [String], far: [String]) {
            let allDates = TbilisiDate.upcomingDateStrings(
                daysAhead: max(nearDaysAhead, farDaysAhead),
                now: now
            )
            let nearCount = min(nearDaysAhead + 1, allDates.count)

            return (Array(allDates.prefix(nearCount)), Array(allDates.dropFirst(nearCount)))
        }
    }

    private let provider: any AvailabilityProvider
    private let store: KustbaAvailabilityStore
    private let configuration: Configuration
    private let dateProvider: any DateProviding

    init(
        provider: any AvailabilityProvider,
        store: KustbaAvailabilityStore,
        configuration: Configuration = Configuration(),
        dateProvider: any DateProviding = SystemDateProvider()
    ) {
        self.provider = provider
        self.store = store
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    /// Runs refresh cycles until the surrounding task is cancelled.
    func run(logger: Logger) async {
        while !Task.isCancelled {
            await refreshOnce(logger: logger)

            guard !Task.isCancelled else {
                return
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(configuration.tickInterval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// Refreshes every date that is currently due, sequentially.
    ///
    /// Sequential on purpose: a single date already fans out one request per
    /// slot, and firing several dates at once measurably slows Kus Tba's site
    /// down rather than speeding us up.
    func refreshOnce(logger: Logger) async {
        let now = await dateProvider.now()
        let today = TbilisiDate.todayString(now: now)
        let tiers = configuration.tiers(now: now)
        let dates = await store.datesDueForRefresh(
            nearDates: tiers.near,
            farDates: tiers.far,
            nearInterval: configuration.nearInterval,
            farInterval: configuration.farInterval,
            today: today,
            now: now,
            idleTimeout: configuration.idleTimeout
        )

        guard !dates.isEmpty else {
            return
        }

        var refreshed = 0

        for date in dates {
            guard !Task.isCancelled else {
                return
            }

            let startedAt = await dateProvider.now()

            do {
                let companies = try await provider.fetchAvailability(on: date, logger: logger)
                let finishedAt = await dateProvider.now()
                await store.store(companies, for: date, now: finishedAt)

                refreshed += 1

                logger.debug(
                    "Refreshed Kus Tba availability",
                    metadata: [
                        "provider": .string(provider.id),
                        "date": .string(date),
                        "duration": .stringConvertible(finishedAt.timeIntervalSince(startedAt))
                    ]
                )
            } catch {
                // Keep whatever is already cached: stale data still beats
                // dropping the venue out of the response entirely.
                logger.warning(
                    "Kus Tba availability refresh failed",
                    metadata: [
                        "provider": .string(provider.id),
                        "date": .string(date),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }

        // Surfaced at info so a silently dead refresher is visible in logs: if
        // these stop, `/availability` quietly regresses to fetching Kus Tba inline.
        let completedAt = await dateProvider.now()
        logger.info(
            "Kus Tba refresh cycle complete",
            metadata: [
                "refreshed": .stringConvertible(refreshed),
                "requested": .stringConvertible(dates.count),
                "duration": .stringConvertible(completedAt.timeIntervalSince(now))
            ]
        )
    }
}
