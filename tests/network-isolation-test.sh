#!/bin/bash
# Asserts the docker management plane stays isolated from the data plane.
#
# docker-proxy is an UNAUTHENTICATED Docker API endpoint: tecnativa's socket
# proxy filters by path and HTTP method only, never by request body. With
# CONTAINERS/POST/EXEC enabled (which MoaV genuinely needs -- singbox-user-add.sh
# does `docker run -v` and `docker compose exec`), anything that can reach
# :2375 can POST /containers/create with {"Binds":["/:/host"],"Privileged":true}
# and own the host.
#
# While it sat on the shared moav_net, that was reachable from all 29 containers
# -- including sing-box, xray, wireguard, wstunnel, telemt, snowflake and
# trusttunnel, i.e. every service that terminates untrusted internet traffic.
# Only admin needs it.
#
# The data plane must be untouched: wstunnel -> moav-wireguard:51820,
# dnstt/slipstream -> sing-box:1080 all stay on moav_net.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "docker management-plane isolation"

C="$ROOT/docker-compose.yml"

# Parse membership from the compose source (no docker required, so this runs in
# the lint job as well as on a machine with a daemon).
svc_networks() { # $1 = service name -> prints its network names
    awk -v svc="  $1:" '
        $0==svc {inservice=1; next}
        inservice && /^  [a-z0-9_-]+:$/ {exit}
        inservice && /^    networks:/ {innet=1; next}
        innet && /^      - / {gsub(/^      - /,""); print; next}
        innet && !/^      / {innet=0}
    ' "$C"
}

proxy_nets=$(svc_networks docker-proxy | tr '\n' ' ' | sed 's/ $//')
[[ "$proxy_nets" == "moav_mgmt" ]] \
    && ok "docker-proxy is ONLY on moav_mgmt [$proxy_nets]" \
    || bad "docker-proxy networks = [$proxy_nets] — must be exactly moav_mgmt, or every container can reach the Docker API"

admin_nets=$(svc_networks admin | tr '\n' ' ')
[[ "$admin_nets" == *moav_mgmt* ]] \
    && ok "admin is on moav_mgmt (it is the only legitimate client)" \
    || bad "admin lost moav_mgmt — the dashboard cannot reach docker-proxy"
[[ "$admin_nets" == *moav_net* ]] \
    && ok "admin is still on moav_net (needs moav-sing-box:9090 for stats)" \
    || bad "admin lost moav_net — service APIs unreachable"

# The management network must not be a general-purpose bridge.
awk '/^  moav_mgmt:/{f=1} f&&/internal: true/{found=1} f&&/^  [a-z]/&&!/moav_mgmt/{f=0} END{exit !found}' "$C" \
    && ok "moav_mgmt is internal: true (no gateway; proxy reaches Docker via the socket mount)" \
    || bad "moav_mgmt is not internal — it should have no outbound route"

# DATA PLANE UNCHANGED. These are the chains that carry real VPN traffic between
# containers; a network split that broke any of them would break users.
for pair in "wstunnel:moav-wireguard:51820" "dnstt:sing-box:1080" "slipstream:sing-box:1080"; do
    svc="${pair%%:*}"; target="${pair#*:}"
    nets=$(svc_networks "$svc" | tr '\n' ' ')
    if [[ "$nets" == *moav_net* ]]; then
        ok "$svc still on moav_net (chain to $target intact)"
    else
        bad "$svc is no longer on moav_net — its chain to $target is broken"
    fi
done

# And no protocol container may be on the management network.
for svc in sing-box xray wireguard amneziawg wstunnel dnstt slipstream masterdns \
           gooserelay trusttunnel telemt snowflake psiphon-conduit grafana; do
    nets=$(svc_networks "$svc" | tr '\n' ' ')
    [[ -n "$nets" && "$nets" == *moav_mgmt* ]] \
        && bad "$svc is on moav_mgmt — it can reach the unauthenticated Docker API"
done
ok "no protocol/monitoring container is on moav_mgmt"

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
