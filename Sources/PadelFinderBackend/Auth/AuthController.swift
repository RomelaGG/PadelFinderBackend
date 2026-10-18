import Fluent
import Foundation
import Vapor

/// The HTTP surface for accounts. Decodes, delegates to `AuthService`,
/// encodes - no rules of its own.
struct AuthController: RouteCollection {
    /// Holds the shared, boot-time pieces. The `AuthService` itself is built
    /// per request, because it needs that request's database connection - which
    /// inside a transaction is the transaction's connection, not the pool.
    let factory: AuthControllerFactory

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")

        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("refresh", use: refresh)
        auth.post("logout", use: logout)
        auth.post("apple", use: signInWithApple)
        auth.post("google", use: signInWithGoogle)

        let otp = auth.grouped("otp")
        otp.post("verify", use: verifySignupCode)
        otp.post("resend", use: resendSignupCode)

        let password = auth.grouped("password")
        password.post("forgot", use: forgotPassword)
        password.post("reset", use: resetPassword)

        let protected = auth.grouped(AccessTokenAuthenticator(factory: factory))
        protected.get("me", use: me)
        protected.patch("me", use: updateMe)
        protected.delete("me", use: deleteMe)

        let email = protected.grouped("email")
        email.post("change-request", use: requestEmailChange)
        email.post("change-confirm", use: confirmEmailChange)
    }

    // MARK: - Email and password

    func register(_ request: Request) async throws -> Response {
        let service = factory.service(on: request.db)
        try RegisterRequest.validate(content: request)
        let body = try request.content.decode(RegisterRequest.self)

        try await mappingOTPErrors {
            try await service.register(
                email: body.email,
                password: body.password,
                displayName: body.displayName,
                clientIP: clientIP(request)
            )
        }

        return try await AcceptedResponse.sent.encodeResponse(status: .accepted, for: request)
    }

    func verifySignupCode(_ request: Request) async throws -> TokenResponse {
        let service = factory.service(on: request.db)
        try VerifyCodeRequest.validate(content: request)
        let body = try request.content.decode(VerifyCodeRequest.self)

        let (pair, user) = try await mappingOTPErrors {
            try await service.verifySignup(email: body.email, code: body.code)
        }

        return try await tokenResponse(pair: pair, user: user, service: service)
    }

    /// Sends another sign-up code.
    ///
    /// Answers `202` whatever happens, including for an address with no pending
    /// sign-up. Anything else would make this the enumeration endpoint that
    /// `/auth/register` carefully is not.
    func resendSignupCode(_ request: Request) async throws -> Response {
        let service = factory.service(on: request.db)
        try EmailRequest.validate(content: request)
        let body = try request.content.decode(EmailRequest.self)
        let email = body.email.normalizedEmail

        if let found = try await service.linker.userForPasswordIdentity(email: email),
           found.user.status == .pendingVerification {
            try await mappingOTPErrors {
                let allowance = try await service.otps.claimSendAllowance(
                    for: email,
                    clientIP: clientIP(request)
                )
                try await service.otps.issue(allowance, purpose: .signup)
            }
        }

        return try await AcceptedResponse.sent.encodeResponse(status: .accepted, for: request)
    }

    func login(_ request: Request) async throws -> TokenResponse {
        let service = factory.service(on: request.db)
        try LoginRequest.validate(content: request)
        let body = try request.content.decode(LoginRequest.self)

        let (pair, user) = try await mappingOTPErrors {
            try await service.login(
                email: body.email,
                password: body.password,
                clientIP: clientIP(request)
            )
        }

        return try await tokenResponse(pair: pair, user: user, service: service)
    }

    // MARK: - Social

    func signInWithApple(_ request: Request) async throws -> TokenResponse {
        let service = factory.service(on: request.db)
        try AppleSignInRequest.validate(content: request)
        let body = try request.content.decode(AppleSignInRequest.self)

        let (pair, user) = try await service.signIn(
            with: factory.appleVerifier(displayName: body.displayName),
            token: body.identityToken,
            nonce: body.nonce
        )

        return try await tokenResponse(pair: pair, user: user, service: service)
    }

    func signInWithGoogle(_ request: Request) async throws -> TokenResponse {
        let service = factory.service(on: request.db)
        try GoogleSignInRequest.validate(content: request)
        let body = try request.content.decode(GoogleSignInRequest.self)

        let (pair, user) = try await service.signIn(
            with: factory.googleVerifier,
            token: body.identityToken,
            nonce: body.nonce
        )

        return try await tokenResponse(pair: pair, user: user, service: service)
    }

    // MARK: - Sessions

    func refresh(_ request: Request) async throws -> TokenResponse {
        let service = factory.service(on: request.db)
        try RefreshRequest.validate(content: request)
        let body = try request.content.decode(RefreshRequest.self)

        let (pair, user) = try await service.refresh(
            body.refreshToken,
            deviceLabel: request.headers.first(name: .userAgent)
        )

        return try await tokenResponse(pair: pair, user: user, service: service)
    }

    func logout(_ request: Request) async throws -> HTTPStatus {
        let service = factory.service(on: request.db)
        try RefreshRequest.validate(content: request)
        let body = try request.content.decode(RefreshRequest.self)

        try await service.logout(refreshToken: body.refreshToken)

        return .noContent
    }

    // MARK: - Password reset

    func forgotPassword(_ request: Request) async throws -> Response {
        let service = factory.service(on: request.db)
        try EmailRequest.validate(content: request)
        let body = try request.content.decode(EmailRequest.self)

        try await mappingOTPErrors {
            try await service.requestPasswordReset(
                email: body.email,
                clientIP: clientIP(request)
            )
        }

        return try await AcceptedResponse.sent.encodeResponse(status: .accepted, for: request)
    }

    func resetPassword(_ request: Request) async throws -> HTTPStatus {
        let service = factory.service(on: request.db)
        try ResetPasswordRequest.validate(content: request)
        let body = try request.content.decode(ResetPasswordRequest.self)

        try await mappingOTPErrors {
            try await service.resetPassword(
                email: body.email,
                code: body.code,
                newPassword: body.newPassword
            )
        }

        return .noContent
    }

    // MARK: - Profile

    func me(_ request: Request) async throws -> UserResponse {
        let service = factory.service(on: request.db)
        let user = try User.requireAuthenticated(request)
        return try UserResponse(user, providers: try await service.providers(for: user))
    }

    func updateMe(_ request: Request) async throws -> UserResponse {
        let service = factory.service(on: request.db)
        let user = try User.requireAuthenticated(request)
        try UpdateProfileRequest.validate(content: request)
        let body = try request.content.decode(UpdateProfileRequest.self)

        let updated = try await service.updateProfile(
            user,
            displayName: body.displayName,
            phone: body.phone
        )

        return try UserResponse(updated, providers: try await service.providers(for: updated))
    }

    func deleteMe(_ request: Request) async throws -> HTTPStatus {
        let service = factory.service(on: request.db)
        let user = try User.requireAuthenticated(request)
        try await service.deleteAccount(user)

        return .noContent
    }

    // MARK: - Email change

    func requestEmailChange(_ request: Request) async throws -> Response {
        let service = factory.service(on: request.db)
        let user = try User.requireAuthenticated(request)
        try EmailRequest.validate(content: request)
        let body = try request.content.decode(EmailRequest.self)

        try await mappingOTPErrors {
            try await service.requestEmailChange(
                for: user,
                newEmail: body.email,
                clientIP: clientIP(request)
            )
        }

        return try await AcceptedResponse.sent.encodeResponse(status: .accepted, for: request)
    }

    func confirmEmailChange(_ request: Request) async throws -> TokenResponse {
        let service = factory.service(on: request.db)
        let user = try User.requireAuthenticated(request)
        try VerifyCodeRequest.validate(content: request)
        let body = try request.content.decode(VerifyCodeRequest.self)

        let pair = try await mappingOTPErrors {
            try await service.confirmEmailChange(
                for: user,
                newEmail: body.email,
                code: body.code
            )
        }

        return try await tokenResponse(pair: pair, user: user, service: service)
    }

    // MARK: - Helpers

    /// Only trusts a forwarding header when one has been explicitly named, so
    /// the per-IP cap cannot be bypassed by sending a header.
    private func clientIP(_ request: Request) -> String? {
        request.clientIPForRateLimiting(trustedHeader: factory.configuration.trustedClientIPHeader)
    }

    private func tokenResponse(pair: TokenPair, user: User, service: AuthService) async throws -> TokenResponse {
        try TokenResponse(
            pair: pair,
            user: user,
            providers: try await service.providers(for: user)
        )
    }

    /// Translates `OTPError` into HTTP once, rather than at nine call sites.
    ///
    /// `noLiveCode` and `incorrectCode` both answer `invalid_code`, and the
    /// remaining-attempts count rides along in the message. Separating "no such
    /// code" from "wrong code" would say whether an address has a pending
    /// sign-up.
    private func mappingOTPErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as OTPError {
            switch error {
            case .noLiveCode:
                throw AuthAbort(.badRequest, .invalidCode, "That code is not valid. Request a new one.")
            case .incorrectCode(let remaining):
                throw AuthAbort(
                    .badRequest,
                    .invalidCode,
                    "That code is not correct. \(remaining) attempt\(remaining == 1 ? "" : "s") left."
                )
            case .codeBurned:
                throw AuthAbort(
                    .badRequest,
                    .codeBurned,
                    "Too many incorrect attempts. Request a new code."
                )
            case .tooManyRequests:
                throw AuthAbort.tooManyRequests
            }
        } catch is OTPMailerError {
            // The provider already logged why, with the detail needed to fix
            // it. The caller only needs to know it is worth retrying.
            throw AuthAbort.emailSendFailed
        }
    }
}
