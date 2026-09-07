import Vapor

func routes(_ app: Application, availabilityService injectedAvailabilityService: (any AvailabilityServiceProtocol)? = nil) throws {
    let availabilityService = injectedAvailabilityService
        ?? AvailabilityService.live(client: app.client, kustbaStore: app.kustbaAvailabilityStore)

    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    app.get("availability") { req async throws -> AvailabilityResponse in
        let date = try resolveDate(from: req)
        let response = await availabilityService.availability(for: date, logger: req.logger)
        let baseURL = req.application.publicBaseURL
        return AvailabilityResponse(
            date: response.date,
            companies: response.companies.map { $0.resolvingAssetURLs(baseURL: baseURL) }
        )
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

        return CompanyAvailabilityResponse(
            date: date,
            company: company.resolvingAssetURLs(baseURL: req.application.publicBaseURL)
        )
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

private extension PadelCompanyAvailability {
    /// Returns a copy with relative backend asset paths (e.g. `/logos/x.png`)
    /// expanded to absolute URLs against the configured API base URL.
    func resolvingAssetURLs(baseURL: String) -> PadelCompanyAvailability {
        let resolvedLogo = resolvingBackendAssetURL(logo, baseURL: baseURL)
        let resolvedCoverImage = resolvingBackendAssetURL(coverImage, baseURL: baseURL)

        guard resolvedLogo != logo || resolvedCoverImage != coverImage else {
            return self
        }

        return PadelCompanyAvailability(
            id: id,
            name: name,
            website: website,
            logo: resolvedLogo,
            coverImage: resolvedCoverImage,
            courts: courts
        )
    }

    private func resolvingBackendAssetURL(_ value: String?, baseURL: String) -> String? {
        guard let value, value.hasPrefix("/") else {
            return value
        }

        return baseURL + value
    }
}
