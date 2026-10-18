import Vapor

/// Sends the code through Resend.
///
/// The whole provider contract is one `POST https://api.resend.com/emails`
/// with a bearer token, which is why this file is short and why swapping it for
/// SES or Postmark later is a new type rather than a rewrite.
struct ResendOTPMailer: OTPMailer {
    static let endpoint: URI = "https://api.resend.com/emails"

    let client: any Client
    let apiKey: String
    /// `Name <address@domain>`, or a bare address. Resend's test sender
    /// (`onboarding@resend.dev`) delivers only to the address the account was
    /// registered with - enough to test on a real device before a domain is
    /// verified, useless for real users.
    let fromAddress: String
    let otpLifetime: TimeInterval
    let logger: Logger

    private struct SendRequest: Content {
        let from: String
        let to: [String]
        let subject: String
        let text: String
        let html: String
    }

    func sendCode(_ code: String, to email: String, purpose: OTPPurpose) async throws {
        let message = OTPEmail(code: code, purpose: purpose, lifetime: otpLifetime)

        let response = try await client.post(Self.endpoint) { request in
            request.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            try request.content.encode(
                SendRequest(
                    from: fromAddress,
                    to: [email],
                    subject: message.subject,
                    text: message.plainText,
                    html: message.html
                )
            )
        }.get()

        guard response.status == .ok || response.status == .accepted else {
            throw failure(from: response, email: email, purpose: purpose)
        }
    }

    /// Turns a provider rejection into a log line that says what to do about it.
    ///
    /// Three cases are worth telling apart, because the fix differs and the
    /// first two are silent otherwise - the API answers `202 accepted`, the
    /// logs look healthy, and users sit on the code screen waiting.
    private func failure(from response: ClientResponse, email: String, purpose: OTPPurpose) -> OTPMailerError {
        let body = response.body.map { String(buffer: $0) } ?? ""

        var metadata: Logger.Metadata = [
            // Domain only. A full address does not belong in a log line, but
            // "which domain is failing" is exactly what you need when
            // deliverability breaks.
            "domain": .string(email.emailDomainForLogging),
            "purpose": .string(purpose.rawValue),
            "status": .stringConvertible(response.status.code)
        ]

        // The API key is a bearer token in the request, never in the response -
        // but the body is still provider text, so it is logged as data and
        // nothing is parsed out of it.
        if !body.isEmpty {
            metadata["providerResponse"] = .string(String(body.prefix(500)))
        }

        switch response.status {
        case .tooManyRequests:
            // The promised warning for the free tier's daily ceiling. A signup
            // spike that quietly exceeds it looks like a broken app, not a
            // quota, unless this line exists.
            logger.critical(
                """
                Resend refused the send: rate limit or daily quota reached. \
                Codes are NOT being delivered. Raise the plan limit.
                """,
                metadata: metadata
            )
        case .unauthorized, .forbidden:
            logger.critical(
                "Resend rejected our API key. Check RESEND_API_KEY.",
                metadata: metadata
            )
        default:
            logger.error("Resend could not send the code", metadata: metadata)
        }

        return OTPMailerError.sendFailed(status: response.status.code)
    }
}

enum OTPMailerError: Error, Equatable {
    case sendFailed(status: UInt)
}
