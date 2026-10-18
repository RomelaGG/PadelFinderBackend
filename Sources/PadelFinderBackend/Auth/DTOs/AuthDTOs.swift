import Foundation
import Vapor

// MARK: - Responses

/// A signed-in session. `expiresIn` is seconds, so the client does not have to
/// parse the JWT to know when to refresh.
struct TokenResponse: Content, Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String
    let user: UserResponse

    init(pair: TokenPair, user: User, providers: [AuthProvider]) throws {
        self.accessToken = pair.accessToken
        self.expiresIn = pair.accessTokenExpiresIn
        self.refreshToken = pair.refreshToken
        self.user = try UserResponse(user, providers: providers)
    }
}

struct UserResponse: Content, Sendable {
    let id: UUID
    let email: String?
    let phone: String?
    let displayName: String?
    /// Which methods this account can sign in with. The app uses it to show
    /// "connected accounts" and to decide whether "set a password" or "change
    /// password" is the right button.
    let providers: [String]

    init(_ user: User, providers: [AuthProvider] = []) throws {
        self.id = try user.requireID()
        self.email = user.email
        self.phone = user.phone
        self.displayName = user.displayName
        self.providers = providers.map(\.rawValue)
    }
}

/// The answer to every request that may or may not have sent an email.
///
/// Identical whether the address has an account, has a pending sign-up, or has
/// never been seen. Anything else turns `/auth/register` and
/// `/auth/password/forgot` into a way to ask us which addresses have accounts.
struct AcceptedResponse: Content, Sendable {
    let status: String

    static let sent = AcceptedResponse(status: "accepted")
}

// MARK: - Requests

struct RegisterRequest: Content, Validatable, Sendable {
    let email: String
    let password: String
    let displayName: String?

    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        // Length is the only password rule. Composition rules (a digit, a
        // symbol) measurably push people towards weaker, more predictable
        // passwords, and we are not the ones storing anything they reuse.
        validations.add("password", as: String.self, is: .count(8...256))
    }
}

struct LoginRequest: Content, Validatable, Sendable {
    let email: String
    let password: String

    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        validations.add("password", as: String.self, is: !.empty)
    }
}

struct EmailRequest: Content, Validatable, Sendable {
    let email: String

    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
    }
}

struct VerifyCodeRequest: Content, Validatable, Sendable {
    let email: String
    let code: String

    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        validations.add("code", as: String.self, is: .count(6...6))
    }
}

struct ResetPasswordRequest: Content, Validatable, Sendable {
    let email: String
    let code: String
    let newPassword: String

    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: .email)
        validations.add("code", as: String.self, is: .count(6...6))
        validations.add("newPassword", as: String.self, is: .count(8...256))
    }
}

struct RefreshRequest: Content, Validatable, Sendable {
    let refreshToken: String

    static func validations(_ validations: inout Validations) {
        validations.add("refreshToken", as: String.self, is: !.empty)
    }
}

/// Apple returns the display name only in the native authorization result, not
/// in the identity token, so the client passes it through on first sign-in.
/// Trusted for display only - never for identity.
struct AppleSignInRequest: Content, Validatable, Sendable {
    let identityToken: String
    let nonce: String?
    let displayName: String?

    static func validations(_ validations: inout Validations) {
        validations.add("identityToken", as: String.self, is: !.empty)
    }
}

struct GoogleSignInRequest: Content, Validatable, Sendable {
    let identityToken: String
    let nonce: String?

    static func validations(_ validations: inout Validations) {
        validations.add("identityToken", as: String.self, is: !.empty)
    }
}

struct UpdateProfileRequest: Content, Validatable, Sendable {
    let displayName: String?
    /// Optional and **unverified**, by design: venues want a number to call
    /// about a late arrival, and verifying it by SMS would cost money per
    /// message for no security we do not already get from the payment step
    /// (ARCHITECTURE.md section 4).
    let phone: String?

    static func validations(_ validations: inout Validations) {
        validations.add("displayName", as: String?.self, is: .nil || .count(1...120), required: false)
        validations.add("phone", as: String?.self, is: .nil || .count(5...32), required: false)
    }
}
