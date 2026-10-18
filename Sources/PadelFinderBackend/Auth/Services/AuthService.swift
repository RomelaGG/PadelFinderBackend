import Fluent
import Foundation
import Vapor

/// Every account operation, in one place, so the HTTP layer only decodes,
/// delegates and encodes.
///
/// Composed of `TokenService`, `OTPService` and `AccountLinker`; the ordering
/// rules live here, the guarantees live in those three.
struct AuthService: Sendable {
    let database: any Database
    let tokens: TokenService
    let otps: OTPService
    let linker: AccountLinker
    let hasher: any PasswordHashing
    let configuration: AuthConfiguration

    // MARK: - Email and password

    /// Starts email+password sign-up.
    ///
    /// Writes a placeholder account - email `NULL`, status `pendingVerification`
    /// - that holds the password until the emailed code proves the address. The
    /// placeholder can never be signed into, which is what makes it safe to
    /// create one for an address the caller does not own.
    ///
    /// Always succeeds from the caller's point of view. Reporting "that email
    /// is taken" here would make this endpoint a way to enumerate our users.
    func register(
        email rawEmail: String,
        password: String,
        displayName: String?,
        clientIP: String?
    ) async throws {
        let email = rawEmail.normalizedEmail

        // Already a real account with a password: send nothing and say nothing.
        //
        // Once a mail provider is wired up, this is where a "you already have
        // an account - sign in or reset your password" email belongs. It is the
        // one message that helps the owner without telling a stranger anything,
        // because it goes to the address rather than into the response.
        if let existing = try await linker.activeUser(withProvedEmail: email) {
            let existingID = try existing.requireID()
            let hasPassword = try await UserCredential.query(on: database)
                .filter(\.$user.$id == existingID)
                .count() > 0

            if hasPassword {
                return
            }
        }

        // Claimed here, before the two Bcrypt hashes and the two row inserts
        // below, because this endpoint takes no authentication. Checking after
        // the work would mean a refused request still cost a quarter-second of
        // CPU and a junk user row - which on one shared vCPU is a denial of
        // service against the availability API as much as against sign-up.
        //
        // After the early return above, so repeatedly registering a real
        // user's address cannot burn the allowance they need for a reset.
        let allowance = try await otps.claimSendAllowance(for: email, clientIP: clientIP)

        // Hashed before the transaction below, never inside it: Bcrypt at cost
        // 12 takes about a quarter of a second, and holding a database
        // connection for that long is how a connection pool runs dry under
        // load.
        let passwordHash = try await hasher.hash(password)

        if try await adoptExistingSignup(email: email, passwordHash: passwordHash) == false {
            do {
                try await createPlaceholder(
                    email: email,
                    passwordHash: passwordHash,
                    displayName: displayName
                )
            } catch let error where error.isDatabaseConstraintFailure {
                // Two people - or one person tapping twice - registering the
                // same address at the same moment. The unique index on
                // (provider, subject) refuses the second insert, which is
                // exactly what it is for. Nothing is wrong: the first request
                // created the placeholder, so adopt it rather than answering
                // 500 to somebody who merely double-tapped.
                guard try await adoptExistingSignup(email: email, passwordHash: passwordHash) else {
                    throw error
                }
            }
        }

        try await otps.issue(allowance, purpose: .signup)
    }

    /// Reuses an existing password sign-up for this address, if there is one.
    ///
    /// Returns false when there is nothing to reuse.
    private func adoptExistingSignup(email: String, passwordHash: String) async throws -> Bool {
        guard let found = try await linker.userForPasswordIdentity(email: email) else {
            return false
        }

        // Registering again for an address still waiting on its code. Safe to
        // overwrite the stored password while the account is a placeholder - it
        // grants nothing - and it is the natural path for "I mistyped my
        // password" or "the email never arrived".
        //
        // If the account is already active the password is left alone, because
        // changing it would be a password reset with no proof of the old one.
        // The code still goes out; verifying it just signs them in.
        if found.user.status == .pendingVerification {
            try await storePasswordHash(passwordHash, for: found.user, on: database)
        }

        return true
    }

