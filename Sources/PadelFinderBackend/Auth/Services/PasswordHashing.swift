import Vapor

/// Hashing behind a protocol so tests can swap in something cheap.
///
/// Bcrypt at cost 12 is roughly a quarter-second per call by design. That is
/// correct for production and ruinous for a test suite that signs up dozens of
/// users, so `AuthTests` injects a fast hasher and the cost stays where the
/// documents require it in the live path.
protocol PasswordHashing: Sendable {
    func hash(_ password: String) async throws -> String
    func verify(_ password: String, created digest: String) async throws -> Bool
}

/// Bcrypt at cost 12 or higher, per ARCHITECTURE.md section 4.
///
/// Runs on Vapor's thread pool rather than an event loop: Bcrypt is deliberately
/// slow, and 250ms of blocking on an event loop would stall every other request
/// sharing it.
struct BcryptPasswordHasher: PasswordHashing {
    let hasher: AsyncPasswordHasher

    func hash(_ password: String) async throws -> String {
        try await hasher.hash(password).get()
    }

    func verify(_ password: String, created digest: String) async throws -> Bool {
        try await hasher.verify(password, created: digest).get()
    }
}
