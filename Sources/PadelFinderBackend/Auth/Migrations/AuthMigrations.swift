import Fluent

/// Every auth migration, in order. Registered from `configureDatabase`.
///
/// Appended to, never reordered or edited: once a migration has run anywhere it
/// is history. A change to a shipped table is a new migration.
enum AuthMigrations {
    static let all: [any Migration] = [
        EnableCitextExtension(),
        CreateUsers(),
        CreateUserIdentities(),
        CreateUserCredentials(),
        CreateEmailOTPs(),
        CreateRefreshTokens(),
        CreateRateLimits()
    ]
}

/// `citext` gives us case-insensitive email comparison in the database itself,
/// so `Giorgi@Gmail.com` and `giorgi@gmail.com` cannot become two accounts.
///
/// Emails are *also* normalized to lowercase at the HTTP boundary
/// (`String.normalizedEmail`). Two mechanisms for one rule is deliberate: the
/// extension is the backstop, normalization is what keeps the OTP lookup key
/// and the log lines consistent.
struct EnableCitextExtension: RawSQLMigration {
    var upStatements: [String] {
        ["CREATE EXTENSION IF NOT EXISTS citext"]
    }

    /// Not dropped on revert. Other tables may be using the type, and dropping
    /// an extension out from under them fails the revert of an unrelated
    /// migration.
    var downStatements: [String] { [] }
}

struct CreateUsers: RawSQLMigration {
    var upStatements: [String] {
        [
            """
            CREATE TABLE users (
                id            uuid PRIMARY KEY,
                email         citext,
                phone         text,
                display_name  text,
                status        text        NOT NULL,
                created_at    timestamptz,
                updated_at    timestamptz,
                deleted_at    timestamptz
            )
            """,
            // Partial, so a soft-deleted account releases its address for reuse
            // and several deleted rows can share a NULL email.
            """
            CREATE UNIQUE INDEX users_email_unique
                ON users (email)
             WHERE email IS NOT NULL AND deleted_at IS NULL
            """
        ]
    }

    var downStatements: [String] {
        ["DROP TABLE IF EXISTS users"]
    }
}

struct CreateUserIdentities: RawSQLMigration {
    var upStatements: [String] {
        [
            """
            CREATE TABLE user_identities (
                id                 uuid PRIMARY KEY,
                user_id            uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
                provider           text NOT NULL,
                subject            text NOT NULL,
                email_at_provider  citext,
                email_verified     boolean NOT NULL DEFAULT false,
                created_at         timestamptz,
                updated_at         timestamptz
            )
            """,
            // The real identity key: one Apple/Google account signs in to
            // exactly one of our accounts.
            "CREATE UNIQUE INDEX user_identities_provider_subject_unique ON user_identities (provider, subject)",
            "CREATE INDEX user_identities_user_id_idx ON user_identities (user_id)",
            // Finding the pending password signup for an address before it has
            // been proved - the one lookup that cannot go through users.email.
            "CREATE INDEX user_identities_email_at_provider_idx ON user_identities (email_at_provider)"
        ]
    }

    var downStatements: [String] {
        ["DROP TABLE IF EXISTS user_identities"]
    }
}

struct CreateUserCredentials: RawSQLMigration {
    var upStatements: [String] {
        [
            """
            CREATE TABLE user_credentials (
                id             uuid PRIMARY KEY,
                user_id        uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
                password_hash  text NOT NULL,
                created_at     timestamptz,
                updated_at     timestamptz
            )
            """,
            "CREATE UNIQUE INDEX user_credentials_user_id_unique ON user_credentials (user_id)"
        ]
    }

    var downStatements: [String] {
        ["DROP TABLE IF EXISTS user_credentials"]
    }
}

struct CreateEmailOTPs: RawSQLMigration {
    var upStatements: [String] {
        [
            """
            CREATE TABLE email_otps (
                id             uuid PRIMARY KEY,
                email          citext      NOT NULL,
                code_hash      text        NOT NULL,
                purpose        text        NOT NULL,
                expires_at     timestamptz NOT NULL,
                consumed_at    timestamptz,
                attempt_count  integer     NOT NULL DEFAULT 0,
                user_id        uuid REFERENCES users (id) ON DELETE CASCADE,
                created_at     timestamptz
            )
            """,
            // Serves both reads on this table: "the newest live code for this
            // address and purpose", and the per-hour send count behind the rate
            // limit.
            "CREATE INDEX email_otps_email_purpose_created_idx ON email_otps (email, purpose, created_at DESC)"
        ]
    }

    var downStatements: [String] {
        ["DROP TABLE IF EXISTS email_otps"]
    }
}

/// Backs `RateLimiter`.
///
/// A counter per (bucket, window) rather than a row per event, because the
/// per-IP cap has no events to count - and because incrementing one row is a
/// single atomic statement, where counting rows and then inserting one is a
/// race.
struct CreateRateLimits: RawSQLMigration {
    var upStatements: [String] {
        [
            """
            CREATE TABLE rate_limits (
                bucket        text        NOT NULL,
                window_start  timestamptz NOT NULL,
                count         integer     NOT NULL,
                PRIMARY KEY (bucket, window_start)
            )
            """,
            // The primary key serves the increment; this serves the pruning of
            // windows nobody will read again.
            "CREATE INDEX rate_limits_window_start_idx ON rate_limits (window_start)"
        ]
    }

    var downStatements: [String] {
        ["DROP TABLE IF EXISTS rate_limits"]
    }
}

struct CreateRefreshTokens: RawSQLMigration {
    var upStatements: [String] {
        [
            """
            CREATE TABLE refresh_tokens (
                id            uuid PRIMARY KEY,
                user_id       uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
                token_hash    text        NOT NULL,
                family_id     uuid        NOT NULL,
                expires_at    timestamptz NOT NULL,
                revoked_at      timestamptz,
                revoked_reason  text,
                device_label    text,
                created_at    timestamptz
            )
            """,
            // Unique because the hash is how a presented token is looked up,
            // and two rows for one token would make "has this been rotated
            // away?" ambiguous.
            "CREATE UNIQUE INDEX refresh_tokens_token_hash_unique ON refresh_tokens (token_hash)",
            // Revoking a family on reuse touches every row that shares it.
            "CREATE INDEX refresh_tokens_family_id_idx ON refresh_tokens (family_id)",
            "CREATE INDEX refresh_tokens_user_id_idx ON refresh_tokens (user_id)"
        ]
    }

    var downStatements: [String] {
        ["DROP TABLE IF EXISTS refresh_tokens"]
    }
}
