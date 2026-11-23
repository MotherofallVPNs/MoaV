#!/bin/bash
# Regression test: the dnstunnel profile (dns-router + backends) must start for
# any routed DNS tunnel, and only for those.
#
# lib/service.sh gated the profile on ENABLE_DNSTT || ENABLE_SLIPSTREAM, so a
# MasterDNS-only or XDNS-only server never started dns-router and nothing
# answered on port 53. Slipstream is unrouted now, so counting it would start a
# router with no routes, which exits and crash-loops under restart: unless-stopped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
info() { :; }

echo "dnstunnel profile starts for dnstt / MasterDNS / XDNS only"

# Real get_env_val from moav.sh, so .env parsing matches production.
eval "$(sed -n '/^get_env_val() {/,/^}/p' "$ROOT/moav.sh")"
# shellcheck disable=SC2034  # read by the sourced lib/service.sh
SCRIPT_DIR="$ROOT"
# shellcheck source=../lib/service.sh
source "$ROOT/lib/service.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

case_env() {  # <label> <want> <dnstt> <masterdns> <xdns> <slipstream>
    local label="$1" want="$2" env="$TMP/$1.env"
    printf 'ENABLE_DNSTT=%s\nENABLE_MASTERDNS=%s\nENABLE_XDNS=%s\nENABLE_SLIPSTREAM=%s\n' \
        "$3" "$4" "$5" "$6" > "$env"
    local got derived in_derived=false
    got=$(profile_enabled dnstunnel "$env")
    derived=$(derive_enabled_profiles "$env")
    [[ " $derived " == *" dnstunnel "* ]] && in_derived=true
    if [[ "$got" == "$want" && "$in_derived" == "$want" ]]; then
        ok "$label → dnstunnel=$want"
    else
        bad "$label → profile_enabled=$got, in derived profiles=$in_derived (want $want)"
    fi
}

case_env masterdns-only   true  false true  false false
case_env xdns-only        true  false false true  false
case_env dnstt-only       true  true  false false false
case_env all-routed       true  true  true  true  false
case_env none             false false false false false
case_env slipstream-only  false false false false true

# Absent keys fall back to the compose defaults (dnstt/MasterDNS/XDNS on).
: > "$TMP/empty.env"
[[ "$(dns_tunnel_enabled "$TMP/empty.env")" == "true" ]] \
    && ok "sparse .env uses the on-by-default fallbacks" \
    || bad "sparse .env no longer starts the DNS tunnels"

# Every decision site must go through the one helper, or they drift again.
n=$(grep -c 'dns_tunnel_enabled "\$' "$ROOT/lib/service.sh")
[[ "$n" -ge 5 ]] \
    && ok "status, profile list, default selection, profile_enabled and port-53 check share the helper ($n uses)" \
    || bad "only $n call sites use dns_tunnel_enabled; a site went back to its own flag list"
grep -qE 'enable_dnstt.*!=.*&&.*enable_slipstream' "$ROOT/lib/service.sh" \
    && bad "a dnstt||slipstream-only gate is back in lib/service.sh" \
    || ok "no dnstt||slipstream-only gate left"

# The helper must agree with the router's own "nothing to route" check.
grep -q 'ENABLE_DNSTT" != "true" && "$ENABLE_MASTERDNS" != "true" && "$ENABLE_XDNS" != "true"' \
    "$ROOT/scripts/dns-router-entrypoint.sh" \
    && ok "dns-router entrypoint gates on the same three flags" \
    || bad "dns-router entrypoint and dns_tunnel_enabled disagree on which flags count"

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
