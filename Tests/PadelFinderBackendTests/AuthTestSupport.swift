@testable import PadelFinderBackend
import Crypto
import Fluent
import FluentPostgresDriver
import Foundation
import JWT
import SQLKit
import Vapor
import VaporTesting

/// Whether the auth tests can run at all.
///
/// They need a real Postgres, because the guarantees being tested *are*
/// Postgres: the single-use `UPDATE`, the unique indexes, the atomic attempt
/// counter. An in-memory stand-in would pass while proving nothing.
///
/// Absent a database the suites are skipped rather than failed, so the
/// availability tests still run on a machine with no Postgres. Point
/// `DATABASE_URL_TEST` at the throwaway `db-test` service in
/// docker-compose.yml.
enum AuthTestEnvironment {
    static var databaseURL: String? {
        guard let url = ProcessInfo.processInfo.environment["DATABASE_URL_TEST"], !url.isEmpty else {
            return nil
        }
        return url
    }

    static var isAvailable: Bool {
        databaseURL != nil
    }

    static let jwtSecret = "test-secret-not-used-anywhere-else"
    static let appleClientID = "ge.padelfinder.app"
    static let googleClientID = "123456789.apps.googleusercontent.com"

    static func configuration(trustedClientIPHeader: String? = nil) -> AuthConfiguration {
        var configuration = Self.configuration
        configuration.trustedClientIPHeader = trustedClientIPHeader
        return configuration
    }

    static var configuration: AuthConfiguration {
        AuthConfiguration(
            jwtSecret: jwtSecret,
            jwtIssuer: "padelfinder-test",
            jwtAudience: "padelfinder-test-app",
            accessTokenLifetime: 900,
            refreshTokenLifetime: 86_400,
            otpLifetime: 600,
            otpMaxAttempts: 5,
            otpSendsPerHourPerEmail: 5,
            otpSendsPerHourPerIP: 20,
            trustedClientIPHeader: nil,
            appleClientIDs: [appleClientID],
            googleClientIDs: [googleClientID],
            mailer: .log,
            resendAPIKey: nil,
            otpFromAddress: "PadelFinder <codes@test.invalid>"
        )
    }
}

/// Keeps the code instead of emailing it, which is the whole reason `OTPMailer`
/// is a protocol: the entire email flow is exercisable with no provider chosen
/// and no account anywhere.
actor RecordingOTPMailer: OTPMailer {
    struct Sent: Sendable, Equatable {
        let code: String
        let email: String
        let purpose: OTPPurpose
    }

    private var sent: [Sent] = []

    func sendCode(_ code: String, to email: String, purpose: OTPPurpose) async throws {
        sent.append(Sent(code: code, email: email, purpose: purpose))
    }

    func all() -> [Sent] {
        sent
    }

    func count(for email: String) -> Int {
        sent.filter { $0.email == email.normalizedEmail }.count
    }

    /// The code a user would actually type: the most recent one, since issuing
    /// a new code burns any earlier one.
    func latestCode(for email: String, purpose: OTPPurpose) -> String? {
        sent.last { $0.email == email.normalizedEmail && $0.purpose == purpose }?.code
    }
}

/// Fast, deterministic hashing for tests.
///
/// Bcrypt at cost 12 is a quarter-second per call by design - correct in
/// production, ruinous across a suite that signs up dozens of users. The cost
/// stays where the documents require it in the live path; only the tests swap
/// it out.
struct TestPasswordHasher: PasswordHashing {
    func hash(_ password: String) async throws -> String {
        "test$" + SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func verify(_ password: String, created digest: String) async throws -> Bool {
        try await hash(password) == digest
    }
}

/// Serves a fixed key set, so Apple and Google tokens can be minted in a test.
///
/// Without this the two social paths would only ever be verifiable by hand on a
/// device - which is exactly how a nonce or audience check quietly stops
/// working.
struct StaticJWKSProvider: JWKSProviding {
    let collection: JWTKeyCollection

    func keys() async throws -> JWTKeyCollection {
        collection
    }
}

/// Everything a test needs to drive auth and look behind it.
struct AuthTestContext: Sendable {
    let app: Application
    let mailer: RecordingOTPMailer
    let factory: AuthControllerFactory
    /// Signs the tokens `StaticJWKSProvider` verifies. Used to mint Apple and
    /// Google identity tokens.
    let providerKeys: JWTKeyCollection

    var service: AuthService {
        factory.service(on: app.db)
    }

