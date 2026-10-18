import Fluent
import FluentPostgresDriver
import Vapor

/// Where the database lives, and why the rule differs by environment.
enum DatabaseConfiguration {
    /// Matches the `db` service in `docker-compose.yml`, so a fresh checkout
    /// needs `docker compose up -d db` and nothing else.
    static let developmentURL = "postgres://padelfinder:padelfinder@localhost:5432/padelfinder"

    static func url(for environment: Environment) throws -> String {
        if let configured = Environment.get("DATABASE_URL"), !configured.isEmpty {
            return configured
        }

        // Falling back to localhost in production would mean a deploy that
        // boots, passes /health, and then fails every sign-in. Refuse instead.
        guard environment != .production else {
            throw AuthConfigurationError.missingRequiredValue("DATABASE_URL")
        }

        return developmentURL
    }
}

/// Registers the database and the migration list.
///
/// Deliberately does **not** run migrations. They run as the `migrate` command,
/// wired to Fly's `release_command`, so a failed migration fails the deploy
/// instead of leaving a half-migrated database serving traffic
/// (BUILD-PLAN.md section 4).
///
/// Fluent connects lazily, which is what lets the existing availability tests
/// keep running with no Postgres anywhere: registering a database costs nothing
/// until something queries it.
func configureDatabase(_ app: Application) throws {
    let url = try DatabaseConfiguration.url(for: app.environment)
    let configuration = try SQLPostgresConfiguration(url: url)

    app.databases.use(.postgres(configuration: configuration), as: .psql)
    app.migrations.add(AuthMigrations.all)

    app.logger.notice(
        "Database registered",
        metadata: ["migrations": .stringConvertible(AuthMigrations.all.count)]
    )
}
