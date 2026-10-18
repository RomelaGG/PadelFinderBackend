import Crypto
import Fluent
import Foundation
import JWT
import SQLKit
import Vapor

/// The access token's payload. `sub` is the user id; everything else is there
/// so a token issued for one environment cannot be replayed against another.
struct AccessTokenPayload: JWTPayload, Sendable {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case issuer = "iss"
        case audience = "aud"
        case expiration = "exp"
        case issuedAt = "iat"
        case tokenID = "jti"
    }

    var subject: SubjectClaim
    var issuer: IssuerClaim
    var audience: AudienceClaim
    var expiration: ExpirationClaim
    var issuedAt: IssuedAtClaim
    var tokenID: IDClaim

    var userID: UUID? {
        UUID(uuidString: subject.value)
    }

    func verify(using _: some JWTAlgorithm) throws {
        try expiration.verifyNotExpired()
    }
}

/// What a successful sign-in hands back.
struct TokenPair: Sendable {
    let accessToken: String
    let accessTokenExpiresIn: Int
    /// Opaque, not a JWT. It is a database lookup key, so there is nothing to
    /// gain from making it self-describing and something to lose.
    let refreshToken: String
}

enum TokenError: Error {
    case invalidRefreshToken
    /// A token that was already rotated away was presented again. Treated as
    /// theft: the family is revoked before this is thrown.
    case refreshTokenReused
}

/// Issues access tokens, and owns the whole life of a refresh token: minting,
/// rotation, family revocation.
struct TokenService: Sendable {
    let keys: JWTKeyCollection
    let configuration: AuthConfiguration
    let database: any Database
    let now: @Sendable () -> Date

    init(
        keys: JWTKeyCollection,
        configuration: AuthConfiguration,
        database: any Database,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keys = keys
        self.configuration = configuration
        self.database = database
        self.now = now
    }

    // MARK: - Issuing

    /// Starts a new token family. Called on sign-in, never on refresh.
    func issuePair(for userID: UUID, deviceLabel: String? = nil) async throws -> TokenPair {
        try await issuePair(for: userID, familyID: UUID(), deviceLabel: deviceLabel)
    }

    private func issuePair(for userID: UUID, familyID: UUID, deviceLabel: String?) async throws -> TokenPair {
        let issuedAt = now()
        let accessToken = try await signAccessToken(userID: userID, issuedAt: issuedAt)

        let refreshToken = Self.generateRefreshToken()
        let record = RefreshToken(
            userID: userID,
            tokenHash: Self.hash(refreshToken),
            familyID: familyID,
            expiresAt: issuedAt.addingTimeInterval(configuration.refreshTokenLifetime),
            deviceLabel: deviceLabel
        )
        try await record.create(on: database)

        return TokenPair(
            accessToken: accessToken,
            accessTokenExpiresIn: Int(configuration.accessTokenLifetime),
            refreshToken: refreshToken
        )
    }

    private func signAccessToken(userID: UUID, issuedAt: Date) async throws -> String {
        let payload = AccessTokenPayload(
            subject: SubjectClaim(value: userID.uuidString),
            issuer: IssuerClaim(value: configuration.jwtIssuer),
            audience: AudienceClaim(value: [configuration.jwtAudience]),
            expiration: ExpirationClaim(
                value: issuedAt.addingTimeInterval(configuration.accessTokenLifetime)
            ),
            issuedAt: IssuedAtClaim(value: issuedAt),
            tokenID: IDClaim(value: UUID().uuidString)
        )

        return try await keys.sign(payload)
    }

    func verifyAccessToken(_ token: String) async throws -> AccessTokenPayload {
        let payload = try await keys.verify(token, as: AccessTokenPayload.self)

        guard payload.issuer.value == configuration.jwtIssuer else {
            throw TokenError.invalidRefreshToken
        }
        try payload.audience.verifyIntendedAudience(includes: configuration.jwtAudience)

        return payload
    }

    // MARK: - Rotation