    var tokens: TokenService {
        factory.tokens(on: app.db)
    }

    func code(for email: String, purpose: OTPPurpose = .signup) async throws -> String {
        guard let code = await mailer.latestCode(for: email, purpose: purpose) else {
            throw AuthTestError.noCodeSent(email: email, purpose: purpose)
        }
        return code
    }
}

enum AuthTestError: Error, CustomStringConvertible {
    case noCodeSent(email: String, purpose: OTPPurpose)

    var description: String {
        switch self {
        case .noCodeSent(let email, let purpose):
            return "No \(purpose.rawValue) code was sent to \(email)"
        }
    }
}

/// Serializes every test that touches the database, across all suites, and
/// migrates it exactly once.
///
/// Swift Testing's `.serialized` trait only orders tests *within* one suite.
/// Two suites sharing one Postgres will happily run at the same time, and then
/// one suite's `TRUNCATE` lands in the middle of the other's inserts - which
/// shows up as foreign key violations that look like auth bugs and are not.
///
/// `actor` alone is not enough: actors are reentrant, so an `await` inside an
/// isolated method lets the next caller in. This is an explicit async mutex.
actor AuthTestDatabase {
    static let shared = AuthTestDatabase()

    private var migrated = false
    private var locked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        while locked {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }
        locked = true
    }

    func unlock() {
        locked = false

        if !waiting.isEmpty {
            waiting.removeFirst().resume()
        }
    }

    /// Runs the migrations on first call and does nothing afterwards.
    ///
    /// `autoMigrate` is idempotent in principle, but running it from two
    /// connections at once is not: both see an empty `_fluent_migrations` and
    /// both try to create every table.
    func migrateOnce(on app: Application) async throws {
        guard !migrated else {
            return
        }

        try await app.autoMigrate()
        migrated = true
    }
}

/// Boots an app against the test database with the auth routes registered.
///
/// Truncates on entry rather than reverting and re-applying the migrations:
/// six migrations per test would dominate the runtime, and `TRUNCATE
/// ... CASCADE` gives the same clean slate.
func withAuthApp(
    trustedClientIPHeader: String? = nil,
    _ body: (AuthTestContext) async throws -> Void
) async throws {
    guard let databaseURL = AuthTestEnvironment.databaseURL else {
        return
    }

    await AuthTestDatabase.shared.lock()
    let app = try await Application.make(.testing)

    do {
        app.databases.use(
            .postgres(configuration: try SQLPostgresConfiguration(url: databaseURL)),
            as: .psql
        )
        app.migrations.add(AuthMigrations.all)
        try await AuthTestDatabase.shared.migrateOnce(on: app)
        try await truncateAuthTables(on: app.db)

        let configuration = AuthTestEnvironment.configuration(
            trustedClientIPHeader: trustedClientIPHeader
        )

        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(stringLiteral: configuration.jwtSecret), digestAlgorithm: .sha256)

        // The "provider" keys stand in for Apple's and Google's. HMAC rather
        // than ECDSA because nothing here tests the signature algorithm - the
        // claims are what matter.
        let providerKeys = JWTKeyCollection()
        await providerKeys.add(hmac: "provider-test-key-at-least-32-bytes-long", digestAlgorithm: .sha256)

        let mailer = RecordingOTPMailer()
        let factory = AuthControllerFactory(
            keys: keys,
            configuration: configuration,
            hasher: TestPasswordHasher(),
            mailer: mailer,
            appleJWKS: StaticJWKSProvider(collection: providerKeys),
            googleJWKS: StaticJWKSProvider(collection: providerKeys)
        )
        app.authFactory = factory

        // The availability routes come along unused. Registering them is
        // cheap - the providers are constructed, never called - and it keeps
        // this app identical in shape to the real one.
        try routes(app, authFactory: factory)

        try await body(
            AuthTestContext(app: app, mailer: mailer, factory: factory, providerKeys: providerKeys)
        )
    } catch {
        try? await app.asyncShutdown()
        await AuthTestDatabase.shared.unlock()
        throw ReadableDatabaseError(error)
    }

    try await app.asyncShutdown()
    await AuthTestDatabase.shared.unlock()
}

/// Makes a database failure readable in a test report.
///
/// `PSQLError.description` is deliberately opaque - "Generic description to
/// prevent accidental leakage of sensitive data" - which is right in a
/// production log and useless in a failing test. Reflection gives the actual
/// constraint name and SQLSTATE.
struct ReadableDatabaseError: Error, CustomStringConvertible {
    let underlying: any Error

