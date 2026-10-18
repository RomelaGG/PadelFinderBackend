@testable import PadelFinderBackend
import Fluent
import Foundation
import Testing
import Vapor

/// The races, exercised against a real Postgres.
///
/// These are the tests the design is for. Each guarantee here is a database
/// statement - an `UPDATE ... WHERE`, a unique index - not an application
/// check, so testing them against anything but Postgres would prove nothing.
///
/// Driven at the service layer rather than over HTTP on purpose: the guard is
/// in the database, and going through the router would add scheduling noise
/// without testing anything extra.
@Suite("Auth races", .serialized, .enabled(if: AuthTestEnvironment.isAvailable))
struct AuthConcurrencyTests {
    /// P-04: "submitting it twice at the same instant must succeed only once."
    ///
    /// The guard is `UPDATE email_otps SET consumed_at = now() WHERE id = $1
    /// AND consumed_at IS NULL` - the database picks the winner, so there is no
    /// window between checking and claiming for a second request to slip into.
    @Test("The same code submitted many times at once is spent exactly once")
    func concurrentCodeSubmissionsSucceedOnce() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let code = try await context.code(for: email)

            let outcomes = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        do {
                            _ = try await context.service.verifySignup(email: email, code: code)
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                var results: [Bool] = []
                for try await outcome in group {
                    results.append(outcome)
                }
                return results
            }

            #expect(outcomes.filter { $0 }.count == 1)

            // And one account, not twelve.
            #expect(try await User.query(on: context.app.db).count() == 1)
        }
    }

    /// P-06, from the other side.
    ///
    /// Several parallel refreshes with one token: exactly one rotation
    /// succeeds. The rest are reuse, which costs the family - which is why the
    /// iOS `TokenStore` actor allows exactly one refresh in flight
    /// (SYSTEM-DESIGN-DIAGRAMS.md section 4). This test documents the strict
    /// server behaviour that single-flight exists to avoid tripping.
    @Test("Parallel refreshes with one token rotate exactly once")
    func concurrentRefreshesRotateOnce() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let (pair, _) = try await context.service.verifySignup(
                email: email,
                code: try await context.code(for: email)
            )

            let succeeded = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            _ = try await context.tokens.rotate(refreshToken: pair.refreshToken)
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                var count = 0
                for try await outcome in group where outcome {
                    count += 1
                }
                return count
            }

            #expect(succeeded == 1)
        }
    }

    /// Five wrong guesses in parallel must count as five, not as one.
    ///
    /// `attempt_count = attempt_count + 1` in SQL rather than read-modify-write
    /// in Swift, so two simultaneous wrong guesses cannot both read 3 and both
    /// write 4 - which would turn the ceiling into something you can walk
    /// straight through with enough concurrency.
    @Test("Parallel wrong guesses all count against the ceiling")
    func concurrentWrongGuessesAllCount() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"
            try await context.service.register(email: email, password: "correct-horse", displayName: nil)
            let realCode = try await context.code(for: email)
            let wrongCode = realCode == "000000" ? "111111" : "000000"

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        _ = try? await context.service.verifySignup(email: email, code: wrongCode)
                    }
                }
            }

            let record = try #require(try await EmailOTP.query(on: context.app.db).first())
            #expect(record.attemptCount == 5)

            // Burned, so the real code is worthless too.
            await #expect(throws: OTPError.noLiveCode) {
                try await context.service.verifySignup(email: email, code: realCode)
            }
        }
    }

    /// The unique index on `(provider, subject)` is what makes "one Apple
    /// account signs in to one of ours" true rather than hoped for.
    @Test("Simultaneous first sign-ins for one Google account make one user")
    func concurrentSocialSignInsMakeOneAccount() async throws {
        try await withAuthApp { context in
            let token = try await context.googleToken(
                subject: "google-sub-1",
                email: "player@example.com"
            )

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<6 {
                    group.addTask {
                        _ = try? await context.service.signIn(
                            with: context.factory.googleVerifier,
                            token: token,
                            nonce: nil
                        )
                    }
                }
            }

            // At least one got in, and the index stopped the rest from
            // duplicating the identity.
            #expect(try await UserIdentity.query(on: context.app.db).count() == 1)
            #expect(try await User.query(on: context.app.db).count() == 1)
        }
    }

    /// The race the old rate limiter lost.
    ///
    /// It counted rows and then inserted one, so twelve parallel requests all
    /// read four and all inserted: the cap of five became "five plus however
    /// many you can send at once". The fix is the same shape as every other
    /// guard here - one `INSERT ... ON CONFLICT DO UPDATE ... WHERE count <
    /// limit`, where Postgres takes a row lock and the losers get nothing back.
    @Test("Parallel code requests cannot exceed the per-address cap")
    func concurrentCodeRequestsRespectTheCap() async throws {
        try await withAuthApp { context in
            let email = "victim@example.com"

            let sent = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        do {
                            try await context.service.otps.issueForTesting(to: email, purpose: .signup)
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                var count = 0
                for try await outcome in group where outcome {
                    count += 1
                }
                return count
            }

            // Exactly the cap. Not "about the cap".
            #expect(sent == 5)
            #expect(await context.mailer.count(for: email) == 5)
        }
    }

    /// The same race on the per-IP counter, which is what stands between an
    /// unauthenticated endpoint and the whole daily email quota.
    @Test("Parallel requests from one IP cannot exceed the per-IP cap")
    func concurrentRequestsRespectTheIPCap() async throws {
        try await withAuthApp { context in
            let attacker = "198.51.100.10"

            let sent = try await withThrowingTaskGroup(of: Bool.self) { group in
                for index in 0..<40 {
                    group.addTask {
                        do {
                            try await context.service.register(
                                email: "spam-\(index)@example.com",
                                password: "correct-horse",
                                displayName: nil,
                                clientIP: attacker
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                var count = 0
                for try await outcome in group where outcome {
                    count += 1
                }
                return count
            }

            #expect(sent == 20)
            #expect(await context.mailer.all().count == 20)
        }
    }

    /// Two people registering the same address at the same moment.
    ///
    /// Only one placeholder may exist, because `(provider, subject)` is unique
    /// and the subject for a password identity is the address. Neither of them
    /// gets an account out of it - that still waits on the code.
    @Test("Simultaneous registrations for one address make one placeholder")
    func concurrentRegistrationsMakeOnePlaceholder() async throws {
        try await withAuthApp { context in
            let email = "player@example.com"

            // Every one of these must answer cleanly. The unique index refuses
            // all but the first insert, and a constraint violation here is a
            // normal outcome - somebody tapped "Sign up" twice - not a fault to
            // report as a 500.
            let failures = await withTaskGroup(of: Bool.self) { group in
                for index in 0..<5 {
                    group.addTask {
                        do {
                            try await context.service.register(
                                email: email,
                                password: "password-\(index)",
                                displayName: nil
                            )
                            return false
                        } catch {
                            return true
                        }
                    }
                }

                var count = 0
                for await failed in group where failed {
                    count += 1
                }
                return count
            }

            #expect(failures == 0)

            let identities = try await UserIdentity.query(on: context.app.db)
                .filter(\.$provider == .password)
                .all()
            #expect(identities.count == 1)

            // And no orphan user rows from the losing inserts.
            #expect(try await User.query(on: context.app.db).count() == 1)
            #expect(try await UserCredential.query(on: context.app.db).count() == 1)

            let users = try await User.query(on: context.app.db).all()
            #expect(users.allSatisfy { $0.status == .pendingVerification })
            #expect(users.allSatisfy { $0.email == nil })
        }
    }
}
