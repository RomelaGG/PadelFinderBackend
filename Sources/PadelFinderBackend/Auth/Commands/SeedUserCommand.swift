import Fluent
import Foundation
import Vapor

/// Creates an email-verified account with a generated password, without an
/// emailed code.
///
/// Exists because there is otherwise no way to get a usable account on a
/// deployed environment. `/auth/register` only ever writes a placeholder, and
/// `AuthService.login` refuses anything that is not `.active`, so a real
/// account needs the 6-digit code - and in production those go out through
/// Resend's test sender, which only delivers to the one address the Resend
/// account was registered with.
///
/// Deliberately a command and not a route, and there must never be a route.
/// This asserts that an address is proved because an operator said so, which is
/// only safe because reaching the code at all requires shell access to the
/// machine. Behind an HTTP handler, however well guarded, it would be an
/// account-takeover primitive.
///
/// There is deliberately no `--password` option: on production a password in
/// argv would be left in shell history and in Fly's audit trail. One is
/// generated and printed once, to the console only - never through
/// `app.logger`, which ships to Fly's shared log stream.
struct SeedUserCommand: AsyncCommand {
    struct Signature: CommandSignature {
        /// No `short:` form. `-e` is already taken by Vapor's `--env`, which is
        /// parsed out of argv by `Environment.detect` before a `CommandContext`
        /// exists.
        @Option(name: "email", help: "Address to seed. Required.")
        var email: String?

        @Option(
            name: "display-name",
            help: "Optional. Only applied when the account has no display name yet."
        )
        var displayName: String?

        @Flag(
            name: "reset-password",
            help: """
            Allow replacing the password of an account that already has one. \
            Revokes every live session, exactly as a password reset does.
            """
        )
        var resetPassword: Bool

        init() {}
    }

    /// Injected rather than read from `app.authFactory`, matching
    /// `AuthController(factory:)`: the dependency is visible at the
    /// registration site instead of being a storage lookup that `fatalError`s
    /// if auth was not configured first.
    let factory: AuthControllerFactory

    var help: String {
        """
        Create an email-verified account with a password, bypassing the signup code.

        The password is generated and printed once; it is never taken as an \
        argument, because on production that would leave it in shell history and \
        in the Fly audit trail.

        Confirms before writing. Pass --yes (ConsoleKit's global flag, as with \
        `migrate --yes`) to skip the prompt in a non-interactive shell.
        """
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        // `entrypoint.swift` reports a thrown error and rethrows it, which the
        // Swift runtime renders as "Fatal error: Error raised at top level".
        // That is right for a crash and wrong for a refusal, so the guidance is
        // printed here, once and legibly, and the rethrown error stays terse
        // enough that the runtime's trailing line is not a second wall of text.
        // The throw is kept: it is what makes the exit code non-zero.
        do {
            try await seed(using: context, signature: signature)
        } catch let error as SeedUserError {
            context.console.error("seed-user: \(error.message)")
            throw error
        }
    }

    private func seed(using context: CommandContext, signature: Signature) async throws {
        let console = context.console
        let app = context.application

        guard let rawEmail = signature.email else {
            throw SeedUserError.missingEmail
        }

        let email = rawEmail.normalizedEmail

        // The same rule `/auth/login` applies (`LoginRequest.validations`).
        // A weaker check here could seed an address that the login endpoint
        // then rejects at the door - an account that exists and can never be
        // signed into.
        guard !Validator<String>.email.validate(email).isFailure else {
            throw SeedUserError.invalidEmail(rawEmail)
        }

        let database = app.db
        let linker = AccountLinker(database: database)

        // A pre-flight read, so the prompt can say what is about to happen.
        // The authoritative check is in `seedVerifiedPasswordUser`, which is
        // where it belongs: a guard that only exists in the UI layer is a
        // guard that the next caller skips.
        let existing = try await Self.classify(email: email, linker: linker, on: database)

        switch existing {
        case .absent:
            console.info("Creating a new verified account for \(email).")
        case .pendingSignup:
            console.info("A pending sign-up for \(email) exists; completing it as verified.")
        case .activeWithoutPassword:
            console.info("An active account for \(email) has no password yet; adding one.")
        case .activeWithPassword:
            guard signature.resetPassword else {
                throw SeedUserError.accountExists(email)
            }
            console.warning(
                "\(email) already has a password. Replacing it signs out every live session."
            )
        }

        guard try Self.confirmed(
            "Seed \(email) on \(app.environment.name)?",
            using: console
        ) else {
            console.warning("Cancelled. Nothing was changed.")
            return
        }

        let password = Self.generatePassword()

        // Hashed here, never inside the linker's transaction: Bcrypt at cost 12
        // is about a quarter of a second, and holding a pooled connection that
        // long is how the pool runs dry. Same reasoning as `AuthService.register`.
        let passwordHash = try await factory.hasher.hash(password)

        let service = factory.service(on: database)
        let result = try await service.seedVerifiedPasswordUser(
            email: email,
            passwordHash: passwordHash,
            displayName: signature.displayName,
            replaceExistingPassword: signature.resetPassword
        )

        let userID = try result.user.requireID()

        // The domain only, never the address or the password: these lines go to
        // Fly's shared log stream, which is precisely where `AuthConfiguration`
        // argues credentials must not land.
        app.logger.notice(
            "Seeded user",
            metadata: [
                "userID": .stringConvertible(userID),
                "emailDomain": .string(email.emailDomainForLogging),
                "replacedPassword": .stringConvertible(result.replacedPassword)
            ]
        )

        console.success(result.replacedPassword ? "Password replaced." : "Account ready.")
        console.print("  id:      \(userID.uuidString)")
        console.print("  email:   \(result.user.email ?? email)")
        console.print("  name:    \(result.user.displayName ?? "-")")
        console.print("  status:  \(result.user.status.rawValue)")
        console.print("")
        console.info("Password - shown once, not stored, not recoverable:")
        console.print("")
        console.print("      \(password)")
        console.print("")
        console.warning("Store it now. Re-run with --reset-password to issue a new one.")
    }

