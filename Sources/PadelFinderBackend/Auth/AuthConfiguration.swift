import Foundation
import Vapor

/// Everything auth reads from the environment, resolved once at boot.
///
/// Read eagerly and loudly on purpose: a missing `JWT_SECRET` should fail the
/// deploy, not the first sign-in attempt after it. Every value has a default
/// that is safe for local development and refused in production.
struct AuthConfiguration: Sendable {
    /// HMAC key for the access token. One service both issues and verifies, so
    /// a shared secret is enough; an ES256 keypair with a public JWKS is only
    /// worth it once the venue panel verifies tokens independently.
    var jwtSecret: String
    var jwtIssuer: String
    var jwtAudience: String

    /// 15 minutes. Short because it cannot be revoked - revocation lives on the
    /// refresh token, so the access token's blast radius is its lifetime.
    var accessTokenLifetime: TimeInterval
    var refreshTokenLifetime: TimeInterval

    var otpLifetime: TimeInterval
    var otpMaxAttempts: Int
    /// Caps how many codes one address can be sent per hour, so our server
    /// cannot be used to spam someone else's inbox.
    var otpSendsPerHourPerEmail: Int
    var otpSendsPerHourPerIP: Int

    /// Name of the header carrying the real client IP, set by a proxy we trust.
    ///
    /// `nil` means trust no header and use the connection's peer address. That
    /// is the safe default: any client can send `X-Forwarded-For`, so a header
    /// trusted by default would make the per-IP cap meaningless. On Fly, set
    /// this to `Fly-Client-IP`.
    var trustedClientIPHeader: String?

    /// Accepted `aud` values. Comma-separated in the environment because the
    /// iOS bundle id and any web client id differ and both are legitimate.
    var appleClientIDs: [String]
    var googleClientIDs: [String]

    var mailer: OTPMailerKind
    /// Only read when `mailer` is `.resend`. Required in that case - boot fails
    /// rather than discovering it on the first sign-up.
    var resendAPIKey: String?
    var otpFromAddress: String

    static let developmentJWTSecret = "development-only-insecure-jwt-secret"

    /// Refuses a mailer that cannot possibly work.
    ///
    /// Checked at boot so a deploy fails loudly, rather than coming up green
    /// and then dropping every sign-up on the floor.
    ///
    /// In production the log mailer is an error, not a warning. It used to be
    /// a warning, which was wrong twice over: `/auth/register` would answer
    /// `202 accepted` for an email that was never sent - so nobody could
    /// complete a sign-up, and nothing in the response said so - and every
    /// code would sit in the logs in plain text, where anyone with log access
    /// could take over an account mid-sign-up. A warning at boot is far too
    /// easy to scroll past for a failure that severe.
    ///
    /// Refusing to boot does not take production down: migrations and startup
    /// run as Fly's release step, so a bad configuration fails the *deploy* and
    /// the previous version keeps serving. Same contract as `DATABASE_URL` and
    /// `JWT_SECRET`.
    ///
    /// For a staging environment that runs with `--env production` but should
    /// not email real people, use `OTP_MAILER=resend` with Resend's test
    /// sender: it is free, and it only ever delivers to the address that
    /// Resend account was registered with.
    static func validateMailerSettings(
        kind: OTPMailerKind,
        apiKey: String?,
        environment: Environment
    ) throws {
        switch kind {
        case .log:
            guard environment != .production else {
                throw AuthConfigurationError.invalidValue(
                    "OTP_MAILER",
                    reason: """
                    'log' writes codes to the log instead of emailing them, so \
                    no real user can complete a sign-up or a password reset, \
                    and every code is left in plain text in the logs. Set \
                    OTP_MAILER=resend with RESEND_API_KEY. For a staging \
                    environment, Resend's test sender only delivers to your own \
                    address.
                    """
                )
            }
        case .resend:
            guard apiKey != nil else {
                throw AuthConfigurationError.missingRequiredValue(
                    "RESEND_API_KEY (required when OTP_MAILER=resend)"
                )
            }
        }
    }

