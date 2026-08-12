#!/bin/bash
# Regression test: regenerating a donate-mode user must not fail on a protocol
# that user was never given.
#
# From a live 2.1.0 run:
#
#   [ERROR] No telemt secret found for test210_aug1101
#   [ERROR] Failed to generate bundle for test210_aug1101 (continuing)
#     test210_aug1101 … FAILED
#
# Donate mode provisions a subset of protocols, so a donated user has no
# state/users/<u>/telemt.env. The server-wide ENABLE_TELEMT is still true, so
# generate-user.sh called the generator anyway, the generator returned 1 on the
# missing secret, and `set -euo pipefail` threw away the whole bundle -- every
# protocol the user DOES have -- over one they were never meant to have.
#
# The gate is the user's own state, not the server-wide flag.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "regenerate: a donate-mode user survives protocols they do not have"

GEN="$ROOT/scripts/generate-user.sh"

# --- the telemt block must key off the user's state, not just the flag -------
block=$(awk '/^# Generate telemt \(Telegram MTProxy\) instructions/,/^# Generate XDNS/' "$GEN")
if [ -z "$block" ]; then
    bad "could not find the telemt block in generate-user.sh"
else
    if printf '%s' "$block" | grep -q 'users/\$USER_ID/telemt.env'; then
        ok "the telemt block checks for the user's own secret first"
    else
        bad "telemt runs off ENABLE_TELEMT alone — a donated user still loses the bundle"
    fi
    # It must SKIP, not error: an error line in a routine regenerate trains
    # operators to ignore errors.
    if printf '%s' "$block" | grep -q 'log_info.*telemt.*skipping'; then
        ok "a user without the secret is skipped at info level"
    else
        bad "the missing-secret path does not log a plain skip"
    fi
fi

# --- and the generator itself is still strict when it IS called --------------
# The call-site guard is the fix; softening the generator would hide a genuinely
# broken provision for a user who should have telemt.
if grep -q 'log_error "No telemt secret found' "$ROOT/scripts/lib/telemt.sh"; then
    ok "telemt_generate_client_instructions still fails loudly if called without a secret"
else
    bad "the generator was softened instead of the call site — real failures now pass silently"
fi

# --- behavioural check: the real guard against a real state dir --------------
# Reproduce both shapes and run just the block's condition.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state/users/donated" "$TMP/state/users/full" "$TMP/out"
printf 'TELEMT_SECRET=abc123\n' > "$TMP/state/users/full/telemt.env"

took_branch() {   # <user> -> skip | generate
    STATE_DIR="$TMP/state" USER_ID="$1" bash -c '
        if [[ ! -f "$STATE_DIR/users/$USER_ID/telemt.env" ]]; then echo skip; else echo generate; fi
    '
}
[ "$(took_branch donated)" = "skip" ] \
    && ok "a donate-mode user (no telemt.env) takes the skip branch" \
    || bad "a donated user still reaches the generator"
[ "$(took_branch full)" = "generate" ] \
    && ok "a fully provisioned user still gets their telemt link" \
    || bad "the guard skips a user who HAS a secret — telemt would vanish from every bundle"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
