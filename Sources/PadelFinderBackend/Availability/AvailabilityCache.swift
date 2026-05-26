import Foundation

actor AvailabilityCache {
    private struct Entry {
        let companies: [PadelCompanyAvailability]
        let createdAt: Date
    }

    private let ttlSeconds: TimeInterval
    private var entries: [String: Entry]

    init(ttlSeconds: TimeInterval = 120) {
        self.ttlSeconds = ttlSeconds
        self.entries = [:]
    }

    func freshValue(for key: String, now: Date) -> [PadelCompanyAvailability]? {
        guard let entry = entries[key] else {
            return nil
        }

        guard now.timeIntervalSince(entry.createdAt) < ttlSeconds else {
            return nil
        }

        return entry.companies
    }

    func store(_ companies: [PadelCompanyAvailability], for key: String, now: Date) {
        entries[key] = Entry(companies: companies, createdAt: now)
    }
}
