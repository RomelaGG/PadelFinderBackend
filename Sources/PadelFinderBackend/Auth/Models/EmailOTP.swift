import Fluent
import Foundation

/// A 6-digit code emailed to an address.
///
/// It is a password with a 10-minute life, so it is stored the way a password
/// is: **only the Bcrypt hash**, never the digits. It dies on first use, on
/// expiry, or after 5 wrong tries - and "first use" is decided by the database,
/// not by an `if`. See `OTPService.consume`.
final class EmailOTP: Model, @unchecked Sendable {
    static let schema = "email_otps"

    @ID(key: .id)
    var id: UUID?

    /// The address the code was sent to. For `emailChange` this is the *new*
    /// address, and `user` is the account asking to move to it.
    @Field(key: "email")
    var email: String

    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "purpose")
    var purpose: OTPPurpose

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Set exactly once, by the atomic consume statement. Also set early when
    /// the attempt ceiling is hit, which is how a burned code dies.
    @OptionalField(key: "consumed_at")
    var consumedAt: Date?

    @Field(key: "attempt_count")
    var attemptCount: Int

    /// Only set for `emailChange`: the account requesting the new address.
    @OptionalParent(key: "user_id")
    var user: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        codeHash: String,
        purpose: OTPPurpose,
        expiresAt: Date,
        userID: UUID? = nil
    ) {
        self.id = id
        self.email = email
        self.codeHash = codeHash
        self.purpose = purpose
        self.expiresAt = expiresAt
        self.consumedAt = nil
        self.attemptCount = 0
        self.$user.id = userID
    }
}