    /// Exchanges a refresh token for a new pair.
    ///
    /// The claim is an `UPDATE ... WHERE revoked_at IS NULL`, not a read
    /// followed by a write: two simultaneous refreshes with the same token must
    /// not both succeed, and the database is the only thing that can decide
    /// that without a lock. The same philosophy as the OTP guard and, later,
    /// the bookings exclusion constraint.
    ///
    /// Strict by design. Honest clients never hit the reuse branch because the
    /// iOS `TokenStore` actor allows exactly one refresh in flight
    /// (SYSTEM-DESIGN-DIAGRAMS.md section 4); anything else looks like a stolen
    /// token and costs the family.
    func rotate(refreshToken presented: String, deviceLabel: String? = nil) async throws -> TokenPair {
        guard let sql = database as? any SQLDatabase else {
            throw RawSQLMigrationError.databaseIsNotSQL
        }

        let hash = Self.hash(presented)

        let claimed = try await sql.raw("""
            UPDATE refresh_tokens
               SET revoked_at = \(bind: now()),
                   revoked_reason = \(bind: RefreshTokenRevocationReason.rotated.rawValue)
             WHERE token_hash = \(bind: hash)
               AND revoked_at IS NULL
               AND expires_at > \(bind: now())
            RETURNING user_id, family_id
            """).first()

        guard let claimed else {
            // Either the token never existed, or it is expired, or someone
            // already rotated it. Only the last of those is theft, so look
            // before reaching for the family.
            try await revokeFamilyIfTokenWasAlreadyRotated(hash: hash, on: sql)
            throw TokenError.invalidRefreshToken
        }

        let userID = try claimed.decode(column: "user_id", as: UUID.self)
        let familyID = try claimed.decode(column: "family_id", as: UUID.self)

        return try await issuePair(for: userID, familyID: familyID, deviceLabel: deviceLabel)
    }

    /// Decides whether a refused refresh is theft or just a dead session.
    ///
    /// Only a token revoked *by rotation* is reuse. One revoked because the
    /// user logged out, reset their password or deleted their account is an
    /// ordinary expired session - and counting those as theft would bury real
    /// token reuse under everyday sign-outs, which is the one thing here worth
    /// alerting on.
    private func revokeFamilyIfTokenWasAlreadyRotated(hash: String, on sql: any SQLDatabase) async throws {
        let existing = try await RefreshToken.query(on: database)
            .filter(\.$tokenHash == hash)
            .first()

        guard let existing, existing.revokedAt != nil, existing.revokedReason == .rotated else {
            return
        }

        try await revokeFamily(existing.familyID, reason: .reuseDetected)

        // Thrown instead of returning so the caller cannot accidentally treat a
        // theft as an ordinary bad token.
        throw TokenError.refreshTokenReused
    }

    /// Signs one device family out. Used by `/auth/logout` and by reuse
    /// detection.
    func revokeFamily(_ familyID: UUID, reason: RefreshTokenRevocationReason) async throws {
        try await RefreshToken.query(on: database)
            .filter(\.$familyID == familyID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: now())
            .set(\.$revokedReason, to: reason)
            .update()
    }

    /// Signs every device out. Used by password reset and account deletion -
    /// after either, a token minted before the change must stop working.
    func revokeAll(for userID: UUID, reason: RefreshTokenRevocationReason) async throws {
        try await RefreshToken.query(on: database)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: now())
            .set(\.$revokedReason, to: reason)
            .update()
    }

    func familyID(forRefreshToken presented: String) async throws -> UUID? {
        try await RefreshToken.query(on: database)
            .filter(\.$tokenHash == Self.hash(presented))
            .first()?
            .familyID
    }

    // MARK: - Token material

    /// 32 bytes of randomness, base64url without padding. 256 bits means the
    /// value is unguessable, which is what lets us store it under a plain
    /// SHA-256 instead of a slow hash.
    static func generateRefreshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()

        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }

        return Data(bytes).base64URLEncodedString()
    }

    static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    /// base64url, unpadded: safe in a URL, a header, and a JSON string.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
