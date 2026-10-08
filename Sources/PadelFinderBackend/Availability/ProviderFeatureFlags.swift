/// Hardcoded on/off switches for the availability providers.
///
/// Flip a flag to `false` and that provider is not registered at all: it stops
/// appearing in `/availability`, `/availability/company/:id` returns 404 for
/// it, and its background refresher (Kus Tba) does not start. These are
/// compile-time switches on purpose — a change needs a redeploy, and shows up
/// in the diff.
enum ProviderFeatureFlags {
    static let tbilisiPadel = true
    static let padelIsland = true
    static let lemansPadel = true
    // Off temporarily: the background refresher ran 24/7 regardless of traffic,
    // about 950 requests an hour at their WordPress site (19 per date, 50 date
    // refreshes an hour). Turn back on once the request rate is deliberate -
    // a slower far tier, a concurrency cap, and a User-Agent that identifies us.
    // Kus Tba disappears from /availability entirely while this is false.
    static let kustbaPadel = false
    static let padelGldani = true
    static let padelHub = true
    static let gymBreeze = true
}
