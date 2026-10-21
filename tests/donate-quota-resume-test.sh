#!/bin/bash
# Regression test: MahsaNet donation must stop on the submission-quota rejection
# and resume without re-submitting already-donated configs.
#
# The bug (found live): a new-donor quota cap comes back as HTTP 400
# ("New donors can submit up to N configs..."). The old code only special-cased
# 429, so the 400 fell through to the generic failure branch and the loop kept
# firing every remaining config at the API — all guaranteed rejections. And a
# re-run re-submitted everything, burning more of the same quota.
#
# Fix: a ledger-keyed skip (resume) + a quota-message stop (break 2), with
# --force to re-donate on purpose.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DONATE="$ROOT/lib/donate.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "donate: stop on quota, resume via ledger"

# --- Unit: mahsanet_already_donated keys on (user, protocol) ------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP  jq not available for the ledger unit test"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    ledger="$tmp/donations.json"
    cat > "$ledger" <<'JSON'
{"configs":[{"id":"h1","user":"alice","protocol":"reality","donated_at":"2026-01-01T00:00:00Z"}]}
JSON
    # Source only the helper; override the ledger path.
    # shellcheck disable=SC1090
    ( source "$DONATE" >/dev/null 2>&1
      MAHSANET_DONATIONS_FILE="$ledger"
      mahsanet_already_donated alice reality ) \
        && ok "recognizes an already-donated (user, protocol)" \
        || bad "did not recognize a donated (user, protocol) — resume would re-submit it"

    ( source "$DONATE" >/dev/null 2>&1
      MAHSANET_DONATIONS_FILE="$ledger"
      mahsanet_already_donated alice hysteria2 ) \
        && bad "treated a NOT-yet-donated protocol as donated — resume would skip it" \
        || ok "does not skip a protocol that hasn't been donated for that user"

    ( source "$DONATE" >/dev/null 2>&1
      MAHSANET_DONATIONS_FILE="$ledger"
      mahsanet_already_donated bob reality ) \
        && bad "treated a different user as donated" \
        || ok "keys on the user, not just the protocol"

    # Missing ledger must not error out or claim things are donated.
    ( source "$DONATE" >/dev/null 2>&1
      MAHSANET_DONATIONS_FILE="$tmp/nope.json"
      mahsanet_already_donated alice reality ) \
        && bad "claimed donated against a missing ledger" \
        || ok "missing ledger => nothing donated (clean first run)"
fi

# --- Static: submit loop stops on the quota message, skips donated, --force ---
if grep -q 'mahsanet_already_donated' "$DONATE" \
   && grep -q 'if \[\[ -z "\$force" \]\] && mahsanet_already_donated' "$DONATE"; then
    ok "submit loop skips ledger entries unless --force"
else
    bad "submit loop does not skip already-donated configs"
fi

if grep -qE 'submit up to\|good-quality submission\|can submit more' "$DONATE" \
   && grep -q 'break 2' "$DONATE"; then
    ok "quota-cap 400 stops the whole run (break 2), not just one config"
else
    bad "no quota-message stop — a capped run keeps hammering the API"
fi

if grep -q 'donate|submit)' "$DONATE" && grep -qE '\-\-force\|-f' "$DONATE"; then
    ok "exposes --force to re-donate on purpose"
else
    bad "--force not wired through the donate command"
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED ($fail failed, $pass passed)"
    exit 1
fi
echo "PASSED ($pass checks)"
