@testable import PadelFinderBackend
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

/// `seed-user`: creating an account that can sign in without the emailed code.
///
/// Targets `AuthService.seedVerifiedPasswordUser` rather than the command. The
/// command is a thin shell over it, and ConsoleKit ships no public test console
/// to drive one with - so the rules worth protecting are asserted where they
/// live.
///
/// `.serialized` and skipped without `DATABASE_URL_TEST`, like every other auth
/// suite: what these verify *is* Postgres - the unique indexes and the
/// credential upsert.
@Suite("Seed user", .serialized, .enabled(if: AuthTestEnvironment.isAvailable))
struct SeedUserTests {
    /// Mirrors the command: hash outside the seed call, never inside it.
    /// `TestPasswordHasher` makes this cheap.
    private func seed(
        _ context: AuthTestContext,
        email: String,
        password: String,
        displayName: String? = nil,
        replaceExistingPassword: Bool = false
    ) async throws -> (user: User, replacedPassword: Bool) {
        try await context.service.seedVerifiedPasswordUser(
            email: email,
            passwordHash: try await context.factory.hasher.hash(password),
            displayName: displayName,
            replaceExistingPassword: replaceExistingPassword
        )
    }

    private func login(
        _ context: AuthTestContext,
        email: String,
        password: String,
        expect status: HTTPStatus
    ) async throws -> TokenResponse? {
        var decoded: TokenResponse?

        try await context.app.testing().test(
            .POST,
            "auth/login",
            beforeRequest: { request in
                try request.content.encode(LoginRequest(email: email, password: password))
            },
            afterResponse: { response async throws in
                #expect(response.status == status)
                if response.status == .ok {
                    decoded = try response.content.decode(TokenResponse.self)
                }
            }
        )

        return decoded
    }

    // MARK: - The point of the command