    /// Creates the placeholder account, its password identity and its
    /// credential as one unit.
    ///
    /// In a transaction so a lost race leaves nothing behind. Without it, the
    /// user row would survive a rejected identity insert as an orphan with no
    /// way to sign in and no way to be cleaned up.
    private func createPlaceholder(email: String, passwordHash: String, displayName: String?) async throws {
        try await database.transaction { database in
            let user = User.pendingVerification(displayName: displayName)
            try await user.create(on: database)

            let identity = UserIdentity(
                userID: try user.requireID(),
                provider: .password,
                subject: email,
                emailAtProvider: email,
                emailVerified: false
            )
            try await identity.create(on: database)

            try await storePasswordHash(passwordHash, for: user, on: database)
        }
    }

    /// Finishes sign-up: consumes the code, which proves the address, and lets
    /// the linker decide whether this becomes a new account or joins one.
    func verifySignup(email rawEmail: String, code: String) async throws -> (TokenPair, User) {
        let email = rawEmail.normalizedEmail

        try await otps.verifyAndConsume(code: code, email: email, purpose: .signup)

        guard let found = try await linker.userForPasswordIdentity(email: email) else {
            // The code was right but there is no password sign-up to finish.
            // Reachable if the account was deleted between the two requests.
            throw AuthAbort(.notFound, .invalidCredentials, "No pending sign-up for this address")
        }

        let user = try await linker.resolve(
            IdentityClaim(
                provider: .password,
                subject: email,
                email: email,
                emailIsProved: true,
                displayName: found.user.displayName
            )
        )

        return (try await tokens.issuePair(for: try user.requireID()), user)
    }

    func login(
        email rawEmail: String,
        password: String,
        clientIP: String? = nil
    ) async throws -> (TokenPair, User) {
        let email = rawEmail.normalizedEmail

        guard let found = try await linker.userForPasswordIdentity(email: email) else {
            throw AuthAbort.invalidCredentials
        }

        let userID = try found.user.requireID()

        guard let credential = try await UserCredential.query(on: database)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw AuthAbort.invalidCredentials
        }

        guard try await hasher.verify(password, created: credential.passwordHash) else {
            throw AuthAbort.invalidCredentials
        }

        // Checked only after the password, so this never reveals which
        // addresses have unverified accounts. By this point the caller has
        // proved they own the account, so telling them what is wrong is both
        // safe and the only way the app can send them to the code screen.
        guard found.user.status == .active else {
            // A fresh code is a convenience, not the point of the request, so a
            // spent allowance must not turn a correct password into an error.
            let resent: Bool

            do {
                let allowance = try await otps.claimSendAllowance(for: email, clientIP: clientIP)
                try await otps.issue(allowance, purpose: .signup)
                resent = true
            } catch {
                resent = false
            }

            throw AuthAbort(
                .forbidden,
                .emailNotVerified,
                resent
                    ? "Confirm your email address. We have sent you a new code."
                    : "Confirm your email address using the code we already sent you."
            )
        }

