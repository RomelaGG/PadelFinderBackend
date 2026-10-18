import JWT
import Vapor

/// Verifies a Google ID token.
///
/// `GoogleIdentityToken.verify` checks the issuer, subject length and expiry.
/// The audience check is ours because iOS and web clients have different client
/// ids and both are legitimate.
struct GoogleIdentityTokenVerifier: IdentityTokenVerifier {
    static let jwksEndpoint: URI = "https://www.googleapis.com/oauth2/v3/certs"

    let provider: AuthProvider = .google
    let jwks: any JWKSProviding
    let allowedClientIDs: [String]

    func verify(_ token: String, expectedNonce: String?) async throws -> IdentityClaim {
        guard !allowedClientIDs.isEmpty else {
            throw IdentityVerificationError.notConfigured(.google)
        }

        let keys = try await jwks.keys()
        let payload = try await keys.verify(token, as: GoogleIdentityToken.self)

        guard allowedClientIDs.contains(where: payload.audience.value.contains) else {
            throw IdentityVerificationError.audienceMismatch
        }

        if let expectedNonce {
            guard payload.nonce == expectedNonce else {
                throw IdentityVerificationError.nonceMismatch
            }
        }

        // Unlike Apple, Google will hand back an address it has *not* verified,
        // and linking on one of those is exactly the hole P-07 exists to close.
        // So the flag is read, not assumed.
        guard let email = payload.email?.normalizedEmail else {
            throw IdentityVerificationError.emailMissing
        }
        guard payload.emailVerified?.value == true else {
            throw IdentityVerificationError.emailNotVerifiedByProvider
        }

        return IdentityClaim(
            provider: .google,
            subject: payload.subject.value,
            email: email,
            emailIsProved: true,
            displayName: payload.name
        )
    }
}
