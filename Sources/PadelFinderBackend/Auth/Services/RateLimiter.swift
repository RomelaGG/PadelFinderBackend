import Fluent
import Foundation
import SQLKit
import Vapor

/// A fixed-window counter that the database increments atomically.
///
/// The previous version of this counted rows and then inserted one, which is a
/// check-then-act race: two requests both read four, both insert, and the cap
/// of five becomes "five plus however many you can send at once". The same
/// philosophy that fixes the OTP single-use guard fixes this - let the database
/// decide, in one statement, instead of an `if` in Swift.
///
/// The statement is an upsert whose `DO UPDATE` carries the limit in its
/// `WHERE`. Postgres takes a row lock for the conflicting insert, so concurrent
/// callers serialize on that one row; when the count has reached the limit the
/// update matches nothing and no row comes back.
///
/// Counted in Postgres rather than in memory, which is already correct across
/// instances - so this does not have to move when we scale past one machine.
/// Redis would be faster and is where the architecture eventually puts rate
/// limits, but "faster" is not the problem being solved here.
struct RateLimiter: Sendable {
    /// Why a request was refused. Separated so a log line can say which cap
    /// tripped, which is the difference between "someone is attacking us" and
    /// "one user is confused".
    enum Bucket: Sendable {
        case email(String)
        case clientIP(String)

        var key: String {
            switch self {
            case .email(let email):
                return "otp:email:\(email)"
            case .clientIP(let ip):
                return "otp:ip:\(ip)"
            }
        }

        var label: String {
            switch self {
            case .email:
                return "email"
            case .clientIP:
                return "ip"
            }
        }
    }

    let database: any Database
    let now: @Sendable () -> Date

    /// Takes one unit from `bucket`, or returns false if it is empty.
    ///
    /// - Note: a *fixed* window, not a sliding one. It resets on the hour, so
    ///   somebody can send the cap at 10:59 and the cap again at 11:00. That is
    ///   the normal trade-off for a counter this cheap, and twice the cap once
    ///   an hour is not the attack worth preventing - the unbounded version was.
    func claim(_ bucket: Bucket, limit: Int, window: TimeInterval) async throws -> Bool {
        guard limit > 0 else {
            return false
        }

        guard let sql = database as? any SQLDatabase else {
            throw RawSQLMigrationError.databaseIsNotSQL
        }

        let windowStart = Self.windowStart(for: now(), window: window)

        let claimed = try await sql.raw("""
            INSERT INTO rate_limits (bucket, window_start, count)
            VALUES (\(bind: bucket.key), \(bind: windowStart), 1)
            ON CONFLICT (bucket, window_start)
            DO UPDATE SET count = rate_limits.count + 1
                    WHERE rate_limits.count < \(bind: limit)
            RETURNING count
            """).first()

        guard let claimed else {
            return false
        }

        // `count == 1` means this statement created the window row, which
        // happens at most once per bucket per window. A good moment to drop
        // windows nobody will read again, without adding a write to every
        // request or a background job to own it.
        if try claimed.decode(column: "count", as: Int.self) == 1 {
            try await pruneExpiredWindows(before: windowStart.addingTimeInterval(-window), on: sql)
        }

        return true
    }

    private func pruneExpiredWindows(before cutoff: Date, on sql: any SQLDatabase) async throws {
        try await sql.raw("DELETE FROM rate_limits WHERE window_start < \(bind: cutoff)").run()
    }

    /// Floors `date` to the start of its window, so every caller in the same
    /// window agrees on which row to increment.
    static func windowStart(for date: Date, window: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / window).rounded(.down) * window)
    }
}