        return (try await tokens.issuePair(for: userID), found.user)
    }

    // MARK: - Social

    func signIn(with verifier: any IdentityTokenVerifier, token: String, nonce: String?) async throws -> (TokenPair, User) {
        let claim: IdentityClaim

        do {
            claim = try await verifier.verify(token, expectedNonce: nonce)
        } catch let error as IdentityVerificationError {
            throw Self.abort(for: error, provider: verifier.provider)
        } catch {
            throw AuthAbort(
                .unauthorized,
                .identityVerificationFailed,
                "Could not verify the \(verifier.provider.rawValue) token"
            )
        }

        let user = try await linker.resolve(claim)
        return (try await tokens.issuePair(for: try user.requireID()), user)
    }

    private static func abort(for error: IdentityVerificationError, provider: AuthProvider) -> AuthAbort {
        switch error {
        case .notConfigured(let provider):
            return AuthAbort(
                .serviceUnavailable,
                .providerNotConfigured,
                "Sign in with \(provider.rawValue.capitalized) is not configured on this server"
            )
        case .audienceMismatch:
            return AuthAbort(
                .unauthorized,
                .identityVerificationFailed,
                "Token was not issued for this app"
            )
        case .nonceMismatch:
            return AuthAbort(
                .unauthorized,
                .identityVerificationFailed,
                "Token nonce does not match the sign-in request"
            )
        case .emailMissing, .emailNotVerifiedByProvider:
            return AuthAbort(
                .unauthorized,
                .identityVerificationFailed,
                "\(provider.rawValue.capitalized) did not give us a verified email address"
            )
        }
    }

    // MARK: - Password reset

    /// Sends a reset code, if the address belongs to a real account.
    ///
    /// Always reports success. The response must not differ between a known and
    /// an unknown address.
    func requestPasswordReset(email rawEmail: String, clientIP: String?) async throws {
        let email = rawEmail.normalizedEmail

        // Before the claim, so hammering this endpoint with a real address
        // cannot exhaust that user's allowance and lock them out of their own
        // reset. Costs two indexed lookups and no hashing.
        guard try await linker.activeUser(withProvedEmail: email) != nil else {
            return
        }

        let allowance = try await otps.claimSendAllowance(for: email, clientIP: clientIP)
        try await otps.issue(allowance, purpose: .reset)
    }

    /// Sets a new password and signs every device out.
    ///
    /// Revoking all sessions is the point: if the reset happened because
    /// someone else had the account, leaving their refresh token alive would
    /// make the reset pointless.
    ///
    /// Also serves as "add a password" for an account that only had Apple or
    /// Google. The address was just proved by the code, so there is nothing
    /// weaker about arriving that way.
    func resetPassword(email rawEmail: String, code: String, newPassword: String) async throws {
        let email = rawEmail.normalizedEmail

        try await otps.verifyAndConsume(code: code, email: email, purpose: .reset)

        guard let user = try await linker.activeUser(withProvedEmail: email) else {
            throw AuthAbort(.notFound, .invalidCredentials, "No account for this address")
        }

        try await setPassword(newPassword, for: user)

        if try await linker.identity(provider: .password, subject: email) == nil {
            let identity = UserIdentity(
                userID: try user.requireID(),
                provider: .password,
                subject: email,
                emailAtProvider: email,
                emailVerified: true
            )
            try await identity.create(on: database)
        }

        try await tokens.revokeAll(for: try user.requireID(), reason: .passwordReset)
    }

    // MARK: - Email change

    func requestEmailChange(for user: User, newEmail rawEmail: String, clientIP: String?) async throws {
        let email = rawEmail.normalizedEmail

        guard email != user.email else {
            throw AuthAbort(.badRequest, .validationFailed, "That is already your email address")
        }

        // Safe to report here, unlike on register: the caller is signed in, so
        // this is not an enumeration oracle - and refusing silently would leave
        // them waiting for a code that never comes.
        guard try await linker.activeUser(withProvedEmail: email) == nil else {
            throw AuthAbort(.conflict, .emailAlreadyInUse, "That email address is already in use")
        }

        let allowance = try await otps.claimSendAllowance(for: email, clientIP: clientIP)
        try await otps.issue(allowance, purpose: .emailChange, userID: try user.requireID())
    }

    /// Moves the account to a new, now-proved address.
    ///
    /// The password identity's subject moves with it, because that subject is
    /// what `/auth/login` looks up - leaving it behind would mean signing in
    /// with the old address forever.
    func confirmEmailChange(for user: User, newEmail rawEmail: String, code: String) async throws -> TokenPair {
        let email = rawEmail.normalizedEmail
        let userID = try user.requireID()

        let record = try await otps.verifyAndConsume(code: code, email: email, purpose: .emailChange)

        // The code is bound to the account that asked for the change, so a code
        // emailed to one user cannot be redeemed by another.
        guard record.$user.id == userID else {
            throw AuthAbort(.forbidden, .invalidCode, "That code was issued for a different account")
        }

        guard try await linker.activeUser(withProvedEmail: email) == nil else {
            throw AuthAbort(.conflict, .emailAlreadyInUse, "That email address is already in use")
        }

        try await database.transaction { database in
            user.email = email
            try await user.save(on: database)

            let identities = try await UserIdentity.query(on: database)
                .filter(\.$user.$id == userID)
                .all()

            for identity in identities {
                if identity.provider == .password {
                    identity.subject = email
                    identity.emailAtProvider = email
                    identity.emailVerified = true
                    try await identity.save(on: database)
                }
            }
        }

        // Changing the address is a security-relevant change, so every other
        // device is signed out. A fresh pair is returned so the device that did
        // it is not punished for it.
        try await tokens.revokeAll(for: userID, reason: .passwordReset)

        return try await tokens.issuePair(for: userID)
    }

    // MARK: - Profile

    func updateProfile(_ user: User, displayName: String?, phone: String?) async throws -> User {
        if let displayName {
            user.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let phone {
            user.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        try await user.save(on: database)
        return user
    }

    /// Deletes an account (P-08 - Apple rejects apps that can create an account
    /// but not delete one).
    ///
    /// A soft delete that first clears everything identifying: the row has to
    /// outlive the account because Phase 8's ledger refers to it - we keep books
    /// on money that moved, and those records cannot disappear when somebody
    /// taps a button - but nothing in it needs to still say who they were.
    ///
    /// Identities are removed outright so the address and the Apple/Google
    /// subject are free for a fresh sign-up. Soft deletes do not fire the
    /// `ON DELETE CASCADE`, so this is explicit rather than implied.
    func deleteAccount(_ user: User) async throws {
        let userID = try user.requireID()

        try await tokens.revokeAll(for: userID, reason: .accountDeleted)

        try await database.transaction { database in
            try await UserCredential.query(on: database)
                .filter(\.$user.$id == userID)
                .delete()

            try await UserIdentity.query(on: database)
                .filter(\.$user.$id == userID)
                .delete()

            user.email = nil
            user.phone = nil
            user.displayName = nil
            user.status = .deleted
            try await user.save(on: database)
            try await user.delete(on: database)
        }
    }

    // MARK: - Sessions

    func refresh(_ refreshToken: String, deviceLabel: String?) async throws -> (TokenPair, User) {
        let pair: TokenPair

        do {
            pair = try await tokens.rotate(refreshToken: refreshToken, deviceLabel: deviceLabel)
        } catch TokenError.refreshTokenReused {
            throw AuthAbort.sessionRevoked
        } catch TokenError.invalidRefreshToken {
            throw AuthAbort.invalidToken
        }

        let payload = try await tokens.verifyAccessToken(pair.accessToken)

        guard let userID = payload.userID,
              let user = try await User.find(userID, on: database)
        else {
            throw AuthAbort.invalidToken
        }

        return (pair, user)
    }

    func logout(refreshToken: String) async throws {
        guard let familyID = try await tokens.familyID(forRefreshToken: refreshToken) else {
            // Nothing to sign out. Reported as success: a client that has
            // already lost its session should not be stuck unable to log out.
            return
        }

        try await tokens.revokeFamily(familyID, reason: .logout)
    }

    // MARK: - Helpers

    func providers(for user: User) async throws -> [AuthProvider] {
        let userID = try user.requireID()

        return try await UserIdentity.query(on: database)
            .filter(\.$user.$id == userID)
            .all()
            .map(\.provider)
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func setPassword(_ password: String, for user: User) async throws {
        try await storePasswordHash(try await hasher.hash(password), for: user, on: database)
    }

    /// Writes an already-computed hash, so callers can hash outside a
    /// transaction and only hold a connection for the insert.
    private func storePasswordHash(
        _ hash: String,
        for user: User,
        on database: any Database
    ) async throws {
        let userID = try user.requireID()

        if let existing = try await UserCredential.query(on: database)
            .filter(\.$user.$id == userID)
            .first() {
            existing.passwordHash = hash
            try await existing.save(on: database)
        } else {
            try await UserCredential(userID: userID, passwordHash: hash).create(on: database)
        }
    }
}
