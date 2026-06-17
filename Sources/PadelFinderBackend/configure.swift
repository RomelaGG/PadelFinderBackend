import Vapor

/// Base URL of this API, used to turn relative asset paths (e.g. `/logos/x.png`)
/// into absolute URLs in responses. Configured once at startup.
struct PublicBaseURLKey: StorageKey {
    typealias Value = String
}

extension Application {
    var publicBaseURL: String {
        get { storage[PublicBaseURLKey.self] ?? "http://127.0.0.1:8080" }
        set { storage[PublicBaseURLKey.self] = newValue }
    }
}

// configures your application
public func configure(_ app: Application) async throws {
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    if let baseURL = Environment.get("PUBLIC_BASE_URL") {
        app.publicBaseURL = baseURL
    }

    // register routes
    try routes(app)
}
