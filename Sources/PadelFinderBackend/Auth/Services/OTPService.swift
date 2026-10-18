import Fluent
import Foundation
import SQLKit
import Vapor

/// Proof that a send was allowed before any expensive work was done.
///
/// Only `OTPService.claimSendAllowance` can make one, and `issue` demands one.
/// That is the point: the previous version checked the rate limit *inside*
/// `issue`, after the caller had already Bcrypt-hashed a password - so a
/// refused request still cost a quarter-second of CPU on an unauthenticated
/// endpoint. Making the permit a value the compiler insists on means the check
/// cannot drift back below the work it is supposed to prevent.
struct SendAllowance: Sendable {
    let email: String
    let clientIP: String?

    fileprivate init(email: String, clientIP: String?) {
        self.email = email
        self.clientIP = clientIP
    }
}

enum OTPError: Error, Equatable {
    /// No live code for this address and purpose - never sent, already used,
    /// or expired. One case on purpose: telling them apart tells an attacker
    /// which addresses have accounts.
    case noLiveCode
    case incorrectCode(attemptsRemaining: Int)
    /// The attempt ceiling was reached. The code is now dead even if the next
    /// guess would have been right.
    case codeBurned
    case tooManyRequests
}

/// Issues, verifies and consumes emailed codes.
///
/// The three rules from ARCHITECTURE.md section 4, and where each one lives:
///
/// - **Stored hashed, never in plain text.** `issue` hashes before it writes;
///   the digits exist only in memory and in the email.
/// - **Dies after 10 minutes or 5 wrong tries.** `expiresAt` and the attempt
///   ceiling in `verify`.
/// - **Submitting it twice at the same instant succeeds exactly once.** The
///   `UPDATE ... WHERE consumed_at IS NULL` in `consume` - the database picks
///   the winner, not an `if`.
struct OTPService: Sendable {
    let database: any Database
    let hasher: any PasswordHashing
    let mailer: any OTPMailer
    let configuration: AuthConfiguration
    let now: @Sendable () -> Date

    init(
        database: any Database,
        hasher: any PasswordHashing,
        mailer: any OTPMailer,
        configuration: AuthConfiguration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.hasher = hasher
        self.mailer = mailer
        self.configuration = configuration
        self.now = now
    }

    private var limiter: RateLimiter {
        RateLimiter(database: database, now: now)
    }

    // MARK: - Rate limiting

    /// Claims one send against both caps, or throws.
    ///
    /// Must be called before anything expensive - creating rows, hashing a
    /// password, generating a code. `issue` will not run without the permit
    /// this returns.
    ///
    /// Both claims live in one transaction, so a request refused by either cap
    /// consumes neither. That matters in one specific direction: without it, an
    /// attacker blocked by the IP cap would still burn the victim's email
    /// allowance, and the victim would be locked out of their own password
    /// reset for an hour.
    ///
    /// The IP cap is claimed first so a refusal costs the attacker's budget
    /// rather than the address they are aiming at.
    func claimSendAllowance(for rawEmail: String, clientIP: String?) async throws -> SendAllowance {
        let email = rawEmail.normalizedEmail

        try await database.transaction { database in
            let limiter = RateLimiter(database: database, now: now)

            if let clientIP {
                let allowed = try await limiter.claim(
                    .clientIP(clientIP),
                    limit: configuration.otpSendsPerHourPerIP,
                    window: 3600
                )

                // Without this cap, unique addresses are unlimited: an
                // attacker walks a list, burns the provider's daily quota, and
                // every request costs us two Bcrypt hashes on one shared vCPU.
                guard allowed else {
                    throw OTPError.tooManyRequests
                }
            }

            let allowed = try await limiter.claim(
                .email(email),
                limit: configuration.otpSendsPerHourPerEmail,
                window: 3600
            )

            // Stops our server being used to flood somebody else's inbox.
            guard allowed else {
                throw OTPError.tooManyRequests
            }
        }

        return SendAllowance(email: email, clientIP: clientIP)
    }

    // MARK: - Issuing

