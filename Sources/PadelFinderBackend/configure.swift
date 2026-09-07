import NIOConcurrencyHelpers
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

struct KustbaAvailabilityStoreKey: StorageKey {
    typealias Value = KustbaAvailabilityStore
}

extension Application {
    /// Shared warm cache for Kus Tba availability, written by the background
    /// refresher and read by the request path.
    var kustbaAvailabilityStore: KustbaAvailabilityStore {
        if let existing = storage[KustbaAvailabilityStoreKey.self] {
            return existing
        }

        let store = KustbaAvailabilityStore()
        storage[KustbaAvailabilityStoreKey.self] = store

        return store
    }
}

/// Owns the background refresh task, tying its lifetime to the application's.
final class KustbaRefreshLifecycleHandler: LifecycleHandler {
    private let service: KustbaRefreshService
    private let task: NIOLockedValueBox<Task<Void, Never>?>

    init(service: KustbaRefreshService) {
        self.service = service
        self.task = NIOLockedValueBox(nil)
    }

    func didBootAsync(_ application: Application) async throws {
        let service = self.service
        let logger = application.logger

        task.withLockedValue { existing in
            existing?.cancel()
            existing = Task { await service.run(logger: logger) }
        }
    }

    func shutdownAsync(_ application: Application) async {
        task.withLockedValue { existing in
            existing?.cancel()
            existing = nil
        }
    }
}

// configures your application
public func configure(_ app: Application) async throws {
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    if let baseURL = Environment.get("PUBLIC_BASE_URL") {
        app.publicBaseURL = baseURL
    }

    // Keep Kus Tba warm in the background. It answers in 13-24s, against under
    // 2.5s for every other provider, so fetching it on the request path made it
    // the sole driver of `/availability` latency. Days near today refresh often;
    // days further out refresh slowly, to keep the load on their site low.
    let kustbaStore = app.kustbaAvailabilityStore
    let refreshService = KustbaRefreshService(
        provider: KustbaPadelProvider(client: app.client),
        store: kustbaStore,
        configuration: .fromEnvironment()
    )
    app.lifecycle.use(KustbaRefreshLifecycleHandler(service: refreshService))

    // register routes
    try routes(app)
}
