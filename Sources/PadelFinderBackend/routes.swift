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
        let requestedDate = try? req.query.get(String.self, at: "date")
        let date: String

        if let requestedDate, !requestedDate.isEmpty {
            guard let validatedDate = TbilisiDate.validatedDateString(requestedDate) else {
                throw Abort(.badRequest, reason: "date must use YYYY-MM-DD")
            }
            date = validatedDate
        } else {
            date = TbilisiDate.todayString()
        }

        return await availabilityService.availability(for: date, logger: req.logger)
    }
}
