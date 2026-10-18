import Fluent
import Vapor

/// Authenticates a request from its `Authorization: Bearer <access token>`
/// header.
///
/// Note what this does **not** do: check whether the session was revoked. An
/// access token is valid for its whole 15 minutes no matter what happens
/// in between, because checking would mean a database round trip on every
/// request to every endpoint. Revocation lives on the refresh token, and the
/// short lifetime is what bounds the gap - see ARCHITECTURE.md section 4.
///
/// The one place that is not good enough is account deletion, which also drops
/// the user row; the lookup below then fails and the token stops working at
/// once.
struct AccessTokenAuthenticator: AsyncBearerAuthenticator {
    let factory: AuthControllerFactory

    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let payload: AccessTokenPayload

        do {
            payload = try await factory.tokens(on: request.db).verifyAccessToken(bearer.token)
        } catch {
            // Left unauthenticated rather than thrown, so a route that allows
            // anonymous callers still works with a stale token in the header.
            // `guardMiddleware` turns the absence into a 401 where it matters.
            return
        }

        guard let userID = payload.userID,
              let user = try await User.find(userID, on: request.db),
              user.status == .active
        else {
            return
        }

        request.auth.login(user)
    }
}

extension User {
    /// 401 with our error shape rather than Vapor's bare one, so the client can
    /// branch on `invalid_token` like every other auth failure.
    static func requireAuthenticated(_ request: Request) throws -> User {
        guard let user = request.auth.get(User.self) else {
            throw AuthAbort.invalidToken
        }

        return user
    }
}
