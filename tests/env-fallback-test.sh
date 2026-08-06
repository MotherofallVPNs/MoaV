#!/bin/bash
# CI test for nested env-var fallbacks: ${PRIMARY:-${SECONDARY:-DEFAULT}}.
#
# These chains are easy to get subtly wrong — XHTTP_REALITY_TARGET shipped as
# ${XHTTP_REALITY_TARGET:-dl.google.com:443}, silently ignoring REALITY_TARGET
# despite a comment claiming it followed it. This pins, for every such chain:
#   primary set            -> primary
#   primary empty/unset    -> secondary (if set)
#   both empty/unset       -> hardcoded default
# plus a coverage guard so a NEW nested fallback added without a test fails CI,
# and a site-check that the XHTTP->REALITY chain stays wired at all its callers.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "env nested-fallback resolution tests"

# resolve <primary_name> <secondary_name> <default> — evaluate the real
# ${primary:-${secondary:-default}} chain with whatever env is currently set.
resolve() {
    local p="$1" s="$2" d="$3"
    eval "printf '%s' \"\${$p:-\${$s:-$d}}\""
}

# assert_chain <primary> <secondary> <default>
assert_chain() {
    local p="$1" s="$2" d="$3" got
    # 1. primary set -> primary wins (even if secondary also set)
    got=$(env -i bash -c "$p='PRIMARY' $s='SECONDARY'; $(declare -f resolve); resolve $p $s '$d'")
    [[ "$got" == "PRIMARY" ]] && ok "$p set -> primary ($got)" || bad "$p set -> got '$got', want PRIMARY"
    # 2. primary empty, secondary set -> secondary
    got=$(env -i bash -c "$p='' $s='SECONDARY'; $(declare -f resolve); resolve $p $s '$d'")
    [[ "$got" == "SECONDARY" ]] && ok "$p empty, $s set -> secondary ($got)" || bad "$p empty -> got '$got', want SECONDARY"
    # 3. both unset -> default
    got=$(env -i bash -c "$(declare -f resolve); resolve $p $s '$d'")
    [[ "$got" == "$d" ]] && ok "$p & $s unset -> default ($got)" || bad "both unset -> got '$got', want '$d'"
}

# --- the known nested fallbacks (keep in sync with the coverage guard below) --
assert_chain XHTTP_REALITY_TARGET      REALITY_TARGET   "dl.google.com:443"
assert_chain CDN_ADDRESS               CDN_DOMAIN       ""
assert_chain CDN_SNI                   DOMAIN           ""
assert_chain CONDUIT_MAX_COMMON_CLIENTS CONDUIT_MAX_CLIENTS "100"

# --- regression: the XHTTP->REALITY chain must stay wired at every site --------
for f in scripts/bootstrap.sh scripts/lib/xray.sh docker-compose.yml; do
    if grep -qF 'XHTTP_REALITY_TARGET:-${REALITY_TARGET' "$ROOT/$f"; then
        ok "$f: XHTTP_REALITY_TARGET falls back to REALITY_TARGET"
    else
        bad "$f: XHTTP_REALITY_TARGET no longer falls back to REALITY_TARGET (the fixed bug)"
    fi
done

# --- coverage guard: every nested ${A:-${B:-...}} in the source must be a known
# --- chain above, so a new one can't ship untested. -------------------------
# bash 3.2 compatible (no mapfile): read via a while loop.
known='XHTTP_REALITY_TARGET|CDN_ADDRESS|CDN_SNI|CONDUIT_MAX_COMMON_CLIENTS'
uncovered=""
while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    [[ "$v" =~ ^($known)$ ]] || uncovered+=" $v"
done < <(grep -rhoE '\$\{[A-Z_]+:-\$\{[A-Z_]+:-' "$ROOT/scripts" "$ROOT/lib" "$ROOT/docker-compose.yml" 2>/dev/null \
    | sed -E 's/\$\{([A-Z_]+):-.*/\1/' | sort -u)
[[ -z "$uncovered" ]] && ok "all nested fallbacks in the source are covered by a test" \
                      || bad "untested nested fallback(s):$uncovered — add an assert_chain above"

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