    @Test("A seeded account signs in immediately, with no code and no email")
    func seededUserCanLogInImmediately() async throws {
        try await withAuthApp { context in
            let email = "review@example.com"
            let password = "correct-horse-battery"

            let result = try await seed(
                context,
                email: email,
                password: password,
                displayName: "App Review"
            )

            #expect(result.replacedPassword == false)
            // The whole point: active, so `login`'s status guard does not
            // divert to `emailNotVerified`.
            #expect(result.user.status == .active)
            #expect(result.user.email == email)
            #expect(result.user.displayName == "App Review")

            // And the address is marked proved on the identity, which is what
            // makes it safe for `User.email` to hold it.
            let identity = try #require(
                try await context.service.linker.identity(provider: .password, subject: email)
            )
            #expect(identity.emailVerified)

            // Nothing was emailed. No OTP was involved at any point.
            #expect(await context.mailer.latestCode(for: email, purpose: .signup) == nil)

            let body = try #require(try await login(context, email: email, password: password, expect: .ok))
            #expect(body.user.email == email)
            #expect(body.user.providers == [AuthProvider.password.rawValue])
        }
    }

    @Test("Seeding normalizes the address, so a mixed-case run is the same account")
    func seedingNormalizesTheAddress() async throws {
        try await withAuthApp { context in
            let password = "correct-horse-battery"

            let first = try await seed(context, email: "Review@Example.com  ", password: password)
            #expect(first.user.email == "review@example.com")

            // Second run sees the same account, so it needs the explicit opt-in.
            await #expect(throws: SeedUserError.self) {
                _ = try await seed(context, email: "review@example.com", password: password)
            }

            #expect(try await User.query(on: context.app.db).count() == 1)
        }
    }

    // MARK: - Not taking a working login away from anyone

    @Test("Seeding refuses an account that already has a password")
    func seedingRefusesAnExistingPasswordAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            let original = "correct-horse"

            try await context.service.register(email: email, password: original, displayName: nil)
            _ = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            await #expect(throws: SeedUserError.self) {
                _ = try await seed(context, email: email, password: "something-else")
            }

            // The refusal left the account exactly as it was - this is the
            // mistyped-address case, and it must cost the real owner nothing.
            _ = try await login(context, email: email, password: original, expect: .ok)
            _ = try await login(context, email: email, password: "something-else", expect: .unauthorized)
        }
    }

    @Test("Replacing a password signs every device out")
    func resetPasswordReplacesAndSignsOutEveryDevice() async throws {
        try await withAuthApp { context in
            let email = "review@example.com"
            let first = "correct-horse-battery"
            let second = "a-different-password"

            _ = try await seed(context, email: email, password: first)
            let session = try #require(try await login(context, email: email, password: first, expect: .ok))

            let result = try await seed(
                context,
                email: email,
                password: second,
                replaceExistingPassword: true
            )
            #expect(result.replacedPassword)

            _ = try await login(context, email: email, password: first, expect: .unauthorized)
            _ = try await login(context, email: email, password: second, expect: .ok)

            // Same contract as `resetPassword`: a password that changed must
            // not leave a live session behind it.
            try await context.app.testing().test(
                .POST,
                "auth/refresh",
                beforeRequest: { request in
                    try request.content.encode(RefreshRequest(refreshToken: session.refreshToken))
                },
                afterResponse: { response async in
                    #expect(response.status == .unauthorized)
                }
            )
        }
    }

    // MARK: - The states an address can already be in

    @Test("Seeding finishes a sign-up that is still waiting on its code")
    func seedingFinishesAPendingSignup() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"

            // A placeholder: email NULL, status pendingVerification. It grants
            // nothing, which is why seeding over it needs no opt-in.
            try await context.service.register(email: email, password: "never-used", displayName: "Nino")
            _ = try await login(context, email: email, password: "never-used", expect: .forbidden)

            let seeded = "correct-horse-battery"
            let result = try await seed(context, email: email, password: seeded)

            #expect(result.replacedPassword == false)
            #expect(result.user.status == .active)
            #expect(result.user.email == email)
            // The placeholder's display name survives rather than being cleared.
            #expect(result.user.displayName == "Nino")

            _ = try await login(context, email: email, password: seeded, expect: .ok)
            #expect(try await User.query(on: context.app.db).count() == 1)
        }
    }

    @Test("Seeding adds a password to an Apple-only account instead of forking it")
    func seedingAttachesAPasswordToAnAppleOnlyAccount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"

            let token = try await context.appleToken(subject: "apple-sub-1", email: email)
            let (_, appleUser) = try await context.service.signIn(
                with: context.factory.appleVerifier(displayName: "Nino"),
                token: token,
                nonce: nil
            )
            let appleUserID = try appleUser.requireID()

            // Active but with no password, so this is an addition rather than a
            // replacement: no opt-in needed, and nothing is taken away.
            let password = "correct-horse-battery"
            let result = try await seed(context, email: email, password: password)

            #expect(result.replacedPassword == false)
            // The same account, not a second one. This is the invariant
            // `AccountLinker` exists to keep.
            #expect(try result.user.requireID() == appleUserID)
            #expect(try await User.query(on: context.app.db).count() == 1)
            #expect(try await context.service.providers(for: result.user) == [.apple, .password])

            let body = try #require(try await login(context, email: email, password: password, expect: .ok))
            #expect(body.user.id == appleUserID)
        }
    }

    // MARK: - Password material

    @Test("Generated passwords are unguessable and satisfy the server's own rule")
    func generatedPasswordsAreUsable() async throws {
        let generated = (0..<64).map { _ in SeedUserCommand.generatePassword() }

        // 24 random bytes as unpadded base64url.
        #expect(generated.allSatisfy { $0.count == 32 })
        // Inside the 8...256 range `/auth/register` and `/auth/password/reset`
        // enforce, so a seeded password is one the app would also accept.
        #expect(generated.allSatisfy { (8...256).contains($0.count) })
        // base64url only: no quoting needed in a shell, no ambiguity on an
        // iOS keyboard.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(generated.allSatisfy { $0.allSatisfy(allowed.contains) })
        // 192 bits of entropy: a collision here means the CSPRNG is broken.
        #expect(Set(generated).count == generated.count)
    }
}
