import Vapor

/// An error with a stable machine-readable code alongside the message.
///
/// The iOS client has to branch on these - "your email is not verified yet"
/// sends it to the code screen, "that slot is gone" to the picker - and
/// branching on English prose breaks the moment the wording is improved or
/// translated. The `reason` is for humans and may change freely; the `code`
/// may not.
struct AuthAbort: AbortError, Equatable {
    let status: HTTPResponseStatus
    let code: AuthErrorCode
    let reason: String

    init(_ status: HTTPResponseStatus, _ code: AuthErrorCode, _ reason: String) {
        self.status = status
        self.code = code
        self.reason = reason
    }
}

enum AuthErrorCode: String, Sendable {
    case invalidCredentials = "invalid_credentials"
    /// The password was right but the address was never proved. The only
    /// failure that deliberately tells the caller something specific, because
    /// they have already demonstrated they own the account.
    case emailNotVerified = "email_not_verified"
    case invalidCode = "invalid_code"
    case codeExpired = "code_expired"
    case codeBurned = "code_burned"
    case tooManyRequests = "too_many_requests"
    case invalidToken = "invalid_token"
    /// A refresh token that had already been rotated away was presented. The
    /// device family is now signed out; the client must start a fresh sign-in.
    case sessionRevoked = "session_revoked"
    case emailAlreadyInUse = "email_already_in_use"
    case identityVerificationFailed = "identity_verification_failed"
    case providerNotConfigured = "provider_not_configured"
    case validationFailed = "validation_failed"
    /// We could not hand the code to the email provider. Answered instead of a
    /// cheerful `202` on purpose: telling the client we sent an email we did
    /// not leaves them waiting on the code screen forever, when retrying would
    /// have worked.
    case emailSendFailed = "email_send_failed"
}

extension AuthAbort {
    static let invalidCredentials = AuthAbort(
        .unauthorized,
        .invalidCredentials,
        "Email or password is incorrect"
    )

    static let invalidToken = AuthAbort(
        .unauthorized,
        .invalidToken,
        "Token is missing, malformed or expired"
    )

    static let sessionRevoked = AuthAbort(
        .unauthorized,
        .sessionRevoked,
        "This session was signed out. Sign in again."
    )

    static let emailSendFailed = AuthAbort(
        .badGateway,
        .emailSendFailed,
        "We could not send the email just now. Try again in a moment."
    )

    static let tooManyRequests = AuthAbort(
        .tooManyRequests,
        .tooManyRequests,
        "Too many codes requested for this address. Try again later."
    )
}

/// Renders `AuthAbort` with its code in the body.
///
/// Vapor's own `ErrorMiddleware` renders `{"error":true,"reason":"..."}` and
/// has nowhere to put a code, so this sits in front of it and handles its own
/// errors. Everything else falls through untouched.
struct AuthErrorMiddleware: AsyncMiddleware {
    struct ErrorBody: Content {
        let error: Bool
        let code: String
        let reason: String
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as AuthAbort {
            request.logger.info(
                "Auth request refused",
                metadata: [
                    "code": .string(error.code.rawValue),
                    "status": .stringConvertible(error.status.code)
                ]
            )

            let response = Response(status: error.status)
            try response.content.encode(
                ErrorBody(error: true, code: error.code.rawValue, reason: error.reason)
            )
            return response
        }
    }
}
