import Fluent
import Foundation

/// A user's password, Bcrypt-hashed at cost 12 or higher
/// (ARCHITECTURE.md section 4). At most one row per user, enforced by a unique
/// index on `user_id`.
final class UserCredential: Model, @unchecked Sendable {
    static let schema = "user_credentials"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "password_hash")
    var passwordHash: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, passwordHash: String) {
        self.id = id
        self.$user.id = userID
        self.passwordHash = passwordHash
    }
}
