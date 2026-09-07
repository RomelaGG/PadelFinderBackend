import Foundation

/// Warm cache holding Kus Tba Padel availability per date.
///
/// Kus Tba's booking site is by far the slowest upstream we talk to: its
/// WordPress `admin-ajax.php` endpoints take 5-13s per call, and one fetch needs
/// a page scrape plus a slot call plus one court call per slot. That made it
/// solely responsible for `/availability` latency, since every other provider
/// answers in under 2.5s. `KustbaRefreshService` keeps this store populated in
/// the background so the request path reads an already-fetched value.
///
/// Entries deliberately never expire on read: serving slightly stale Kus Tba
/// data is better than blocking the response on a 20s upstream. Staleness is
/// bounded by the refresh interval instead, and `refreshTargets(...)` drops days
/// that are in the past or that nobody has asked for in a while.
actor KustbaAvailabilityStore {
    private struct Entry {
        var companies: [PadelCompanyAvailability]
        var refreshedAt: Date
        var lastRequestedAt: Date
    }

    private var entries: [String: Entry]
    private var inFlight: [String: Task<[PadelCompanyAvailability], any Error>]

    init() {
        self.entries = [:]
        self.inFlight = [:]
    }

    /// Returns the cached companies for `date` regardless of age, recording the
    /// request so the refresher keeps this date warm.
    func cachedValue(for date: String, now: Date) -> [PadelCompanyAvailability]? {
        guard var entry = entries[date] else {
            return nil
        }

        entry.lastRequestedAt = now
        entries[date] = entry

        return entry.companies
    }

    func store(_ companies: [PadelCompanyAvailability], for date: String, now: Date) {
        let lastRequestedAt = entries[date]?.lastRequestedAt ?? now
        entries[date] = Entry(companies: companies, refreshedAt: now, lastRequestedAt: lastRequestedAt)
    }

    /// Fetches `date` through `fetch`, collapsing concurrent callers for the same
    /// date onto a single upstream request, and caches the result.
    ///
    /// Only used when the request path misses the warm cache — a cold boot, or a
    /// date outside the refresh window. Without this coalescing, simultaneous
    /// misses would each start their own ~20-request fan-out at an already slow site.
    func loadValue(
        for date: String,
        now: Date,
        fetch: @escaping @Sendable () async throws -> [PadelCompanyAvailability]
    ) async throws -> [PadelCompanyAvailability] {
        if let existing = inFlight[date] {
            return try await existing.value
        }

        // Callers check the warm cache before calling in, so a fetch that
        // finished in between would otherwise be repeated here. Re-checking
        // inside the actor closes that window.
        if let entry = entries[date] {
            return entry.companies
        }

        let task = Task { try await fetch() }
        inFlight[date] = task

        defer { inFlight[date] = nil }

        let companies = try await task.value
        store(companies, for: date, now: now)

        return companies
    }

    /// Days the refresher should fetch right now.
    ///
    /// Each date carries its own cadence: days close to today change often
    /// enough to be worth refreshing frequently, while days further out barely
    /// move and are refreshed on a much slower interval. Returning only the
    /// dates that are actually due keeps the upstream request rate low.
    func datesDueForRefresh(
        nearDates: [String],
        farDates: [String],
        nearInterval: TimeInterval,
        farInterval: TimeInterval,
        today: String,
        now: Date,
        idleTimeout: TimeInterval
    ) -> [String] {
        let windowDates = Set(nearDates).union(farDates)

        // `YYYY-MM-DD` strings order lexicographically the same way they order
        // chronologically, so a string comparison is enough to drop past days.
        entries = entries.filter { date, entry in
            guard date >= today else {
                return false
            }

            guard !windowDates.contains(date) else {
                return true
            }

            return now.timeIntervalSince(entry.lastRequestedAt) < idleTimeout
        }

        func isDue(_ date: String, interval: TimeInterval) -> Bool {
            guard let entry = entries[date] else {
                return true
            }

            return now.timeIntervalSince(entry.refreshedAt) >= interval
        }

        // Dates a client asked for outside the scheduled window follow the far
        // cadence: they are kept warm, but cheaply.
        let requestedOutsideWindow = entries.keys
            .filter { !windowDates.contains($0) }
            .sorted()

        // Near days first, so a long cycle still refreshes today before next week.
        return nearDates.filter { isDue($0, interval: nearInterval) }
            + farDates.filter { isDue($0, interval: farInterval) }
            + requestedOutsideWindow.filter { isDue($0, interval: farInterval) }
    }
}
