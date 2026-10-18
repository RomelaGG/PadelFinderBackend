import Fluent
import JWT
import Vapor

/// The shared, boot-time half of auth.
///
/// Everything expensive lives here and is built once: the JWT key collection,
/// the Bcrypt hasher, and the two JWKS caches. `AuthService` is *not* here,
/// because it needs a `Database` and the right one is always the request's -
/// inside a transaction that is the transaction's connection, not the pool's.
/// So the factory hands out a service per request instead.
struct AuthControllerFactory: Sendable {
    let keys: JWTKeyCollection
    let configuration: AuthConfiguration
    let hasher: any PasswordHashing
    let mailer: any OTPMailer
    let appleJWKS: any JWKSProviding
    let googleJWKS: any JWKSProviding

    func tokens(on database: any Database) -> TokenService {
        TokenService(keys: keys, configuration: configuration, database: database)
    }

    func service(on database: any Database) -> AuthService {
        AuthService(
            database: database,
            tokens: tokens(on: database),
            otps: OTPService(
                database: database,
                hasher: hasher,
                mailer: mailer,
                configuration: configuration
            ),
            linker: AccountLinker(database: database),
            hasher: hasher,
            configuration: configuration
        )
    }

    /// Apple's display name arrives with the request, not in the token, so the
    /// verifier is built per sign-in.
    func appleVerifier(displayName: String?) -> any IdentityTokenVerifier {
        AppleIdentityTokenVerifier(
            jwks: appleJWKS,
            allowedClientIDs: configuration.appleClientIDs,
            displayName: displayName
        )
    }

    var googleVerifier: any IdentityTokenVerifier {
        GoogleIdentityTokenVerifier(
            jwks: googleJWKS,
            allowedClientIDs: configuration.googleClientIDs
        )
    }
}

struct AuthFactoryKey: StorageKey {
    typealias Value = AuthControllerFactory
}

extension Application {
    var authFactory: AuthControllerFactory {
        get {
            guard let factory = storage[AuthFactoryKey.self] else {
                fatalError("Auth was not configured. Call configureAuth(app) first.")
            }
            return factory
        }
        set { storage[AuthFactoryKey.self] = newValue }
    }
}

/// Builds the auth factory: password hasher, signing key, mailer, and the JWKS
/// caches for Apple and Google.
func configureAuth(_ app: Application) async throws -> AuthControllerFactory {
    let configuration = try AuthConfiguration.fromEnvironment(app.environment, logger: app.logger)
    app.authConfiguration = configuration

    // Cost 12 is the floor ARCHITECTURE.md section 4 sets, and the reason
    // hashing runs on the thread pool rather than an event loop: a quarter of
    // a second of blocking would stall every request sharing that loop.
    app.passwords.use(.bcrypt(cost: 12))

    let keys = JWTKeyCollection()
    await keys.add(hmac: HMACKey(stringLiteral: configuration.jwtSecret), digestAlgorithm: .sha256)

    let mailer: any OTPMailer

    switch configuration.mailer {
    case .log:
        // Production cannot reach here: `AuthConfiguration` refuses to build
        // with the log mailer in that environment, so this is development and
        // testing only.
        mailer = LoggingOTPMailer(logger: app.logger)

    case .resend:
        // The key's presence is checked while reading the configuration, so a
        // missing one fails the deploy rather than the first sign-up.
        mailer = ResendOTPMailer(
            client: app.client,
            apiKey: configuration.resendAPIKey ?? "",
            fromAddress: configuration.otpFromAddress,
            otpLifetime: configuration.otpLifetime,
            logger: app.logger
        )

        if configuration.otpFromAddress.contains("resend.dev") {
            app.logger.warning(
                """
                OTP_FROM_ADDRESS still uses Resend's test sender: codes reach \
                only the address the Resend account was registered with. Set a \
                verified domain before real users sign up.
                """
            )
        }
    }

    let eventLoop = app.eventLoopGroup.any()

    let factory = AuthControllerFactory(
        keys: keys,
        configuration: configuration,
        hasher: BcryptPasswordHasher(hasher: app.password.async),
        mailer: mailer,
        appleJWKS: RemoteJWKSProvider(
            endpoint: AppleIdentityTokenVerifier.jwksEndpoint,
            client: app.client,
            eventLoop: eventLoop,
            logger: app.logger
        ),
        googleJWKS: RemoteJWKSProvider(
            endpoint: GoogleIdentityTokenVerifier.jwksEndpoint,
            client: app.client,
            eventLoop: eventLoop,
            logger: app.logger
        )
    )

    app.authFactory = factory

    if app.environment == .production, configuration.trustedClientIPHeader == nil {
        app.logger.warning(
            """
            TRUSTED_CLIENT_IP_HEADER is not set. Behind a proxy every request \
            appears to come from the proxy, so the per-IP code limit applies to \
            all callers at once. On Fly, set it to Fly-Client-IP.
            """
        )
    }

    app.logger.notice(
        "Auth configured",
        metadata: [
            "mailer": .string(configuration.mailer.rawValue),
            "apple": .stringConvertible(!configuration.appleClientIDs.isEmpty),
            "google": .stringConvertible(!configuration.googleClientIDs.isEmpty),
            "trustedClientIPHeader": .string(configuration.trustedClientIPHeader ?? "none")
        ]
    )

    return factory
}
