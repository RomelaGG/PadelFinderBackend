import Fluent
import Foundation
import Vapor

/// An account.
///
/// The one invariant the whole auth design rests on: **`email` is always a
/// proved email.** An address only lands here once a provider vouched for it
/// (Apple, Google) or the owner typed our 6-digit code. An unproved address
/// lives on `UserIdentity.emailAtProvider` and nowhere else.
///
/// That is what makes account linking safe. If unproved emails could reach this
/// column, registering `victim@gmail.com` with a password you never confirmed
/// would hand you the real owner's account the moment they signed in with
/// Google — saved card and booking history included.
final class User: Model, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    /// Nullable because a `pendingVerification` placeholder has no proved email
    /// yet, and because deleting an account releases the address.
    @OptionalField(key: "email")
    var email: String?

    /// Collected at checkout so a venue can call about a late arrival.
    /// Deliberately **unverified** - see ARCHITECTURE.md section 4.
    @OptionalField(key: "phone")
    var phone: String?

    @OptionalField(key: "display_name")
    var displayName: String?

    @Field(key: "status")
    var status: UserStatus

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    /// Account deletion is a soft delete (P-08). The row has to outlive the
    /// account because Phase 8's ledger refers to it: we are keeping books on
    /// money that moved, and that record cannot vanish when someone taps
    /// "Delete account". The identifying fields are cleared instead.
    @Timestamp(key: "deleted_at", on: .delete)
    var deletedAt: Date?

    @Children(for: \.$user)
    var identities: [UserIdentity]

    init() {}

    init(
        id: UUID? = nil,
        email: String?,
        phone: String? = nil,
        displayName: String? = nil,
        status: UserStatus
    ) {
        self.id = id
        self.email = email
        self.phone = phone
        self.displayName = displayName
        self.status = status
    }

    /// A placeholder created by email+password registration, holding the
    /// password until the signup code proves the address.
    static func pendingVerification(displayName: String? = nil) -> User {
        User(email: nil, displayName: displayName, status: .pendingVerification)
    }
}
