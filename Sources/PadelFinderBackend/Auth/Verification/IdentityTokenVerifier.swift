import JWT
import Vapor

/// Turns a provider's identity token into a claim we can link an account on.
///
/// A protocol rather than calling vapor/jwt's `request.jwt.apple.verify()`
/// directly, for two reasons: real Apple and Google tokens cannot be minted in
/// a test, and we accept **several** audiences (the iOS bundle id and any web
/// client id are both legitimate) where the built-in helper checks one.
protocol IdentityTokenVerifier: Sendable {
    var provider: AuthProvider { get }

    /// - Parameter expectedNonce: the nonce the client sent with its
    ///   authorization request, if any. Checking it is what stops a token
    ///   captured from one sign-in being replayed into another.
    func verify(_ token: String, expectedNonce: String?) async throws -> IdentityClaim
}

/// Supplies the provider's current public keys.
///
/// Behind a protocol so tests can hand over a locally generated key set and
/// mint their own tokens against it - without that, the Apple and Google paths
/// could only ever be exercised by hand on a device.
protocol JWKSProviding: Sendable {
    func keys() async throws -> JWTKeyCollection
}

/// Fetches a provider's JWKS over HTTP.
///
/// Built on Vapor's `EndpointCache`, which honours `Cache-Control`, `Expires`
/// and `ETag`. Worth reusing rather than writing: fetching Apple's key set on
/// every sign-in would be both slow and rude, and caching it forever breaks
/// sign-in on the day they rotate a key.
struct RemoteJWKSProvider: JWKSProviding {
    let cache: EndpointCache<JWKS>
    let client: any Client
    let eventLoop: any EventLoop
    let logger: Logger

    init(endpoint: URI, client: any Client, eventLoop: any EventLoop, logger: Logger) {
        self.cache = EndpointCache<JWKS>(uri: endpoint)
        self.client = client
        self.eventLoop = eventLoop
        self.logger = logger
    }

    func keys() async throws -> JWTKeyCollection {
        let jwks = try await cache.get(using: client, logger: logger, on: eventLoop).get()
        return try await JWTKeyCollection().add(jwks: jwks)
    }
}

enum IdentityVerificationError: Error, Equatable {
    case notConfigured(AuthProvider)
    case audienceMismatch
    case nonceMismatch
    case emailMissing
    case emailNotVerifiedByProvider
}
