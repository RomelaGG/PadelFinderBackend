import Foundation

/// How a user proved who they are. One user can have several.
enum AuthProvider: String, Codable, Sendable, CaseIterable {
    case apple
    case google
    case password
}

/// A user row exists before its email is proved, so the status says whether it
/// is a real account yet.
///
/// `pendingVerification` is the placeholder written by `POST /auth/register`:
/// it holds the password and the unproved email until the signup code is
/// consumed. It can never be signed into.
enum UserStatus: String, Codable, Sendable {
    case pendingVerification = "pending_verification"
    case active
    /// Deleted by its owner (P-08), or folded into another account by a merge.
    ///
    /// Redundant with `deleted_at` as far as Fluent is concerned - it excludes
    /// soft-deleted rows from every query automatically. Set anyway so the row
    /// says what it is: later phases write raw SQL against these tables (the
    /// bookings exclusion constraint has no Fluent equivalent), and raw SQL
    /// gets no such help.
    case deleted
}

/// What an emailed code is for. The same table serves all three; the purpose
/// keeps a reset code from being spent on a signup, and vice versa.
enum OTPPurpose: String, Codable, Sendable, CaseIterable {
    case signup
    case reset
    case emailChange = "email_change"
}

/// Why a refresh token stopped working.
///
/// The distinction that matters is `rotated` versus everything else. A token
/// revoked *by rotation* and then presented again is the theft signal from
/// ARCHITECTURE.md section 4 and costs the whole family. A token revoked
/// because somebody logged out, reset their password or deleted their account
/// is simply a dead session, and treating that as theft would bury real token
/// reuse under ordinary sign-outs - the one metric we would actually want to
/// alert on.
enum RefreshTokenRevocationReason: String, Codable, Sendable {
    /// Exchanged for a new token. Presenting it again is reuse.
    case rotated
    case logout
    case passwordReset = "password_reset"
    case accountDeleted = "account_deleted"
    /// Revoked because a sibling token was reused. Recorded so "how often does
    /// this actually happen?" is answerable.
    case reuseDetected = "reuse_detected"
}
