import Vapor

func routes(_ app: Application, availabilityService injectedAvailabilityService: (any AvailabilityServiceProtocol)? = nil) throws {
    let availabilityService = injectedAvailabilityService ?? AvailabilityService.live(client: app.client)

    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    app.get("availability") { req async throws -> AvailabilityResponse in
        let date = try resolveDate(from: req)
        return await availabilityService.availability(for: date, logger: req.logger)
    }

    app.get("availability", "company", ":companyId") { req async throws -> CompanyAvailabilityResponse in
        let companyId = try req.parameters.require("companyId")
        let date = try resolveDate(from: req)

        guard let company = await availabilityService.companyAvailability(
            forCompany: companyId,
            date: date,
            logger: req.logger
        ) else {
            throw Abort(.notFound, reason: "No availability for company \(companyId) on \(date)")
        }

        return CompanyAvailabilityResponse(date: date, company: company)
    }
}

/// Resolves the `date` query parameter, validating YYYY-MM-DD and defaulting to
/// today in the Tbilisi timezone when it is missing or empty.
private func resolveDate(from req: Request) throws -> String {
    let requestedDate = try? req.query.get(String.self, at: "date")

    guard let requestedDate, !requestedDate.isEmpty else {
        return TbilisiDate.todayString()
    }

    guard let validatedDate = TbilisiDate.validatedDateString(requestedDate) else {
        throw Abort(.badRequest, reason: "date must use YYYY-MM-DD")
    }

    return validatedDate
}
