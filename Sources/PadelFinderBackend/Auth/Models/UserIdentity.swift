import Fluent
import Foundation

/// One way of signing in to one account: Apple, Google, or our own password.
///
/// `(provider, subject)` is unique and is the real identity key. For Apple and
/// Google the subject is their stable opaque id - never the email, which can
/// change. For `password` the subject is the normalized email at registration.
final class UserIdentity: Model, @unchecked Sendable {
    static let schema = "user_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "provider")
    var provider: AuthProvider

    @Field(key: "subject")
    var subject: String

    /// The address this provider reported. Unlike `User.email` it may be
    /// unproved, so nothing may be granted on the strength of it alone.
    ///
    /// Apple sends the email only on the *first* authorization, so this is
    /// never overwritten with `nil` on a later sign-in.
    @OptionalField(key: "email_at_provider")
    var emailAtProvider: String?

    @Field(key: "email_verified")
    var emailVerified: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        provider: AuthProvider,
        subject: String,
        emailAtProvider: String?,
        emailVerified: Bool
    ) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.subject = subject
        self.emailAtProvider = emailAtProvider
        self.emailVerified = emailVerified
    }
}
