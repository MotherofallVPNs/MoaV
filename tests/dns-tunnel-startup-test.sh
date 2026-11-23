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

# The dnstunnel profile groups dnstt + masterdns + slipstream, so a profile-level
# gate alone still launched a disabled member (Slipstream restart-looped on a
# fresh install: no cert, exit 1, restart: unless-stopped).
DOCKER_LOG="$TMP/docker.log"
docker() {
    echo "$*" >> "$DOCKER_LOG"
    if [[ "$*" == *"config --services"* ]]; then
        printf '%s\n' certbot decoy dns-router dnstt masterdns slipstream xray sing-box
    fi
}
up_case() {  # <label> <env-lines> <must-start> <must-not-start>
    local label="$1" env="$TMP/up-$1.env" upline s okc=true
    printf '%b' "$2" > "$env"
    : > "$DOCKER_LOG"
    compose_up_enabled "--profile proxy --profile dnstunnel " "$env" >/dev/null 2>&1
    upline=$(grep ' up -d' "$DOCKER_LOG" | tail -1)
    # No service list = every service of the profiles starts.
    if [[ "$upline" != *"--remove-orphans" ]]; then
        for s in $3; do [[ " $upline " == *" $s "* ]] || okc=false; done
    fi
    for s in $4; do [[ " $upline " == *" $s "* ]] && okc=false; done
    $okc && ok "start: $label" || bad "start: $label → '$upline'"
}
up_case "fresh install skips slipstream" "ENABLE_DNSTT=true\nENABLE_MASTERDNS=true\n" \
    "dnstt masterdns dns-router sing-box" "slipstream"
up_case "ENABLE_SLIPSTREAM=false + dnstt off" "ENABLE_SLIPSTREAM=false\nENABLE_DNSTT=false\n" \
    "masterdns dns-router" "slipstream dnstt"
up_case "masterdns off" "ENABLE_MASTERDNS=false\n" "dnstt dns-router" "masterdns slipstream"
grep -q 'rm -sf slipstream' "$DOCKER_LOG" \
    && ok "an upgraded install's leftover Slipstream container is removed" \
    || bad "leftover Slipstream container is not removed on start"
up_case "ENABLE_SLIPSTREAM=true still starts it" "ENABLE_SLIPSTREAM=true\n" "slipstream dnstt masterdns" ""
unset -f docker

# Every start path goes through the helper (start, first-run bootstrap, menu, switch-dns).
n=$(grep -c 'compose_up_enabled "\$' "$ROOT/lib/service.sh" "$ROOT/lib/bootstrap.sh" "$ROOT/lib/dns.sh" | awk -F: '{s+=$2} END{print s}')
m=$(grep -c "compose_up_enabled '\$profiles'" "$ROOT/lib/service.sh")
[[ "$n" -ge 3 && "$m" -ge 1 ]] \
    && ok "cmd_start, bootstrap, start_services and switch-dns use compose_up_enabled" \
    || bad "a start path bypasses compose_up_enabled ($n + $m call sites)"

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
