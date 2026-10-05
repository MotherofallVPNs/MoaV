#!/bin/bash
# Regression: .env variable lines must not carry a trailing inline "# comment".
#
# The bug (hit twice — AmneziaWG then Snell): a value line like
#   PORT_AMNEZIAWG=51821 # AmneziaWG port
# gets copied verbatim into the user's live .env by `moav update`
# (check_env_additions), and .env consumers that read a value with a raw
# grep|cut fold the comment into it — a client Endpoint became
# "<ip>:51821 # AmneziaWG ...", so the app connected but relayed no traffic.
#
# Fix + guard: keep every note on its OWN line above the variable in
# .env.example, and have check_env_additions strip any inline comment defensively.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/.env.example"
U="$ROOT/lib/update.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo ".env: no inline comments on variable lines"

# 1. .env.example has no `KEY=value  # note` lines (whitespace before the #).
hits="$(grep -nE '^[A-Z_][A-Z0-9_]*=.*[[:space:]]#' "$EXAMPLE" || true)"
if [ -z "$hits" ]; then
    ok ".env.example keeps every note on its own line"
else
    bad ".env.example still has inline comments on these variable lines:"
    printf '%s\n' "$hits" | sed 's/^/          /'
fi

# 2. The update-time append strips a trailing inline comment defensively.
if grep -qE "sed 's/\[\[:space:\]\].*#" "$U"; then
    ok "check_env_additions strips a trailing inline comment before appending"
else
    bad "check_env_additions does not strip inline comments — a slipped-through note would reach .env"
fi

# 3. Functional proof the strip pattern keeps the value only.
got="$(printf 'PORT_SNELL=8389      # Snell (only if ENABLE_SNELL=true)' | sed 's/[[:space:]]\{1,\}#.*$//')"
if [ "$got" = "PORT_SNELL=8389" ]; then
    ok "strip turns 'PORT_SNELL=8389   # note' into 'PORT_SNELL=8389'"
else
    bad "strip produced unexpected result: '$got'"
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
