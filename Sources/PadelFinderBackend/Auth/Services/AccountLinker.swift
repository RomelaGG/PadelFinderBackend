import Fluent
import Foundation
import Vapor

/// What a sign-in method asserts about who is signing in.
struct IdentityClaim: Sendable {
    let provider: AuthProvider
    /// The provider's stable id for this person. For Apple and Google their
    /// opaque subject, never the email - an email can move between accounts,
    /// a subject cannot.
    let subject: String
    let email: String?
    /// Whether the email above was *proved*: vouched for by Apple or Google, or
    /// confirmed by our own emailed code. Everything in `AccountLinker` turns
    /// on this flag, so nothing may set it optimistically.
    let emailIsProved: Bool
    let displayName: String?
}

/// Decides which account a sign-in belongs to, and is the only place allowed to
/// write `User.email`.
///
/// The rule from BUILD-PLAN.md (P-07): join two accounts only when **both**
/// emails were proved. Joining on an unproved email hands someone else's
/// account - and their saved card - to an attacker.
///
/// That rule is kept structurally rather than carefully. `User.email` is only
/// ever written from a claim with `emailIsProved == true`, which makes "is this
/// address proved?" the same question as "is it on a user row?", and removes
/// the chance of asking it the wrong way somewhere else.
struct AccountLinker: Sendable {
    let database: any Database

    /// Resolves a claim to an account, creating, attaching or merging as needed.
    ///
    /// Runs in a transaction because the merge branch moves rows between two
    /// users; a crash halfway would leave an account with a password it cannot
    /// use or an identity pointing at a deleted row.
    func resolve(_ claim: IdentityClaim) async throws -> User {
        try await database.transaction { database in
            try await Self(database: database).resolveInTransaction(claim)
        }
    }

    private func resolveInTransaction(_ claim: IdentityClaim) async throws -> User {
        let normalizedEmail = claim.email?.normalizedEmail

        // Case 1 - we have seen this identity before. The subject is the key,
        // so this is a returning user regardless of what their email says now.
        if let identity = try await identity(provider: claim.provider, subject: claim.subject) {
            let user = try await identity.$user.get(on: database)

            // Apple sends the email only on the first authorization, so a nil
            // here means "no news", never "the address was removed".
            if let normalizedEmail {
                identity.emailAtProvider = normalizedEmail
            }
            if claim.emailIsProved {
                identity.emailVerified = true
            }
            try await identity.save(on: database)

            if claim.emailIsProved, let normalizedEmail {
                return try await proveEmail(normalizedEmail, for: user, displayName: claim.displayName)
            }

            return user
        }

        // Case 2 - a new identity for an address somebody already proved. This
        // is the whole point of P-07: signing in with Google after registering
        // with a password lands in the same account, so bookings are not split
        // in two.
        if claim.emailIsProved,
           let normalizedEmail,
           let existing = try await activeUser(withProvedEmail: normalizedEmail) {
            try await attach(claim, normalizedEmail: normalizedEmail, to: existing)
            return existing
        }

        // Case 3 - nobody we know. Note that an *unproved* email creates an
        // account with no email at all; it waits on the code.
        let user = User(
            email: claim.emailIsProved ? normalizedEmail : nil,
            displayName: claim.displayName,
            status: claim.emailIsProved ? .active : .pendingVerification
        )
        try await user.create(on: database)
        try await attach(claim, normalizedEmail: normalizedEmail, to: user)

        return user
    }

    /// Writes a now-proved address onto an account - and merges if that address
    /// turns out to belong to a different account already.
    ///
    /// This is the tail of email+password sign-up: the placeholder user created
    /// by `/auth/register` arrives here once the code is typed, and either
    /// becomes a real account or is folded into the existing one.
    private func proveEmail(_ email: String, for user: User, displayName: String?) async throws -> User {
        let userID = try user.requireID()

        if let existing = try await activeUser(withProvedEmail: email), try existing.requireID() != userID {
            try await merge(user, into: existing)
            return existing
        }

        if user.email != email || user.status != .active {
            user.email = email
            user.status = .active
            if user.displayName == nil {
                user.displayName = displayName
            }
            try await user.save(on: database)
        }

        return user
    }

    /// Folds `source` into `destination` and soft-deletes it.
    ///
    /// `destination` wins every conflict, because it is the account that proved
    /// this address first. In particular its password is kept: letting a later
    /// sign-up overwrite it would be a password reset with no proof of the old
    /// one.
    private func merge(_ source: User, into destination: User) async throws {
        let sourceID = try source.requireID()
        let destinationID = try destination.requireID()

        let destinationIdentities = try await UserIdentity.query(on: database)
            .filter(\.$user.$id == destinationID)
            .all()
        let taken = Set(destinationIdentities.map { "\($0.provider.rawValue)|\($0.subject)" })

        let sourceIdentities = try await UserIdentity.query(on: database)
            .filter(\.$user.$id == sourceID)
            .all()

        for identity in sourceIdentities {
            // The (provider, subject) unique index would reject a duplicate.
            // It should not be reachable - the same subject cannot already be
            // on two accounts - but a merge is not the place to find out.
            if taken.contains("\(identity.provider.rawValue)|\(identity.subject)") {
                try await identity.delete(on: database)
                continue
            }

            identity.$user.id = destinationID
            try await identity.save(on: database)
        }

        let destinationHasPassword = try await UserCredential.query(on: database)
            .filter(\.$user.$id == destinationID)
            .count() > 0

        let sourceCredentials = try await UserCredential.query(on: database)
            .filter(\.$user.$id == sourceID)
            .all()

        for credential in sourceCredentials {
            if destinationHasPassword {
                try await credential.delete(on: database)
            } else {
                credential.$user.id = destinationID
                try await credential.save(on: database)
            }
        }

        if destination.displayName == nil, let displayName = source.displayName {
            destination.displayName = displayName
            try await destination.save(on: database)
        }

        // Clear the identifying fields before the soft delete, so the row that
        // survives for the ledger holds nothing identifying.
        source.email = nil
        source.phone = nil
        source.displayName = nil
        source.status = .deleted
        try await source.save(on: database)
        try await source.delete(on: database)
    }

    private func attach(_ claim: IdentityClaim, normalizedEmail: String?, to user: User) async throws {
        let identity = UserIdentity(
            userID: try user.requireID(),
            provider: claim.provider,
            subject: claim.subject,
            emailAtProvider: normalizedEmail,
            emailVerified: claim.emailIsProved
        )
        try await identity.create(on: database)
    }

    // MARK: - Lookups

    func identity(provider: AuthProvider, subject: String) async throws -> UserIdentity? {
        try await UserIdentity.query(on: database)
            .filter(\.$provider == provider)
            .filter(\.$subject == subject)
            .first()
    }

    /// The only lookup by email that may grant anything, precisely because
    /// `User.email` is always proved.
    func activeUser(withProvedEmail email: String) async throws -> User? {
        try await User.query(on: database)
            .filter(\.$email == email.normalizedEmail)
            .filter(\.$status == .active)
            .first()
    }

    /// Finds the account behind an email+password sign-in.
    ///
    /// Goes through the identity rather than `User.email` so it also finds a
    /// placeholder that has not proved its address yet - which is what lets
    /// `/auth/login` answer "verify your email first" instead of "no such
    /// account".
    func userForPasswordIdentity(email: String) async throws -> (user: User, identity: UserIdentity)? {
        guard let identity = try await identity(provider: .password, subject: email.normalizedEmail) else {
            return nil
        }

        let user = try await identity.$user.get(on: database)
        return (user, identity)
    }
}