    // MARK: - Pre-flight classification

    enum ExistingAccount {
        case absent
        /// A placeholder from `/auth/register`, still waiting on its code.
        /// Overwriting its password is safe for the reason
        /// `AuthService.adoptExistingSignup` gives: a placeholder grants nothing.
        case pendingSignup
        /// Active via Apple or Google, with no password yet.
        case activeWithoutPassword
        case activeWithPassword
    }

    static func classify(
        email: String,
        linker: AccountLinker,
        on database: any Database
    ) async throws -> ExistingAccount {
        let signup = try await linker.userForPasswordIdentity(email: email)
        let holder = try await linker.activeUser(withProvedEmail: email)

        // The account that will actually be written. When both exist and
        // differ, `AccountLinker.proveEmail` merges the placeholder into the
        // holder and returns the *holder* - so the holder's credential is the
        // one at risk, and asking about the placeholder's would answer the
        // wrong question.
        guard let target = holder ?? signup?.user else {
            return .absent
        }

        guard target.status == .active else {
            return .pendingSignup
        }

        let hasPassword = try await UserCredential.query(on: database)
            .filter(\.$user.$id == target.requireID())
            .count() > 0

        return hasPassword ? .activeWithPassword : .activeWithoutPassword
    }

    // MARK: - Confirmation

    /// `console.confirm` reads stdin through `Terminal.input`, which calls
    /// `fatalError` on EOF. Under `fly ssh console -C "..."` there is no
    /// terminal, so prompting there would crash with a stack trace instead of
    /// saying what was missing. Check first and explain.
    static func confirmed(_ prompt: String, using console: any Console) throws -> Bool {
        if console.confirmOverride == nil, isatty(STDIN_FILENO) == 0 {
            throw SeedUserError.needsConfirmation
        }

        return console.confirm(prompt.consoleText(.warning))
    }

    // MARK: - Password material

    /// 24 bytes of randomness, base64url without padding: 192 bits in 32
    /// characters, comfortably inside the 8...256 range the register and reset
    /// endpoints enforce, and typable on an iOS keyboard.
    ///
    /// Same source and same spelling as `TokenService.generateRefreshToken`.
    /// `SystemRandomNumberGenerator` is the platform CSPRNG - `arc4random_buf`
    /// on Darwin, `getrandom(2)` on Linux - and is the only random source in
    /// this codebase allowed to produce a credential.
    static func generatePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        var generator = SystemRandomNumberGenerator()

        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }

        return Data(bytes).base64URLEncodedString()
    }
}

enum SeedUserError: Error, CustomStringConvertible {
    case missingEmail
    case invalidEmail(String)
    case accountExists(String)
    case needsConfirmation

    /// What the operator needs to read, printed by the command.
    var message: String {
        switch self {
        case .missingEmail:
            return """
            missing --email. Usage:
              seed-user --email you@example.com [--display-name 'Name'] [--yes]
            """

        case .invalidEmail(let value):
            return "'\(value)' is not a valid email address, so it could never be signed in with."

        case .accountExists(let email):
            return """
            \(email) already has an account with a password, and seeding would \
            replace it. Re-run with --reset-password if that is what you want - \
            note that it revokes every live session, exactly as a password reset does.
            """

        case .needsConfirmation:
            return """
            not running on a terminal, so there is nothing to confirm against. \
            Pass --yes to proceed non-interactively.
            """
        }
    }

    /// Deliberately terse. This is what the runtime echoes after the command
    /// has already printed `message`, so repeating the guidance here would
    /// print it three times over.
    var description: String {
        switch self {
        case .missingEmail: return "seed-user: missing --email"
        case .invalidEmail: return "seed-user: invalid email"
        case .accountExists: return "seed-user: account already has a password"
        case .needsConfirmation: return "seed-user: needs --yes on a non-interactive shell"
        }
    }
}
