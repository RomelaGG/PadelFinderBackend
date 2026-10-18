import Vapor

extension Request {
    /// The caller's IP address, for rate limiting.
    ///
    /// Only reads a forwarding header when one has been **explicitly named** in
    /// the configuration. Any client can send `X-Forwarded-For: 1.2.3.4`, so
    /// trusting such a header by default would turn the per-IP cap into a
    /// decoration - an attacker sends a different value each request and has no
    /// limit at all.
    ///
    /// On Fly, set `TRUSTED_CLIENT_IP_HEADER=Fly-Client-IP`: Fly's proxy sets
    /// that header itself from the real connection, so it cannot be forged from
    /// outside. Unset - running without a proxy - the peer address of the
    /// connection is the truth and is used instead.
    func clientIPForRateLimiting(trustedHeader: String?) -> String? {
        if let trustedHeader, let value = headers.first(name: trustedHeader) {
            // A proxy may append rather than replace. The first entry is the
            // one the trusted proxy observed.
            let first = value
                .split(separator: ",")
                .first?
                .trimmingCharacters(in: .whitespaces)

            if let first, !first.isEmpty {
                return first
            }
        }

        // `remoteAddress`, deliberately - NOT Vapor's `peerAddress`.
        //
        // `peerAddress` returns the value of `Forwarded` or `X-Forwarded-For`
        // when either is present, falling back to the socket. That is a
        // reasonable convenience for logging and completely wrong here: any
        // client can send those headers, so using it would let an attacker
        // rotate the header per request and never meet the cap. A test asserts
        // this exact distinction.
        //
        // Behind an unconfigured proxy this is the proxy's own address, which
        // makes the per-IP cap apply to everyone at once. That fails closed
        // rather than open, and `configureAuth` warns about it at startup.
        return remoteAddress?.ipAddress
    }
}
