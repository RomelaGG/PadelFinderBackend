#!/usr/bin/env bash
#
# Fails if anything key-shaped is about to be committed.
#
# BUILD-PLAN.md section 4 asks for this (E-04, "no secrets in git"). It exists
# because a live Resend key was once pasted into .env.example - which is the one
# .env* path .gitignore deliberately does NOT exclude, so it would have been
# committed by the next `git add .`.
#
# Run it from CI on every pull request, and as a pre-commit hook:
#   ln -s ../../Scripts/check-secrets.sh .git/hooks/pre-commit
#
# Scans tracked and staged files only. Untracked files are not a risk yet, and
# .env is ignored.

set -euo pipefail
cd "$(dirname "$0")/.."

# Patterns are prefix-anchored to real providers rather than generic entropy,
# which keeps the false-positive rate near zero - a check that cries wolf gets
# bypassed, and then it protects nothing.
patterns=(
  're_[A-Za-z0-9_]{20,}'            # Resend
  'sk_live_[A-Za-z0-9]{10,}'        # Stripe live
  'rk_live_[A-Za-z0-9]{10,}'        # Stripe restricted live
  'AKIA[0-9A-Z]{16}'                # AWS access key id
  'eyJ[A-Za-z0-9_-]{20,}\.eyJ'      # a signed JWT
  'SG\.[A-Za-z0-9_-]{20,}'          # SendGrid
  'xkeysib-[A-Za-z0-9]{20,}'        # Brevo
  '-----BEGIN [A-Z ]*PRIVATE KEY'   # any private key
)

# Known, accepted findings.
#
# Every line here is debt, not a false positive. An allowlist is how a secret
# scanner quietly stops protecting anything, so each entry carries why it is
# here and what removes it.
#
#   Sources/.../PadelHubProvider.swift - a Supabase anon key hardcoded as a
#   default argument, committed in 793619c and therefore already in history.
#   ARCHITECTURE.md section 8 requires it to move to an environment variable.
#   Removing it needs PADELHUB_API_KEY set as a Fly secret first, or Padel Hub
#   availability breaks in production - so it is a deliberate change, not a
#   drive-by one. Delete this line when it is done.
allowlist=(
  'Sources/PadelFinderBackend/Providers/PadelHubProvider.swift'
)

# Files git would include in a commit, minus this script - it necessarily
# contains the patterns it looks for.
files=$(git ls-files --cached --others --exclude-standard | grep -v '^Scripts/check-secrets.sh$' || true)

for allowed in "${allowlist[@]}"; do
  files=$(echo "$files" | grep -vxF "$allowed" || true)
done

if [ -z "$files" ]; then
  exit 0
fi

found=0

for pattern in "${patterns[@]}"; do
  # -I skips binaries. Printed without the matched value, so a CI log does not
  # become the second place the secret leaks.
  while IFS=: read -r file line _; do
    [ -z "$file" ] && continue
    echo "error: possible secret in $file:$line (matched /$pattern/)" >&2
    found=1
  done < <(echo "$files" | tr '\n' '\0' | xargs -0 grep -InE "$pattern" 2>/dev/null || true)
done

if [ "$found" -ne 0 ]; then
  cat >&2 <<'MESSAGE'

Refusing to continue. If this is a real secret:
  1. Revoke it at the provider now - assume it is already compromised.
  2. Remove it from the file. Real values belong in .env (gitignored) or
     `fly secrets set`.
  3. If it was already committed, rewriting history is not enough on its own.
     Rotate the key regardless.

If it is a false positive, add a narrower pattern or exclude the file here.
MESSAGE
  exit 1
fi

echo "check-secrets: clean ($(echo "$files" | wc -l | tr -d ' ') files scanned)"

if [ "${#allowlist[@]}" -ne 0 ]; then
  echo "check-secrets: ${#allowlist[@]} file(s) allowlisted - see the comments in this script. These are known secrets, not clean files." >&2
fi
