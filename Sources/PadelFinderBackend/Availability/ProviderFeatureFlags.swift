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
    static let kustbaPadel = true
    static let padelGldani = true
    static let padelHub = true
    static let gymBreeze = true
}
