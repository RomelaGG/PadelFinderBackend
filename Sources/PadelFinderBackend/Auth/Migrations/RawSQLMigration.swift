import Fluent
import SQLKit

/// A migration written as SQL rather than through Fluent's schema builder.
///
/// Auth needs DDL Fluent cannot express: the `citext` extension, partial unique
/// indexes, and the guards in SYSTEM-DESIGN-DIAGRAMS.md section 7. Writing all
/// of it as SQL keeps the shipped schema readable next to the design document
/// instead of split between two styles. Later phases need the same thing - the
/// bookings exclusion constraint has no Fluent equivalent at all.
protocol RawSQLMigration: AsyncMigration {
    var upStatements: [String] { get }
    var downStatements: [String] { get }
}

enum RawSQLMigrationError: Error, CustomStringConvertible {
    case databaseIsNotSQL

    var description: String {
        switch self {
        case .databaseIsNotSQL:
            return "RawSQLMigration requires an SQL database"
        }
    }
}

extension RawSQLMigration {
    func prepare(on database: any Database) async throws {
        try await run(upStatements, on: database)
    }

    func revert(on database: any Database) async throws {
        try await run(downStatements, on: database)
    }

    private func run(_ statements: [String], on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw RawSQLMigrationError.databaseIsNotSQL
        }

        for statement in statements {
            try await sql.raw(SQLQueryString(statement)).run()
        }
    }
}