    /// Generates a code, stores its hash, and sends it.
    ///
    /// Any previous live code for the same address and purpose is burned first.
    /// Otherwise asking for a new code because the first one did not arrive
    /// would leave two valid codes, and the attempt ceiling would apply to each
    /// separately - five tries per request instead of five per address.
    func issue(_ allowance: SendAllowance, purpose: OTPPurpose, userID: UUID? = nil) async throws {
        let normalized = allowance.email
        try await burnLiveCodes(for: normalized, purpose: purpose)

        let code = Self.generateCode()
        let record = EmailOTP(
            email: normalized,
            codeHash: try await hasher.hash(code),
            purpose: purpose,
            expiresAt: now().addingTimeInterval(configuration.otpLifetime),
            userID: userID
        )
        try await record.create(on: database)

        try await mailer.sendCode(code, to: normalized, purpose: purpose)
    }

    private func burnLiveCodes(for email: String, purpose: OTPPurpose) async throws {
        try await EmailOTP.query(on: database)
            .filter(\.$email == email)
            .filter(\.$purpose == purpose)
            .filter(\.$consumedAt == nil)
            .set(\.$consumedAt, to: now())
            .update()
    }

    // MARK: - Verifying

    /// Checks a submitted code and consumes it.
    ///
    /// Order matters: find the newest live row, verify the hash, *then* claim
    /// it atomically. Verifying before claiming means a wrong guess costs an
    /// attempt without burning the code; claiming before verifying would let
    /// one wrong guess destroy a code the owner was about to use correctly.
    @discardableResult
    func verifyAndConsume(code: String, email: String, purpose: OTPPurpose) async throws -> EmailOTP {
        let normalized = email.normalizedEmail

        guard let record = try await EmailOTP.query(on: database)
            .filter(\.$email == normalized)
            .filter(\.$purpose == purpose)
            .filter(\.$consumedAt == nil)
            .filter(\.$expiresAt > now())
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw OTPError.noLiveCode
        }

        guard try await hasher.verify(code, created: record.codeHash) else {
            throw try await registerFailedAttempt(on: record)
        }

        guard try await consume(record) else {
            // Lost the race: another request consumed this row between our read
            // and our write. Exactly one caller gets past this point.
            throw OTPError.noLiveCode
        }

        return record
    }

    /// The single-use guard, verbatim from SYSTEM-DESIGN-DIAGRAMS.md section 7.
    ///
    /// Returns false when no row came back, which means someone else already
    /// used this code or it expired in the meantime.
    private func consume(_ record: EmailOTP) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw RawSQLMigrationError.databaseIsNotSQL
        }

        let consumedAt = now()
        let claimed = try await sql.raw("""
            UPDATE email_otps
               SET consumed_at = \(bind: consumedAt)
             WHERE id = \(bind: try record.requireID())
               AND consumed_at IS NULL
               AND expires_at > \(bind: consumedAt)
            RETURNING id
            """).first()

        if claimed != nil {
            record.consumedAt = consumedAt
        }

        return claimed != nil
    }

    /// Counts a wrong guess, and kills the code on the last one.
    ///
    /// The increment is done in SQL so parallel wrong guesses cannot both read
    /// 3 and both write 4.
    private func registerFailedAttempt(on record: EmailOTP) async throws -> OTPError {
        guard let sql = database as? any SQLDatabase else {
            throw RawSQLMigrationError.databaseIsNotSQL
        }

        let row = try await sql.raw("""
            UPDATE email_otps
               SET attempt_count = attempt_count + 1
             WHERE id = \(bind: try record.requireID())
            RETURNING attempt_count
            """).first()

        let attempts = try row?.decode(column: "attempt_count", as: Int.self) ?? configuration.otpMaxAttempts

        guard attempts < configuration.otpMaxAttempts else {
            // Burn it rather than merely refusing further guesses, so a code
            // that has been brute-forced at cannot be used even by its owner.
            // They request a new one.
            try await sql.raw("""
                UPDATE email_otps
                   SET consumed_at = \(bind: now())
                 WHERE id = \(bind: try record.requireID())
                   AND consumed_at IS NULL
                """).run()

            return OTPError.codeBurned
        }

        return OTPError.incorrectCode(attemptsRemaining: configuration.otpMaxAttempts - attempts)
    }

    // MARK: - Code material

    /// Six digits, zero-padded, from the system CSPRNG.
    ///
    /// Not `Int.random(in: 0..<1_000_000)` formatted - that is the same thing,
    /// but written this way it is obvious that every code including `000123` is
    /// equally likely, which a naive implementation gets wrong.
    static func generateCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = UInt32.random(in: 0..<1_000_000, using: &generator)
        return String(format: "%06u", value)
    }
}
