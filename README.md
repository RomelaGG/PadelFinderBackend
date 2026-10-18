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
