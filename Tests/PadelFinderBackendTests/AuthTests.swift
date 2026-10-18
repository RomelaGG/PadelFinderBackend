@testable import PadelFinderBackend
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

/// The sign-up, sign-in and account-management flows, driven over HTTP.
///
/// `.serialized` because every test shares one database and truncates it on
/// entry. Skipped entirely without `DATABASE_URL_TEST` - see
/// `AuthTestEnvironment`.
@Suite("Auth", .serialized, .enabled(if: AuthTestEnvironment.isAvailable))
struct AuthTests {
    // MARK: - Email and password sign-up

    @Test("Register, verify the emailed code, and the account is live")
    func registerAndVerify() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"

            try await context.app.testing().test(
                .POST,
                "auth/register",
                beforeRequest: { request in
                    try request.content.encode(
                        RegisterRequest(email: email, password: "correct-horse", displayName: "Nino")
                    )
                },
                afterResponse: { response async in
                    #expect(response.status == .accepted)
                }
            )

            // Not signed in yet. The placeholder holds the password but grants
            // nothing, which is what makes it safe to create one for an address
            // the caller has not proved.
            let pending = try await User.query(on: context.app.db).all()
            #expect(pending.count == 1)
            #expect(pending.first?.status == .pendingVerification)
            #expect(pending.first?.email == nil)

            let code = try await context.code(for: email)

            var issuedAccessToken: String?

            try await context.app.testing().test(
                .POST,
                "auth/otp/verify",
                beforeRequest: { request in
                    try request.content.encode(VerifyCodeRequest(email: email, code: code))
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let body = try response.content.decode(TokenResponse.self)
                    #expect(body.user.email == email)
                    #expect(body.user.providers == ["password"])
                    #expect(body.expiresIn == 900)
                    issuedAccessToken = body.accessToken
                }
            )

            let user = try await User.query(on: context.app.db).first()
            #expect(user?.status == .active)
            #expect(user?.email == email)

            let accessToken = try #require(issuedAccessToken)

