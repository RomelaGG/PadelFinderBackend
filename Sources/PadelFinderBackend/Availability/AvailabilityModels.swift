import Vapor

struct AvailabilityResponse: Content, Equatable, Sendable {
    let date: String
    let companies: [PadelCompanyAvailability]
}

struct CompanyAvailabilityResponse: Content, Equatable, Sendable {
    let date: String
    let company: PadelCompanyAvailability
}

struct PadelCompanyAvailability: Content, Equatable, Sendable {
    let id: String
    let name: String
    let website: String?
    let logo: String?
    let courts: [CourtAvailability]
}

struct CourtAvailability: Content, Equatable, Sendable {
    let id: String
    let name: String
    let address: String?
    let pricePerHour: Int?
    let rating: Double?
    let imageUrl: String?
    let totalCourts: Int
    let timeSlots: [TimeSlot]
}

struct TimeSlot: Content, Equatable, Sendable {
    let time: String
    let status: TimeSlotStatus
    let isBookable: Bool
}

enum TimeSlotStatus: String, Content, Equatable, Sendable {
    case available
    case booked
    case maintenance
}