    init(_ underlying: any Error) {
        self.underlying = underlying
    }

    var description: String {
        String(reflecting: underlying)
    }
}

private func truncateAuthTables(on database: any Database) async throws {
    guard let sql = database as? any SQLDatabase else {
        return
    }

    // One statement so the foreign keys never see an inconsistent moment.
    try await sql.raw("""
        TRUNCATE users, user_identities, user_credentials, email_otps, refresh_tokens, rate_limits
        RESTART IDENTITY CASCADE
        """).run()
}

// MARK: - Minting provider tokens

extension AuthTestContext {
    /// A Sign in with Apple identity token, as Apple would send it.
    func appleToken(
        subject: String,
        email: String?,
        emailVerified: Bool = true,
        audience: String = AuthTestEnvironment.appleClientID,
        nonce: String? = nil,
        issuer: String = "https://appleid.apple.com",
        expires: Date = Date().addingTimeInterval(300)
    ) async throws -> String {
        let payload = AppleIdentityToken(
            issuer: IssuerClaim(value: issuer),
            audience: AudienceClaim(value: [audience]),
            expires: ExpirationClaim(value: expires),
            issuedAt: IssuedAtClaim(value: Date()),
            subject: SubjectClaim(value: subject),
            nonceSupported: BoolClaim(value: nonce != nil),
            nonce: nonce,
            email: email,
            emailVerified: BoolClaim(value: emailVerified)
        )

        return try await providerKeys.sign(payload)
    }

    /// A Google ID token.
    func googleToken(
        subject: String,
        email: String?,
        emailVerified: Bool = true,
        audience: String = AuthTestEnvironment.googleClientID,
        nonce: String? = nil,
        name: String? = nil,
        issuer: String = "https://accounts.google.com",
        expires: Date = Date().addingTimeInterval(300)
    ) async throws -> String {
        let payload = GoogleIdentityToken(
            issuer: IssuerClaim(value: issuer),
            subject: SubjectClaim(value: subject),
            audience: AudienceClaim(value: [audience]),
            authorizedPresenter: audience,
            issuedAt: IssuedAtClaim(value: Date()),
            expires: ExpirationClaim(value: expires),
            email: email,
            emailVerified: BoolClaim(value: emailVerified),
            name: name,
            nonce: nonce
        )

        return try await providerKeys.sign(payload)
    }
}

// MARK: - Test conveniences

/// Shorthands for the tests that are not about rate limiting.
///
/// Deliberately *not* defaults on `AuthService` itself. A default `clientIP:
/// nil` in production would let a newly added endpoint skip the per-IP cap
/// without anyone noticing - which is how the cap came to be missing in the
/// first place. Here the omission is confined to tests.
extension AuthService {
    func register(email: String, password: String, displayName: String?) async throws {
        try await register(
            email: email,
            password: password,
            displayName: displayName,
            clientIP: nil
        )
    }

    func requestPasswordReset(email: String) async throws {
        try await requestPasswordReset(email: email, clientIP: nil)
    }

    func requestEmailChange(for user: User, newEmail: String) async throws {
        try await requestEmailChange(for: user, newEmail: newEmail, clientIP: nil)
    }
}

extension OTPService {
    /// Claims and issues in one step, for tests that only need a code to exist.
    func issueForTesting(to email: String, purpose: OTPPurpose, clientIP: String? = nil) async throws {
        let allowance = try await claimSendAllowance(for: email, clientIP: clientIP)
        try await issue(allowance, purpose: purpose)
    }
}

/// Reads the rate-limit counters, so a test can assert *which* bucket was
/// charged rather than only that something was refused.
enum RateLimitRow {
    static func allBuckets(on database: any Database) async throws -> Set<String> {
        guard let sql = database as? any SQLDatabase else {
            return []
        }

        let rows = try await sql.raw("SELECT bucket FROM rate_limits").all()
        return Set(try rows.map { try $0.decode(column: "bucket", as: String.self) })
    }

    static func count(bucket: String, on database: any Database) async throws -> Int {
        guard let sql = database as? any SQLDatabase else {
            return 0
        }

        let row = try await sql.raw("""
            SELECT coalesce(sum(count), 0) AS total FROM rate_limits WHERE bucket = \(bind: bucket)
            """).first()

        return try row?.decode(column: "total", as: Int.self) ?? 0
    }
}
