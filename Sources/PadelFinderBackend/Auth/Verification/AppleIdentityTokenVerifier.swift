import JWT
import Vapor

/// Verifies a Sign in with Apple identity token.
///
/// `AppleIdentityToken.verify` already checks the issuer and expiry; what is
/// left is ours: the audience must be one of our client ids, and the nonce must
/// match the one the client used.
struct AppleIdentityTokenVerifier: IdentityTokenVerifier {
    static let jwksEndpoint: URI = "https://appleid.apple.com/auth/keys"

    let provider: AuthProvider = .apple
    let jwks: any JWKSProviding
    /// Our `client_id`s: the iOS bundle id, plus a Services ID if we ever add
    /// a web flow.
    let allowedClientIDs: [String]
    /// Passed through to the account linker for display. Apple puts the name in
    /// the native authorization result, not in the token.
    let displayName: String?

    func verify(_ token: String, expectedNonce: String?) async throws -> IdentityClaim {
        guard !allowedClientIDs.isEmpty else {
            throw IdentityVerificationError.notConfigured(.apple)
        }

        let keys = try await jwks.keys()
        let payload = try await keys.verify(token, as: AppleIdentityToken.self)

        guard allowedClientIDs.contains(where: payload.audience.value.contains) else {
            throw IdentityVerificationError.audienceMismatch
        }

        // `nonce_supported` false means an older platform that did not echo the
        // nonce back, and Apple's own guidance is to treat it as optional there.
        // Anywhere else a missing or different nonce is a replay.
        if let expectedNonce {
            let nonceSupported = payload.nonceSupported?.value ?? true
            if nonceSupported || payload.nonce != nil {
                guard payload.nonce == expectedNonce else {
                    throw IdentityVerificationError.nonceMismatch
                }
            }
        }

        // Apple only ever returns addresses it has verified, so an address in
        // the token is proved. It may be an `@privaterelay.appleid.com` relay
        // address, which is a perfectly good proved email and must not be
        // treated as second class.
        //
        // The email is absent on sign-ins after the first. That is fine: the
        // subject identifies the account, and `AccountLinker` never overwrites
        // a stored address with nil.
        let email = payload.email?.normalizedEmail
        let emailIsProved = email != nil && (payload.emailVerified?.value ?? true)

        return IdentityClaim(
            provider: .apple,
            subject: payload.subject.value,
            email: email,
            emailIsProved: emailIsProved,
            displayName: displayName
        )
    }
}
