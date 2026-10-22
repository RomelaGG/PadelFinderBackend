# PadelFinderBackend

💧 A project built with the Vapor web framework.

Design documents live outside this repo, in `PadelFinder Documentation`:
`ARCHITECTURE.md` for how the system works, `BUILD-PLAN.md` for the phase order,
`SYSTEM-DESIGN-DIAGRAMS.md` for the schema and the state machines.

## Getting Started

```bash
swift build
```

### Postgres

Accounts need Postgres. Either a local install:

```bash
brew install postgresql@16 && brew services start postgresql@16
```

then create the role and the two databases:

```bash
psql -h localhost -d postgres -c "CREATE ROLE padelfinder LOGIN PASSWORD 'padelfinder' CREATEDB;" -c "CREATE DATABASE padelfinder OWNER padelfinder;" -c "CREATE DATABASE padelfinder_test OWNER padelfinder;"
```

…or the containers, which match CI:

```bash
docker compose up -d db db-test
```

Then copy `.env.example` to `.env` and fill it in.

### Migrations

Never run at boot. On Fly they are the `release_command`, so a failed migration
fails the deploy instead of leaving a half-migrated database serving traffic.

```bash
swift run PadelFinderBackend migrate --yes
```

Reverting works too, and is worth checking before shipping a new migration:

```bash
swift run PadelFinderBackend migrate --revert --yes
```

### Test accounts

`/auth/register` only creates a placeholder, and `login` refuses anything that
is not `active`, so a usable account normally needs the emailed code. In
production those go out through Resend's test sender, which delivers only to
the address the Resend account was registered with - so an arbitrary test
address can never be verified that way. `seed-user` creates a verified account
directly:

```bash
swift run PadelFinderBackend seed-user --email test@example.com --display-name "Test User" --yes
```

The password is generated and printed **once**; it is never accepted as an
argument, because on production that would leave it in shell history and in
Fly's audit trail. Nothing is written until you confirm, and `--yes` (ConsoleKit's
global flag, as with `migrate --yes`) is required on a non-interactive shell.

Seeding an address that already has a password refuses unless you pass
`--reset-password`, which replaces it and revokes every live session exactly as
a password reset does. A sign-up still waiting on its code, or an account that
signed up with Apple or Google and has no password, needs no such opt-in -
neither case takes a working login away from anyone.

On Fly, run it on the machine:

```bash
fly ssh console -a padelfinder-ge -C "/app/PadelFinderBackend seed-user --email test@example.com --yes"
```

Do **not** add `--env production` there. Nothing the command needs is
environment-gated - `DATABASE_URL` is a Fly secret and is present either way -
but `--env production` activates the mailer validation that refuses to boot
without `OTP_MAILER=resend` and a `RESEND_API_KEY`, which would stop a command
that sends no email at all. This is the same reason `release_command` in
`fly.toml` carries no `--env`.

There is no route for any of this and there must not be: it stands in for the
proof that an address is owned, which is only safe behind shell access.

### Running

```bash
swift run
```

With `OTP_MAILER=log` (the default) the 6-digit sign-up codes are written to the
console rather than emailed, so the whole account flow is usable locally with no
mail provider configured.

**Production refuses `OTP_MAILER=log`.** It would answer `202` for sign-ups
whose email was never sent, and leave every code in plain text in the logs, so
the app fails to boot rather than coming up broken. A staging environment that
runs with `--env production` should use `OTP_MAILER=resend` with Resend's test
sender, which only delivers to your own address.

To send real email, set `OTP_MAILER=resend` and `RESEND_API_KEY`. Resend's test
sender needs no domain but reaches only the address the Resend account was
registered with; real users need a verified domain in `OTP_FROM_ADDRESS`, with
the SPF, DKIM and DMARC records Resend provides. Skip those records and codes
land in spam while the API still answers `202` — the failure is completely
silent, which is why the server warns while the test sender is in use.

### Tests

```bash
swift test
```

The auth suites need `DATABASE_URL_TEST` pointing at a throwaway database —
what they verify *is* Postgres (the single-use OTP `UPDATE`, the unique
indexes, the atomic attempt counter), so there is nothing to test without one.
Absent that variable they are skipped rather than failed, and the availability
tests still run.

### Secrets

`.env` is gitignored; `.env.example` is **not**, because it is the committed
template. Never put a real value in it.

```bash
./Scripts/check-secrets.sh
```

Fails if anything key-shaped is staged or tracked (BUILD-PLAN.md section 4,
E-04). Wire it into CI, and optionally as a pre-commit hook:

```bash
ln -s ../../Scripts/check-secrets.sh .git/hooks/pre-commit
```

It carries one allowlisted file — a Supabase key committed in `793619c` and
flagged in ARCHITECTURE.md section 8. That is recorded debt, not a clean file.

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)