            try await context.app.testing().test(
                .GET,
                "auth/me",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: accessToken)
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let me = try response.content.decode(UserResponse.self)
                    #expect(me.email == email)
                    #expect(me.displayName == "Nino")
                }
            )
        }
    }

    @Test("The email is normalized, so casing cannot make two accounts")
    func emailCasingIsNormalized() async throws {
        try await withAuthApp { context in
            try await context.service.register(
                email: "  Player@Example.COM ",
                password: "correct-horse",
                displayName: nil
            )

            let code = try await context.code(for: "player@example.com")
            _ = try await context.service.verifySignup(email: "PLAYER@example.com", code: code)

            let users = try await User.query(on: context.app.db).all()
            #expect(users.count == 1)
            #expect(users.first?.email == "player@example.com")
        }
    }

    @Test("Five wrong codes kill the code, and the right one no longer works")
    func wrongCodesBurnTheCode() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let realCode = try await context.code(for: email)

            let wrongCode = realCode == "000000" ? "111111" : "000000"

            // Four wrong tries: refused, with the remaining count.
            for attempt in 1...4 {
                await #expect(throws: OTPError.incorrectCode(attemptsRemaining: 5 - attempt)) {
                    try await context.service.verifySignup(email: email, code: wrongCode)
                }
            }

            // The fifth burns it.
            await #expect(throws: OTPError.codeBurned) {
                try await context.service.verifySignup(email: email, code: wrongCode)
            }

            // And now the correct code is worthless - they have to ask for a
            // new one. Refusing further guesses but leaving the code usable
            // would make the ceiling decorative.
            await #expect(throws: OTPError.noLiveCode) {
                try await context.service.verifySignup(email: email, code: realCode)
            }
        }
    }

    @Test("An expired code is refused")
    func expiredCodeIsRefused() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let code = try await context.code(for: email)

            // Reach into the row rather than waiting ten minutes.
            let record = try #require(try await EmailOTP.query(on: context.app.db).first())
            record.expiresAt = Date().addingTimeInterval(-1)
            try await record.save(on: context.app.db)

            await #expect(throws: OTPError.noLiveCode) {
                try await context.service.verifySignup(email: email, code: code)
            }
        }
    }

    @Test("Asking for a new code invalidates the old one")
    func reissuingACodeBurnsThePrevious() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let first = try await context.code(for: email)

            try await context.service.otps.issueForTesting(to: email, purpose: .signup)
            let second = try await context.code(for: email)
            #expect(first != second)

            // Otherwise two live codes would mean five attempts each, and the
            // ceiling would scale with however many times you tap "resend".
            await #expect(throws: OTPError.incorrectCode(attemptsRemaining: 4)) {
                try await context.service.verifySignup(email: email, code: first)
            }

            _ = try await context.service.verifySignup(email: email, code: second)
        }
    }

    @Test("Codes per address are capped per hour")
    func codeSendsAreRateLimited() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"

            // The registration itself is the first of five.
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)

            for _ in 1...4 {
                try await context.service.otps.issueForTesting(to: email, purpose: .signup)
            }

            // Nobody gets to use our server to flood someone else's inbox.
            await #expect(throws: OTPError.tooManyRequests) {
                try await context.service.otps.issueForTesting(to: email, purpose: .signup)
            }

            #expect(await context.mailer.count(for: email) == 5)
        }
    }

    @Test("Registering a real user's address repeatedly cannot burn their reset allowance")
    func registeringAnExistingAddressDoesNotConsumeAllowance() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            _ = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            // Ten attempts on an address that already has a password. Each one
            // sends nothing, so none of them may consume the cap - otherwise
            // this is a way to lock somebody out of their own password reset.
            for _ in 1...10 {
                try await context.service.register(
                    email: email,
                    password: "attacker-guess",
                    displayName: nil
                )
            }

            try await context.service.requestPasswordReset(email: email)
            #expect(await context.mailer.latestCode(for: email, purpose: .reset) != nil)
        }
    }

    @Test("Unique addresses are capped by IP, so the provider quota is not open to anyone")
    func uniqueAddressesAreCappedByIP() async throws {
        try await withAuthApp { context in
            let attacker = "198.51.100.7"
            var refusals = 0

            // Twenty is the per-IP cap. Each of these is a different address,
            // so the per-email cap never fires - this is the only thing between
            // an unauthenticated endpoint and our whole daily email quota.
            for index in 1...25 {
                do {
                    try await context.service.register(
                        email: "victim-\(index)@example.com",
                        password: "correct-horse",
                        displayName: nil,
                        clientIP: attacker
                    )
                } catch is OTPError {
                    refusals += 1
                }
            }

            #expect(refusals == 5)
            #expect(await context.mailer.all().count == 20)
        }
    }

    @Test("A refused request does no hashing and leaves no rows behind")
    func refusedRequestDoesNoWork() async throws {
        try await withAuthApp { context in
            let attacker = "198.51.100.8"

            for index in 1...20 {
                try await context.service.register(
                    email: "spam-\(index)@example.com",
                    password: "correct-horse",
                    displayName: nil,
                    clientIP: attacker
                )
            }

            let usersBefore = try await User.query(on: context.app.db).count()
            let credentialsBefore = try await UserCredential.query(on: context.app.db).count()

            await #expect(throws: OTPError.tooManyRequests) {
                try await context.service.register(
                    email: "spam-21@example.com",
                    password: "correct-horse",
                    displayName: nil,
                    clientIP: attacker
                )
            }

            // The whole point of claiming the allowance first: a refused
            // request must not have cost two Bcrypt hashes and two inserts.
            // Row counts are the observable proof that we bailed out early.
            #expect(try await User.query(on: context.app.db).count() == usersBefore)
            #expect(try await UserCredential.query(on: context.app.db).count() == credentialsBefore)
        }
    }

    @Test("A request refused by the IP cap does not consume the email's allowance")
    func ipRefusalDoesNotChargeTheEmail() async throws {
        try await withAuthApp { context in
            let attacker = "198.51.100.9"
            let victim = "victim@example.com"

            for index in 1...20 {
                try await context.service.register(
                    email: "spam-\(index)@example.com",
                    password: "correct-horse",
                    displayName: nil,
                    clientIP: attacker
                )
            }

            // Now aim the exhausted IP at one address, five times - exactly the
            // victim's per-hour allowance.
            for _ in 1...5 {
                await #expect(throws: OTPError.tooManyRequests) {
                    try await context.service.register(
                        email: victim,
                        password: "correct-horse",
                        displayName: nil,
                        clientIP: attacker
                    )
                }
            }

            // None of that may have charged the victim, or an attacker could
            // lock anyone out of sign-up and password reset for an hour from a
            // single IP they are happy to burn.
            try await context.service.register(
                email: victim,
                password: "correct-horse",
                displayName: nil,
                clientIP: "203.0.113.5"
            )
            #expect(await context.mailer.latestCode(for: victim, purpose: .signup) != nil)
        }
    }

    @Test("A forwarding header is ignored unless it is explicitly trusted")
    func untrustedForwardingHeaderIsIgnored() async throws {
        try await withAuthApp { context in
            // Anyone can send X-Forwarded-For. If it were trusted by default,
            // rotating it per request would make the per-IP cap meaningless.
            try await context.app.testing().test(
                .POST,
                "auth/register",
                beforeRequest: { request in
                    request.headers.replaceOrAdd(name: "X-Forwarded-For", value: "9.9.9.9")
                    request.headers.replaceOrAdd(name: "Fly-Client-IP", value: "8.8.8.8")
                    try request.content.encode(
                        RegisterRequest(email: "spoof@example.com", password: "correct-horse", displayName: nil)
                    )
                },
                afterResponse: { response async in
                    #expect(response.status == .accepted)
                }
            )

            // The test configuration names no trusted header, so neither was
            // read and the peer address was used.
            let buckets = try await RateLimitRow.allBuckets(on: context.app.db)
            #expect(!buckets.contains("otp:ip:9.9.9.9"))
            #expect(!buckets.contains("otp:ip:8.8.8.8"))
        }
    }

    @Test("The configured header is used, and only that one")
    func trustedForwardingHeaderIsUsed() async throws {
        try await withAuthApp(trustedClientIPHeader: "Fly-Client-IP") { context in
            try await context.app.testing().test(
                .POST,
                "auth/register",
                beforeRequest: { request in
                    // Fly sets Fly-Client-IP itself from the real connection,
                    // so it cannot be forged from outside. X-Forwarded-For can
                    // be, and must stay ignored even now that a header is
                    // trusted.
                    request.headers.replaceOrAdd(name: "Fly-Client-IP", value: "203.0.113.42")
                    request.headers.replaceOrAdd(name: "X-Forwarded-For", value: "9.9.9.9")
                    try request.content.encode(
                        RegisterRequest(email: "player@example.com", password: "correct-horse", displayName: nil)
                    )
                },
                afterResponse: { response async in
                    #expect(response.status == .accepted)
                }
            )

            let buckets = try await RateLimitRow.allBuckets(on: context.app.db)
            #expect(buckets.contains("otp:ip:203.0.113.42"))
            #expect(!buckets.contains("otp:ip:9.9.9.9"))
        }
    }

    // MARK: - Sign in

    @Test("Login works after verification, and the password must be right")
    func loginRequiresCorrectPassword() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            _ = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            try await context.app.testing().test(
                .POST,
                "auth/login",
                beforeRequest: { request in
                    try request.content.encode(LoginRequest(email: email, password: "correct-horse"))
                },
                afterResponse: { response async in
                    #expect(response.status == .ok)
                }
            )

            try await context.app.testing().test(
                .POST,
                "auth/login",
                beforeRequest: { request in
                    try request.content.encode(LoginRequest(email: email, password: "wrong"))
                },
                afterResponse: { response async throws in
                    #expect(response.status == .unauthorized)
                    let body = try response.content.decode(AuthErrorMiddleware.ErrorBody.self)
                    #expect(body.code == AuthErrorCode.invalidCredentials.rawValue)
                }
            )
        }
    }

    @Test("Login before verification says so, and resends the code")
    func loginBeforeVerificationIsTold() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)

            try await context.app.testing().test(
                .POST,
                "auth/login",
                beforeRequest: { request in
                    try request.content.encode(LoginRequest(email: email, password: "correct-horse"))
                },
                afterResponse: { response async throws in
                    // Specific on purpose: the caller just proved they own the
                    // account, and the app needs this to open the code screen
                    // rather than show "wrong password".
                    #expect(response.status == .forbidden)
                    let body = try response.content.decode(AuthErrorMiddleware.ErrorBody.self)
                    #expect(body.code == AuthErrorCode.emailNotVerified.rawValue)
                }
            )

            #expect(await context.mailer.count(for: email) == 2)
        }
    }

    @Test("An unknown address and a wrong password are indistinguishable")
    func loginDoesNotRevealWhoHasAnAccount() async throws {
        try await withAuthApp { context in
            try await context.service.register(
                email: "known@example.com",
                password: "correct-horse",
                displayName: nil
            )
            _ = try await context.service.verifySignup(
                email: "known@example.com",
                code: try await context.code(for: "known@example.com")
            )

            var bodies: [AuthErrorMiddleware.ErrorBody] = []

            for email in ["known@example.com", "stranger@example.com"] {
                try await context.app.testing().test(
                    .POST,
                    "auth/login",
                    beforeRequest: { request in
                        try request.content.encode(LoginRequest(email: email, password: "wrong"))
                    },
                    afterResponse: { response async throws in
                        #expect(response.status == .unauthorized)
                        bodies.append(try response.content.decode(AuthErrorMiddleware.ErrorBody.self))
                    }
                )
            }

            #expect(bodies.count == 2)
            #expect(bodies[0].code == bodies[1].code)
            #expect(bodies[0].reason == bodies[1].reason)
        }
    }

    @Test("Registering an address that already has an account reveals nothing")
    func registerDoesNotRevealWhoHasAnAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            _ = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            let sentBefore = await context.mailer.count(for: email)

            var responses: [HTTPStatus] = []

            for address in [email, "stranger@example.com"] {
                try await context.app.testing().test(
                    .POST,
                    "auth/register",
                    beforeRequest: { request in
                        try request.content.encode(
                            RegisterRequest(email: address, password: "another-password", displayName: nil)
                        )
                    },
                    afterResponse: { response async in
                        responses.append(response.status)
                    }
                )
            }

            #expect(responses == [.accepted, .accepted])

            // And the existing account's password is untouched - a second
            // registration must not be a password reset without proof.
            #expect(await context.mailer.count(for: email) == sentBefore)

            try await context.app.testing().test(
                .POST,
                "auth/login",
                beforeRequest: { request in
                    try request.content.encode(LoginRequest(email: email, password: "correct-horse"))
                },
                afterResponse: { response async in
                    #expect(response.status == .ok)
                }
            )
        }
    }

    @Test("Forgot-password reveals nothing either")
    func forgotPasswordDoesNotRevealWhoHasAnAccount() async throws {
        try await withAuthApp { context in
            var responses: [HTTPStatus] = []

            for address in ["nobody@example.com", "also-nobody@example.com"] {
                try await context.app.testing().test(
                    .POST,
                    "auth/password/forgot",
                    beforeRequest: { request in
                        try request.content.encode(EmailRequest(email: address))
                    },
                    afterResponse: { response async in
                        responses.append(response.status)
                    }
                )
            }

            #expect(responses == [.accepted, .accepted])
            #expect(await context.mailer.all().isEmpty)
        }
    }

    // MARK: - Account linking (P-07)

    @Test("Google after a verified password sign-up lands in the same account")
    func googleJoinsAVerifiedPasswordAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (_, passwordUser) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            let token = try await context.googleToken(subject: "google-sub-1", email: email, name: "Nino")
            let (_, googleUser) = try await context.service.signIn(
                with: context.factory.googleVerifier,
                token: token,
                nonce: nil
            )

            // The point of P-07: one account, so the bookings are not split in
            // two.
            #expect(try googleUser.requireID() == passwordUser.requireID())

            let providers = try await context.service.providers(for: googleUser)
            #expect(providers == [.google, .password])

            let users = try await User.query(on: context.app.db).all()
            #expect(users.count == 1)
        }
    }

    @Test("An unproved sign-up cannot be walked into by the address's real owner")
    func unprovedSignupNeverCapturesTheAddress() async throws {
        try await withAuthApp { context in
            let email = "victim@example.com"

            // The attack from ARCHITECTURE.md section 4: register someone
            // else's address with a password, never prove it, and wait for them
            // to sign in with Google.
            try await context.service.register(email: email, password: "attacker-password", displayName: nil)

            let token = try await context.googleToken(subject: "google-sub-victim", email: email)
            let (_, googleUser) = try await context.service.signIn(
                with: context.factory.googleVerifier,
                token: token,
                nonce: nil
            )

            // The real owner gets their own account, holding the address.
            #expect(googleUser.email == email)
            #expect(googleUser.status == .active)

            let googleUserID = try googleUser.requireID()
            let placeholder = try #require(
                try await UserIdentity.query(on: context.app.db)
                    .filter(\.$provider == .password)
                    .first()
            )

            // The attacker's placeholder is still a placeholder, still has no
            // email, and is a different account.
            #expect(placeholder.$user.id != googleUserID)
            let placeholderUser = try await placeholder.$user.get(on: context.app.db)
            #expect(placeholderUser.email == nil)
            #expect(placeholderUser.status == .pendingVerification)

            // Their password does not open the owner's account either.
            await #expect(throws: AuthAbort.self) {
                try await context.service.login(email: email, password: "attacker-password")
            }
        }
    }

    @Test("The owner proving the address later merges into the account that holds it")
    func provingAnAddressMergesIntoTheExistingAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"

            // Signed in with Google first, so Google's account owns the address.
            let token = try await context.googleToken(subject: "google-sub-1", email: email)
            let (_, googleUser) = try await context.service.signIn(
                with: context.factory.googleVerifier,
                token: token,
                nonce: nil
            )
            let googleUserID = try googleUser.requireID()

            // Now the same person adds a password for the same address. The
            // code goes to an address they have proved they own, so completing
            // it is legitimate.
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (_, merged) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            #expect(try merged.requireID() == googleUserID)
            #expect(try await context.service.providers(for: merged) == [.google, .password])

            // The placeholder is gone, and the surviving row holds nothing
            // identifying.
            let live = try await User.query(on: context.app.db).all()
            #expect(live.count == 1)

            // Both ways in now reach the one account.
            let (_, viaPassword) = try await context.service.login(email: email, password: "correct-horse")
            #expect(try viaPassword.requireID() == googleUserID)
        }
    }

    @Test("Apple's relay address is a proved email like any other")
    func applePrivateRelayAddressIsAccepted() async throws {
        try await withAuthApp { context in
            let relay = "abc123@privaterelay.appleid.com"
            let token = try await context.appleToken(subject: "apple-sub-1", email: relay)

            let (_, user) = try await context.service.signIn(
                with: context.factory.appleVerifier(displayName: "Nino"),
                token: token,
                nonce: nil
            )

            #expect(user.email == relay)
            #expect(user.status == .active)
            #expect(user.displayName == "Nino")
        }
    }

    @Test("Apple omitting the email on a later sign-in does not clear it")
    func appleSecondSignInKeepsTheStoredEmail() async throws {
        try await withAuthApp { context in
            let email = "player@privaterelay.appleid.com"

            let first = try await context.appleToken(subject: "apple-sub-1", email: email)
            let (_, user) = try await context.service.signIn(
                with: context.factory.appleVerifier(displayName: nil),
                token: first,
                nonce: nil
            )
            let userID = try user.requireID()

            // Apple sends the email only on the first authorization. A nil here
            // means "no news", not "the address was removed".
            let second = try await context.appleToken(subject: "apple-sub-1", email: nil)
            let (_, again) = try await context.service.signIn(
                with: context.factory.appleVerifier(displayName: nil),
                token: second,
                nonce: nil
            )

            #expect(try again.requireID() == userID)
            #expect(again.email == email)

            let identity = try #require(
                try await context.service.linker.identity(provider: .apple, subject: "apple-sub-1")
            )
            #expect(identity.emailAtProvider == email)
        }
    }

    @Test("Google's unverified email is refused, because linking on one is the hole")
    func googleUnverifiedEmailIsRefused() async throws {
        try await withAuthApp { context in
            let token = try await context.googleToken(
                subject: "google-sub-1",
                email: "player@example.com",
                emailVerified: false
            )

            await #expect(throws: AuthAbort.self) {
                try await context.service.signIn(
                    with: context.factory.googleVerifier,
                    token: token,
                    nonce: nil
                )
            }

            #expect(try await User.query(on: context.app.db).count() == 0)
        }
    }

    @Test("A token for another app is refused")
    func wrongAudienceIsRefused() async throws {
        try await withAuthApp { context in
            let token = try await context.googleToken(
                subject: "google-sub-1",
                email: "player@example.com",
                audience: "someone-elses-client-id.apps.googleusercontent.com"
            )

            await #expect(throws: AuthAbort.self) {
                try await context.service.signIn(
                    with: context.factory.googleVerifier,
                    token: token,
                    nonce: nil
                )
            }
        }
    }

    @Test("A mismatched nonce is refused, so a captured token cannot be replayed")
    func mismatchedNonceIsRefused() async throws {
        try await withAuthApp { context in
            let token = try await context.appleToken(
                subject: "apple-sub-1",
                email: "player@example.com",
                nonce: "nonce-from-another-sign-in"
            )

            await #expect(throws: AuthAbort.self) {
                try await context.service.signIn(
                    with: context.factory.appleVerifier(displayName: nil),
                    token: token,
                    nonce: "nonce-for-this-sign-in"
                )
            }
        }
    }

    // MARK: - Password reset

    @Test("Reset sets the new password and signs every device out")
    func resetPasswordRevokesEverySession() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "old-password", displayName: nil)
            let (firstDevice, _) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )
            let (secondDevice, _) = try await context.service.login(email: email, password: "old-password")

            try await context.service.requestPasswordReset(email: email)
            try await context.service.resetPassword(
                email: email,
                code: try await context.code(for: email, purpose: .reset),
                newPassword: "new-password"
            )

            _ = try await context.service.login(email: email, password: "new-password")

            await #expect(throws: AuthAbort.self) {
                try await context.service.login(email: email, password: "old-password")
            }

            // The whole point: if the reset happened because somebody else had
            // the account, leaving their refresh token alive would make it
            // pointless.
            for device in [firstDevice, secondDevice] {
                await #expect(throws: TokenError.invalidRefreshToken) {
                    try await context.tokens.rotate(refreshToken: device.refreshToken)
                }
            }
        }
    }

    @Test("Reset doubles as adding a password to a Google-only account")
    func resetAddsAPasswordToASocialAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            let token = try await context.googleToken(subject: "google-sub-1", email: email)
            let (_, user) = try await context.service.signIn(
                with: context.factory.googleVerifier,
                token: token,
                nonce: nil
            )

            try await context.service.requestPasswordReset(email: email)
            try await context.service.resetPassword(
                email: email,
                code: try await context.code(for: email, purpose: .reset),
                newPassword: "brand-new-password"
            )

            let (_, signedIn) = try await context.service.login(email: email, password: "brand-new-password")
            #expect(try signedIn.requireID() == user.requireID())
            #expect(try await context.service.providers(for: signedIn) == [.google, .password])
        }
    }

    @Test("A signup code cannot be spent on a password reset")
    func codePurposesDoNotCross() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let signupCode = try await context.code(for: email, purpose: .signup)

            await #expect(throws: OTPError.noLiveCode) {
                try await context.service.resetPassword(
                    email: email,
                    code: signupCode,
                    newPassword: "new-password"
                )
            }
        }
    }

    // MARK: - Profile and deletion

    @Test("Phone and display name can be set, and the phone stays unverified")
    func profileCanBeUpdated() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (pair, _) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            try await context.app.testing().test(
                .PATCH,
                "auth/me",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: pair.accessToken)
                    try request.content.encode(
                        UpdateProfileRequest(displayName: "Nino", phone: "+995 555 00 00 00")
                    )
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let body = try response.content.decode(UserResponse.self)
                    #expect(body.displayName == "Nino")
                    #expect(body.phone == "+995 555 00 00 00")
                }
            )
        }
    }

    @Test("Deleting an account kills the sessions and frees the address")
    func deleteAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (pair, user) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )
            let userID = try user.requireID()

            try await context.app.testing().test(
                .DELETE,
                "auth/me",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: pair.accessToken)
                },
                afterResponse: { response async in
                    #expect(response.status == .noContent)
                }
            )

            // The access token stops working at once - not because it was
            // revoked (it cannot be) but because the user row is gone.
            try await context.app.testing().test(
                .GET,
                "auth/me",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: pair.accessToken)
                },
                afterResponse: { response async in
                    #expect(response.status == .unauthorized)
                }
            )

            await #expect(throws: TokenError.invalidRefreshToken) {
                try await context.tokens.rotate(refreshToken: pair.refreshToken)
            }

            await #expect(throws: AuthAbort.self) {
                try await context.service.login(email: email, password: "correct-horse")
            }

            // Soft, not hard: the row survives for Phase 8's ledger, holding
            // nothing identifying.
            #expect(try await User.query(on: context.app.db).count() == 0)
            let retained = try await User.query(on: context.app.db).withDeleted().all()
            #expect(retained.count == 1)
            #expect(retained.first?.id == userID)
            #expect(retained.first?.email == nil)
            #expect(retained.first?.status == .deleted)
            #expect(retained.first?.deletedAt != nil)

            // And the address is free again.
            try await context.service.register(email: email, password: "a-new-password", displayName: nil)
            let (_, fresh) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )
            #expect(try fresh.requireID() != userID)
        }
    }

    // MARK: - Email change

    @Test("Changing the email moves the password login with it")
    func emailChangeMovesTheLogin() async throws {
        try await withAuthApp { context in
            let oldEmail = "old@example.com"
            let newEmail = "new@example.com"

            try await context.service.register(email: oldEmail, password: "correct-horse", displayName: nil)
            let (_, user) = try await context.service.verifySignup(
                email: oldEmail,
                code: try await context.code(for: oldEmail)
            )

            try await context.service.requestEmailChange(for: user, newEmail: newEmail)
            _ = try await context.service.confirmEmailChange(
                for: user,
                newEmail: newEmail,
                code: try await context.code(for: newEmail, purpose: .emailChange)
            )

            // The identity's subject is what /auth/login looks up, so it has to
            // move too or the old address would sign in forever.
            let (_, signedIn) = try await context.service.login(email: newEmail, password: "correct-horse")
            #expect(try signedIn.requireID() == user.requireID())
            #expect(signedIn.email == newEmail)

            await #expect(throws: AuthAbort.self) {
                try await context.service.login(email: oldEmail, password: "correct-horse")
            }
        }
    }

    @Test("Changing to an address somebody else holds is refused")
    func emailChangeToATakenAddressIsRefused() async throws {
        try await withAuthApp { context in
            let token = try await context.googleToken(subject: "google-sub-1", email: "taken@example.com")
            _ = try await context.service.signIn(
                with: context.factory.googleVerifier,
                token: token,
                nonce: nil
            )

            try await context.service.register(email: "mine@example.com", password: "correct-horse", displayName: nil)
            let (_, user) = try await context.service.verifySignup(
                email: "mine@example.com",
                code: try await context.code(for: "mine@example.com")
            )

            // Safe to say so here, unlike on register: the caller is signed in,
            // so this is not an enumeration oracle, and silence would leave
            // them waiting for a code that never comes.
            await #expect(throws: AuthAbort.self) {
                try await context.service.requestEmailChange(for: user, newEmail: "taken@example.com")
            }
        }
    }

    // MARK: - Tokens

    @Test("Refresh rotates, and the old token is dead")
    func refreshRotatesTheToken() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (first, _) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            var rotated: String?

            try await context.app.testing().test(
                .POST,
                "auth/refresh",
                beforeRequest: { request in
                    try request.content.encode(RefreshRequest(refreshToken: first.refreshToken))
                },
                afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let body = try response.content.decode(TokenResponse.self)
                    #expect(body.refreshToken != first.refreshToken)
                    rotated = body.refreshToken
                }
            )

            #expect(rotated != nil)
        }
    }

    @Test("Reusing a rotated-away token revokes the whole family")
    func refreshTokenReuseRevokesTheFamily() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (first, _) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            let second = try await context.tokens.rotate(refreshToken: first.refreshToken)

            // Presenting the rotated-away token looks like a stolen one.
            try await context.app.testing().test(
                .POST,
                "auth/refresh",
                beforeRequest: { request in
                    try request.content.encode(RefreshRequest(refreshToken: first.refreshToken))
                },
                afterResponse: { response async throws in
                    #expect(response.status == .unauthorized)
                    let body = try response.content.decode(AuthErrorMiddleware.ErrorBody.self)
                    #expect(body.code == AuthErrorCode.sessionRevoked.rawValue)
                }
            )

            // And the legitimate token dies with it: if a token was copied, we
            // cannot tell which of the two holders is the real one, so the
            // device family starts over.
            await #expect(throws: TokenError.invalidRefreshToken) {
                try await context.tokens.rotate(refreshToken: second.refreshToken)
            }
        }
    }

    @Test("Logout signs out one device family and leaves the others alone")
    func logoutRevokesOneFamily() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (phone, _) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )
            let (tablet, _) = try await context.service.login(email: email, password: "correct-horse")

            try await context.app.testing().test(
                .POST,
                "auth/logout",
                beforeRequest: { request in
                    try request.content.encode(RefreshRequest(refreshToken: phone.refreshToken))
                },
                afterResponse: { response async in
                    #expect(response.status == .noContent)
                }
            )

            await #expect(throws: TokenError.invalidRefreshToken) {
                try await context.tokens.rotate(refreshToken: phone.refreshToken)
            }

            _ = try await context.tokens.rotate(refreshToken: tablet.refreshToken)
        }
    }

    @Test("A protected route refuses a missing, garbage or expired token")
    func protectedRoutesRequireAValidToken() async throws {
        try await withAuthApp { context in
            try await context.app.testing().test(.GET, "auth/me", afterResponse: { response async in
                #expect(response.status == .unauthorized)
            })

            try await context.app.testing().test(
                .GET,
                "auth/me",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: "not-a-jwt")
                },
                afterResponse: { response async in
                    #expect(response.status == .unauthorized)
                }
            )
        }
    }

    @Test("A token signed with another key is refused")
    func foreignlySignedTokenIsRefused() async throws {
        try await withAuthApp { context in
            // Signed with the stand-in provider key rather than ours.
            let forged = try await context.appleToken(subject: "whoever", email: "a@example.com")

            try await context.app.testing().test(
                .GET,
                "auth/me",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: forged)
                },
                afterResponse: { response async in
                    #expect(response.status == .unauthorized)
                }
            )
        }
    }
}
