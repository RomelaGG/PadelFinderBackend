import Fluent
import Foundation

/// One long-lived session credential, stored as a SHA-256 hash of the opaque
/// token we handed out.
///
/// SHA-256 rather than Bcrypt on purpose: the token is 32 random bytes, so
/// there is no dictionary to attack and nothing for a slow hash to buy. The
/// unique index also needs the hash to be deterministic, which Bcrypt's salt
/// rules out.
///
/// `familyID` ties every token descended from one sign-in together. Refresh
/// rotates the token, and presenting a rotated-away token is treated as theft:
/// the whole family is revoked. See ARCHITECTURE.md section 4.
final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "family_id")
    var familyID: UUID

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    /// Set together with `revokedAt`. Only `rotated` makes a later use of this
    /// token look like theft.
    @OptionalField(key: "revoked_reason")
    var revokedReason: RefreshTokenRevocationReason?

    /// Free-text label for the "signed-in devices" screen. Never trusted for
    /// anything but display.
    @OptionalField(key: "device_label")
    var deviceLabel: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        tokenHash: String,
        familyID: UUID,
        expiresAt: Date,
        deviceLabel: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.familyID = familyID
        self.expiresAt = expiresAt
        self.revokedAt = nil
        self.revokedReason = nil
        self.deviceLabel = deviceLabel
    }
}
