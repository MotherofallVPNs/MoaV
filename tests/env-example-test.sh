#!/bin/bash
# Guards the slim .env.example / full-reference split (E4-1).
#
# .env.example is a CURATED minimal first-run surface; .env.example.full is the
# complete reference (every tunable, with defaults). The invariants below keep
# the two from drifting: slim must be a strict subset of full, slim must stay
# slim (no re-bloat), and the essentials a fresh `cp .env.example .env` install
# needs must be present.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

SLIM="$ROOT/.env.example"
FULL="$ROOT/.env.example.full"

echo ".env.example split tests"

[[ -f "$SLIM" ]] && ok ".env.example exists" || { bad ".env.example missing"; echo "  $pass/$fail"; exit 1; }
[[ -f "$FULL" ]] && ok ".env.example.full (reference) exists" || bad ".env.example.full missing — the full reference was lost"

# var keys (LHS of KEY=), ignoring commented lines
keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null | sed 's/=$//' | sort -u; }

# 1. slim ⊆ full: every key in the minimal file must also be in the reference,
#    or an operator copying a line "from the full reference" could find it absent.
missing_from_full=$(comm -23 <(keys "$SLIM") <(keys "$FULL") 2>/dev/null | tr '\n' ' ')
[[ -z "$missing_from_full" ]] && ok "every slim key is present in the full reference" \
    || bad "slim keys missing from full reference (drift): $missing_from_full"

# 2. slim stays slim: guard against a future edit re-bloating it back toward the
#    old 118-var / 475-line surface this split exists to remove.
n=$(keys "$SLIM" | wc -l | tr -d ' ')
[[ "$n" -le 40 ]] && ok "slim .env.example is curated ($n vars, ceiling 40)" \
                  || bad "slim .env.example has $n vars (> 40) — re-bloating; move advanced tunables to .env.example.full"

# 3. full is genuinely the superset (has the advanced classes slim dropped).
for k in SINGBOX_VERSION PORT_HTTPS TELEMT_POOL_SIZE CDN_TRANSPORT REALITY_TARGET; do
    grep -qE "^${k}=" "$FULL" && ok "full reference carries $k" \
        || bad "full reference missing $k — advanced tunable lost, not just moved"
done

# 4. the version-outdated check reads .env.example.full — it must hold versions.
grep -qE '^[A-Z_]+_VERSION=' "$FULL" \
    && ok "full reference carries *_VERSION lines (moav update version check)" \
    || bad "no *_VERSION in full reference — check_component_versions goes silent"

# 5. essentials a bare `cp .env.example .env` install needs.
for k in DOMAIN ACME_EMAIL ADMIN_PASSWORD COMPOSE_PROJECT_NAME INITIAL_USERS; do
    grep -qE "^#?${k}=" "$SLIM" && ok "slim has essential $k" \
        || bad "slim .env.example dropped essential $k"
done

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