    static func fromEnvironment(_ environment: Environment, logger: Logger) throws -> AuthConfiguration {
        let secret: String

        if let configured = Environment.get("JWT_SECRET"), !configured.isEmpty {
            secret = configured
        } else if environment == .production {
            throw AuthConfigurationError.missingRequiredValue("JWT_SECRET")
        } else {
            logger.warning("JWT_SECRET not set; using the development secret. Never do this in production.")
            secret = developmentJWTSecret
        }

        let mailer = OTPMailerKind(rawValue: Environment.get("OTP_MAILER") ?? "log") ?? .log
        let resendAPIKey = Environment.get("RESEND_API_KEY").flatMap { $0.isEmpty ? nil : $0 }

        try validateMailerSettings(kind: mailer, apiKey: resendAPIKey, environment: environment)

        return AuthConfiguration(
            jwtSecret: secret,
            jwtIssuer: Environment.get("JWT_ISSUER") ?? "padelfinder",
            jwtAudience: Environment.get("JWT_AUDIENCE") ?? "padelfinder-app",
            accessTokenLifetime: Environment.double("ACCESS_TOKEN_TTL_SECONDS") ?? 900,
            refreshTokenLifetime: (Environment.double("REFRESH_TOKEN_TTL_DAYS") ?? 60) * 86_400,
            otpLifetime: Environment.double("OTP_TTL_SECONDS") ?? 600,
            otpMaxAttempts: Environment.int("OTP_MAX_ATTEMPTS") ?? 5,
            otpSendsPerHourPerEmail: Environment.int("OTP_SENDS_PER_HOUR") ?? 5,
            otpSendsPerHourPerIP: Environment.int("OTP_SENDS_PER_HOUR_PER_IP") ?? 20,
            trustedClientIPHeader: Environment.get("TRUSTED_CLIENT_IP_HEADER").flatMap {
                $0.isEmpty ? nil : $0
            },
            appleClientIDs: Environment.commaSeparated("APPLE_CLIENT_IDS"),
            googleClientIDs: Environment.commaSeparated("GOOGLE_CLIENT_IDS"),
            mailer: mailer,
            resendAPIKey: resendAPIKey,
            // Resend's test sender. It reaches only the address the account was
            // registered with, which is enough to test on a device and no use
            // for real users - a verified domain replaces it.
            otpFromAddress: Environment.get("OTP_FROM_ADDRESS") ?? "PadelFinder <onboarding@resend.dev>"
        )
    }
}

enum AuthConfigurationError: Error, CustomStringConvertible {
    case missingRequiredValue(String)
    case invalidValue(String, reason: String)

    var description: String {
        switch self {
        case .missingRequiredValue(let name):
            return "\(name) must be set in this environment"
        case .invalidValue(let name, let reason):
            return "\(name) is not usable in this environment: \(reason)"
        }
    }
}

enum OTPMailerKind: String, Sendable {
    /// Logs the code instead of sending it. The default, and the right choice
    /// for local development: the whole sign-up flow works with no provider
    /// account and no API key - read the code off the console.
    case log
    case resend
}

extension Environment {
    static func double(_ key: String) -> Double? {
        Environment.get(key).flatMap(Double.init)
    }

    static func int(_ key: String) -> Int? {
        Environment.get(key).flatMap(Int.init)
    }

    static func commaSeparated(_ key: String) -> [String] {
        guard let raw = Environment.get(key) else {
            return []
        }

        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct AuthConfigurationKey: StorageKey {
    typealias Value = AuthConfiguration
}

extension Application {
    var authConfiguration: AuthConfiguration {
        get {
            guard let configuration = storage[AuthConfigurationKey.self] else {
                fatalError("AuthConfiguration was not configured. Call configureAuth(app) first.")
            }
            return configuration
        }
        set { storage[AuthConfigurationKey.self] = newValue }
    }
}
